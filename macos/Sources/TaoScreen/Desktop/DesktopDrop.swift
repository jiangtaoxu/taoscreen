import AppKit
import Carbon
import OSLog

struct DesktopDropPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct DesktopDropResult {
    var message: String
    var warning: Bool
    var paths: [String]
}

struct DesktopTransferState: Equatable {
    enum Phase: String { case preparing, sending, delivering, completed, warning, failed, cancelled }
    var phase: Phase
    var message: String
    var bytes: Int64 = 0
    var total: Int64 = 0
    var fileIndex = 0
    var fileCount = 0
    var startedAt = Date()
    var updatedAt = Date()
    var paths: [String] = []
    var destinationHint: String?
    var active: Bool { [.preparing, .sending, .delivering].contains(phase) }
    var progress: Double? {
        guard phase == .sending, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
}

enum DesktopDropStorage {
    // 使用应用管理目录而非系统 /tmp，避免用户尚未执行命令就被系统清理。
    static var root: URL {
        DesktopRuntime.supportDirectory.appendingPathComponent("RemoteDrop", isDirectory: true)
    }
    static let retention: TimeInterval = 7 * 24 * 3600
    static func prune(root: URL, now: Date = .now) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for child in children {
            let name = child.lastPathComponent
            let suffix = name.hasPrefix("接收-") ? String(name.dropFirst(3)) : name.hasPrefix(".partial-") ? String(name.dropFirst(9)) : ""
            guard UUID(uuidString: suffix) != nil, let info = try? child.resourceValues(forKeys: keys),
                  info.isDirectory == true, info.isSymbolicLink != true,
                  let date = info.contentModificationDate, now.timeIntervalSince(date) > retention else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// POSIX 单引号引用适用于 macOS 常用的 zsh/bash；拒绝可触发终端动作的控制字符。
    static func shellPaths(_ paths: [String]) -> String? {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { return nil }
        return paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " "
    }
}

/// Snapshot the exact target before transfer; never infer a Finder path from its
/// title or require AXDocument (Finder may return AXError.noValue for directories).
@MainActor
final class DesktopDropDelivery {
    private static let log = Logger(subsystem: "com.xujiangtao.taoscreen", category: "drop")
    private struct WindowIdentity: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let title: String?
        static func capture(at point: CGPoint, pid: pid_t? = nil, ignoringDragImage: Bool = false) -> Self? {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
            for window in windows {
                guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                      pid == nil || owner == pid,
                      !ignoringDragImage || (window[kCGWindowLayer as String] as? Int ?? 0) < CGWindowLevelForKey(.draggingWindow),
                      let id = window[kCGWindowNumber as String] as? UInt32,
                      (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                      let value = window[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: value as CFDictionary), bounds.contains(point) else { continue }
                return .init(id: id, pid: owner, bounds: bounds, title: window[kCGWindowName as String] as? String)
            }
            return nil
        }
    }
    private struct Target {
        var point: CGPoint
        var displayID: CGDirectDisplayID
        var displayBounds: CGRect
        var pid: pid_t
        var element: AXUIElement?
        var identity: WindowIdentity
        var window: AXUIElement?
        var title: String?
        var document: String?
        var frame: CGRect?
        var elementFrame: CGRect?
    }
    private var target: Target?
    private var generation = UUID()
    private let native = DesktopNativeDrag()
    private var localInputMonitor: Any?
    private var globalInputMonitor: Any?
    var onDiagnostic: ((String) -> Void)? { didSet { native.onDiagnostic = onDiagnostic } }
    private func diagnose(_ stage: String) {
        Self.log.notice("drop-target stage=\(stage, privacy: .public)")
        onDiagnostic?(stage)
    }
    private var reason = "无法确认投放区域，请在远端手动使用已保存的文件。"
    var isDelivering: Bool { native.isActive }
    var summary: String {
        target == nil ? reason : "上传完成后在原位置拖入文件，请保持目标不变。"
    }

    func invalidate() {
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        localInputMonitor = nil; globalInputMonitor = nil
        target = nil; generation = UUID(); native.cancel()
        reason = "目标已变化，文件已保存，未自动投放。"
    }

    func prepare(_ point: DesktopDropPoint, input: DesktopInputReceiver, allowed: () -> Bool) async {
        invalidate()
        let token = generation
        reason = "此区域无法确认投放目标，文件将保存在远端暂存目录。"
        guard !Task.isCancelled, point.isValid, allowed(), input.enabled else { return }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            reason = "远端辅助功能或输入控制权限不可用，文件将保存在暂存目录。"; return
        }
        guard !IsSecureEventInputEnabled() else {
            reason = "远端处于安全输入状态，文件将保存在暂存目录。"; return
        }
        let bounds = CGDisplayBounds(input.displayID)
        let position = CGPoint(x: bounds.minX + point.x * max(0, bounds.width - 1),
                               y: bounds.minY + point.y * max(0, bounds.height - 1))
        var hit = Self.hit(at: position)
        // WebKit may lazily build its accessibility tree on the first query.
        for _ in 0..<3 where hit == nil {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, generation == token, allowed() else { return }
            hit = Self.hit(at: position)
        }
        guard hit.map({ !Self.isSecure($0) }) ?? true else { return }
        var owner: pid_t = 0
        let hitPID = hit.flatMap { AXUIElementGetPid($0, &owner) == .success ? owner : nil }
        guard let identity = WindowIdentity.capture(at: position, pid: hitPID) else {
            diagnose("target-window-unavailable"); return
        }
        let window = hit.flatMap { Self.element($0, kAXWindowAttribute) }
        // Dock/desktop targets can be windowless; retain the actual hit element.
        target = Target(point: position, displayID: input.displayID, displayBounds: bounds, pid: identity.pid,
                        element: hit, identity: identity, window: window, title: window.flatMap { Self.string($0, kAXTitleAttribute) },
                        document: window.flatMap { Self.string($0, kAXDocumentAttribute) },
                        frame: window.flatMap(Self.frame), elementFrame: hit.flatMap(Self.frame))
        diagnose(hit == nil ? "target-window-snapshot" : "target-accessibility-snapshot")
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        // Physical host interaction during upload also invalidates the snapshot.
        // Once the native drag starts, its tagged CGEvent observer owns this check.
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { if self?.native.isActive == false { self?.invalidate() } }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { if self?.native.isActive == false { self?.invalidate() } }
            return event
        }
        reason = "目标已变化，文件已保存，未自动投放。"
    }

