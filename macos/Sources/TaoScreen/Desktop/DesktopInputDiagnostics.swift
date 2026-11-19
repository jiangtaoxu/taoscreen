import AppKit
import OSLog

/// 常规日志只记录按钮阶段；专用诊断包另记录鼠标投递属性，不记录按键内容或剪贴板。
enum DesktopInputDiagnostics {
    private static let logger = Logger(subsystem: "com.xujiangtao.taoscreen", category: "input")
    // 仅专用诊断包写入此键；普通构建不安装观察器，也不收发诊断消息。
    static let systemEnabled = Bundle.main.object(forInfoDictionaryKey: "TaoziInputSystemDiagnostics") as? Bool == true

    static func trace(_ value: DesktopInputTrace, remote: Bool = false) {
        logger.notice("system=\(value.stage, privacy: .public) remote=\(remote) \(value.detail, privacy: .public)")
    }

    static func button(_ stage: String, number: Int, down: Bool, detail: String = "") {
        logger.notice("stage=\(stage, privacy: .public) button=\(number) down=\(down) \(detail, privacy: .public)")
    }

    static func record(_ stage: String, input: DesktopInput, detail: String = "") {
        guard input.kind == "button", let number = input.button, let down = input.down else { return }
        button(stage, number: number, down: down, detail: detail)
    }
}

struct DesktopInputTrace: Codable {
    var kind = "desktop-input-trace.v1"
    let stage: String
    let detail: String
    var isValid: Bool { kind == "desktop-input-trace.v1" && stage.utf8.count <= 64 && detail.utf8.count <= 2048 }
}

/// 用 userData 标记接收器产生的鼠标事件，再以只读 tap 观察；不申请权限。
@MainActor
final class DesktopInputSystemObserver {
    var onTrace: ((DesktopInputTrace) -> Void)?
    private let marker = Int64.random(in: 1...Int64.max)
    private var started = false
    private final class Context {
        let marker: Int64
        let stage: String
        let report: (String, CGEvent) -> Void
        init(marker: Int64, stage: String, report: @escaping (String, CGEvent) -> Void) {
            self.marker = marker; self.stage = stage; self.report = report
        }
    }
    private var taps: [(CFMachPort, CFRunLoopSource, Context)] = []

    func stop() {
        for (tap, source, _) in taps {
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        taps.removeAll(); started = false
    }

    func prepare(_ event: CGEvent) {
        guard DesktopInputDiagnostics.systemEnabled, Self.mouseTypes.contains(event.type) else { return }
        if !started { start() }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        report("before-post", event: event)
    }

    private static let mouseTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .scrollWheel]

    private func emit(_ stage: String, _ detail: String) {
        let value = DesktopInputTrace(stage: stage, detail: detail)
        DesktopInputDiagnostics.trace(value); onTrace?(value)
    }

    private func report(_ stage: String, event: CGEvent) {
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        let name = NSRunningApplication(processIdentifier: pid_t(clamping: target))?.bundleIdentifier ?? "unknown"
        emit(stage, "type=\(event.type.rawValue) number=\(event.getIntegerValueField(.mouseEventNumber)) flags=\(event.flags.rawValue) point=\(event.location.x),\(event.location.y) clicks=\(event.getIntegerValueField(.mouseEventClickState)) source=\(event.getIntegerValueField(.eventSourceUnixProcessID)) state=\(event.getIntegerValueField(.eventSourceStateID)) target=\(target) app=\(name)")
    }

    private func start() {
        started = true
        emit("observer", "pid=\(ProcessInfo.processInfo.processIdentifier) ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess()) listen=\(CGPreflightListenEventAccess())")
        // 已有权限才能观察；不触发授权请求，不尝试其他注入路径。
        guard CGPreflightListenEventAccess() else { emit("observer-unavailable", "listen-access=false"); return }
        let mask = Self.mouseTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        for (location, stage) in [(CGEventTapLocation.cgSessionEventTap, "session"), (.cgAnnotatedSessionEventTap, "target")] {
            let context = Context(marker: marker, stage: stage) { [weak self] stage, event in
                MainActor.assumeIsolated { self?.report(stage, event: event) }
            }
            guard let tap = CGEvent.tapCreate(tap: location, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: { _, type, event, pointer in
                    guard let pointer else { return Unmanaged.passUnretained(event) }
                    let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        context.report(context.stage + "-disabled", event)
                    } else if event.getIntegerValueField(.eventSourceUserData) == context.marker {
                        context.report(context.stage, event)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
                emit("observer-unavailable", "stage=\(stage) tap-create-failed"); continue
            }
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                CFMachPortInvalidate(tap); emit("observer-unavailable", "stage=\(stage) run-loop-source-failed"); continue
            }
            taps.append((tap, source, context))
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            emit("observer-ready", "stage=\(stage)")
        }
    }
}
