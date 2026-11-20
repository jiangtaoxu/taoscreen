import AppKit
import ScreenCaptureKit
#if SWIFT_PACKAGE
import DesktopVirtualDisplayBridge
#endif

enum DesktopVirtualDisplayPreset: String, Codable, CaseIterable, Identifiable {
    case fullHD, quadHD, ultraHD

    var id: Self { self }
    var dimensions: (width: UInt32, height: UInt32) {
        switch self {
        case .fullHD: (1920, 1080)
        case .quadHD: (2560, 1440)
        case .ultraHD: (3840, 2160)
        }
    }

    var hiDPI: Bool { self == .ultraHD }
    var title: String { L10n.text("虚拟屏 · \(dimensions.width) × \(dimensions.height)\(hiDPI ? "（HiDPI）" : "")") }
}

enum DesktopShareDisplay: Hashable {
    case main
    case fixed(CGDirectDisplayID)
    case virtual(DesktopVirtualDisplayPreset)

    var virtualPreset: DesktopVirtualDisplayPreset? {
        if case let .virtual(preset) = self { return preset }
        return nil
    }
}

@MainActor
final class DesktopVirtualDisplay {
    let id: CGDirectDisplayID
    let preset: DesktopVirtualDisplayPreset
    private let handle: NSObject

    init(preset: DesktopVirtualDisplayPreset) throws {
        let size = preset.dimensions
        var id = kCGNullDirectDisplay
        let handle = autoreleasepool { TaoCreateVirtualDisplay(size.width, size.height, preset.hiDPI, &id) }
        guard let handle, id != kCGNullDirectDisplay else {
            throw CloudError(L10n.text("无法创建 \(size.width) × \(size.height) 虚拟屏。当前 macOS 或显示器配置未能启用虚拟显示器。"))
        }
        self.id = id
        self.preset = preset
        self.handle = handle
    }

    var isExtended: Bool { Self.isExtended(id) }

    private static func isExtended(_ id: CGDirectDisplayID) -> Bool {
        // 显示器移除后，CoreGraphics 对失效 ID 可能返回 -1。
        CGDisplayIsActive(id) == 1 && CGDisplayIsInMirrorSet(id) == 0
    }

    static func waitUntilReady(_ id: CGDirectDisplayID, preset: DesktopVirtualDisplayPreset,
                               isCurrentSession: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while isCurrentSession(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if isExtended(id), hasResolution(id, preset: preset), NSScreen.screens.contains(where: { $0.desktopDisplayID == id }) {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard isCurrentSession() else { throw CancellationError() }
                if isExtended(id), hasResolution(id, preset: preset),
                   content.displays.contains(where: { $0.displayID == id }) { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrentSession() else { throw CancellationError() }
        if CGDisplayIsInMirrorSet(id) == 1 {
            throw CloudError(L10n.text("macOS 将虚拟屏设为镜像，无法将其作为独立屏幕共享。"))
        }
        if isExtended(id), !hasResolution(id, preset: preset) {
            throw CloudError(L10n.text("macOS 未能启用所选的虚拟屏分辨率。"))
        }
        throw CloudError(L10n.text("macOS 未能及时将虚拟屏提供给屏幕采集。请在被控 Mac 检查显示器和录屏权限后重试。"))
    }

    private static func hasResolution(_ id: CGDirectDisplayID, preset: DesktopVirtualDisplayPreset) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let size = preset.dimensions
        return mode.pixelWidth == size.width && mode.pixelHeight == size.height
    }
}

extension NSScreen {
    var desktopDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