    func deliver(_ urls: [URL], input: DesktopInputReceiver, allowed: @escaping () -> Bool) async -> DesktopDropResult {
        let paths = urls.map(\.path)
        guard !Task.isCancelled, allowed(), input.enabled, let target, matches(target) else {
            return .init(message: reason, warning: true, paths: paths)
        }
        let token = generation
        input.releaseAll()
        let outcome = await native.deliver(urls, at: target.point, display: target.displayBounds,
            allowed: { [weak self, weak input] in
                self?.generation == token && allowed() && input?.enabled == true
            }, validateTarget: { [weak self] in
                self?.generation == token && self?.matches(target, checkElement: false) == true
            })
        // An older completion must not invalidate the next batch's snapshot.
        if generation == token { invalidate() }
        let message: String
        switch outcome {
        case .accepted: message = "目标已接受文件拖放，请在目标应用中确认处理结果。"
        case .rejected: message = "目标未接受文件拖放，文件已保存在远端暂存目录。"
        case .cancelled: message = "投放已取消或目标发生变化，文件已保存在远端暂存目录。"
        case .unavailable: message = "远端无法启动系统拖放，请检查辅助功能权限；文件已保存在暂存目录。"
        case .timedOut: message = "等待目标拖放响应超时，文件已保存；请检查目标，避免重复投放。"
        }
        return .init(message: message, warning: outcome != .accepted, paths: paths)
    }

    private func matches(_ target: Target, checkElement: Bool = true) -> Bool {
        guard CGDisplayBounds(target.displayID) == target.displayBounds else { return false }
        let hit = Self.hit(at: target.point)
        var pid: pid_t = 0
        let hitPID = hit.flatMap { AXUIElementGetPid($0, &pid) == .success ? pid : nil }
        guard hit.map({ !Self.isSecure($0) }) ?? true else { diagnose("secure-target"); return false }
        // AppKit's drag image or the app's drop hint can own the AX hit. Preserve
        // the original receiving window while ignoring the system drag layer.
        // An AX hit in another application still means the target was covered.
        if !checkElement, let hitPID, hitPID != target.pid, hitPID != ProcessInfo.processInfo.processIdentifier {
            diagnose("target-application-changed"); return false
        }
        let currentIdentity = WindowIdentity.capture(at: target.point, pid: checkElement ? hitPID : target.pid,
                                                     ignoringDragImage: !checkElement)
        guard currentIdentity == target.identity else {
            diagnose("window-changed-old-\(target.identity.id)-new-\(currentIdentity?.id ?? 0)-axpid-\(hitPID ?? 0)")
            return false
        }
        // A hover can expose a child (e.g. a Finder icon label); the original
        // element must still own that hit. A shared window alone is insufficient.
        // AppKit/Finder legitimately replace child AX elements during drag hover.
        // Check the child before starting; while dragging, the window identity,
        // geometry, document, secure-input gate and event observer remain binding.
        if checkElement, let original = target.element {
            guard let hit, hitPID == target.pid, Self.frame(original) == target.elementFrame,
                  Self.ancestors(hit).contains(where: { CFEqual($0, original) }) else { diagnose("element-changed"); return false }
        }
        if let window = target.window {
            // A chat app can replace its input's accessibility subtree with a
            // drop hint. During the drag, validate the retained window instead
            // of requiring the hint to expose the same AXWindow relationship.
            if checkElement {
                guard let hit, let currentWindow = Self.element(hit, kAXWindowAttribute), CFEqual(window, currentWindow) else {
                    diagnose("accessibility-window-changed"); return false
                }
            }
            guard Self.string(window, kAXTitleAttribute) == target.title,
                  Self.string(window, kAXDocumentAttribute) == target.document,
                  Self.frame(window) == target.frame else { diagnose("window-attributes-changed"); return false }
        }
        return true
    }

    private static func hit(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }
    private static func isSecure(_ element: AXUIElement) -> Bool {
        ancestors(element).contains { string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole }
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func ancestors(_ start: AXUIElement) -> [AXUIElement] {
        var result = [start]
        for _ in 0..<8 {
            guard let parent = element(result.last!, kAXParentAttribute), !result.contains(where: { CFEqual($0, parent) }) else { break }
            result.append(parent)
        }
        return result
    }
}
