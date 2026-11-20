import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import TaoScreen

@Suite(.serialized)
struct DesktopPrivacyTests {
    @Test @MainActor func libraryCopiesImagesPersistsSelectionAndDeletesOwnedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("wallpaper.png")
        try png(width: 5000, height: 20).write(to: source)
        let library = DesktopPrivacyLibrary(directory: root.appendingPathComponent("library"))
        #expect(!library.settings.automatic)
        library.setAutomatic(true)
        await library.importImages([source])
        #expect(library.error == nil && !library.importing)
        let item = try #require(library.settings.images.first)
        #expect(library.settings.selection == item.selectionID)
        let copy = library.directory.appendingPathComponent(item.filename)
        let imageSource = try #require(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 3840)
        try FileManager.default.removeItem(at: source)
        let reloaded = DesktopPrivacyLibrary(directory: library.directory)
        #expect(reloaded.settings == library.settings)
        #expect(reloaded.image(item) != nil && reloaded.image(item, thumbnail: true) != nil)
        reloaded.remove(item)
        #expect(reloaded.settings.images.isEmpty)
        #expect(reloaded.settings.selection == DesktopPrivacyPreset.charcoal.id)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(DesktopPrivacyLibrary(directory: library.directory).settings == reloaded.settings)
    }

    @Test @MainActor func invalidImageOrStorageFailureNeverReplacesSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = root.appendingPathComponent("not-an-image.png")
        try Data("invalid".utf8).write(to: invalid)
        let library = DesktopPrivacyLibrary(directory: root.appendingPathComponent("library"))
        library.select(DesktopPrivacyPreset.forest.id)
        await library.importImages([invalid])
        #expect(library.error != nil)
        #expect(library.settings.images.isEmpty && library.settings.selection == DesktopPrivacyPreset.forest.id)
        library.select("../../other-file")
        #expect(library.settings.selection == DesktopPrivacyPreset.forest.id)
        let blocked = DesktopPrivacyLibrary(directory: invalid)
        blocked.setAutomatic(true)
        #expect(blocked.error != nil && !blocked.settings.automatic)
    }

    @Test @MainActor func missingSelectedImageFallsBackWithoutLosingAutomaticPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = DesktopPrivacyImage(id: UUID(), name: "missing")
        let settings = DesktopPrivacySettings(automatic: true, selection: item.selectionID, images: [item])
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
        let library = DesktopPrivacyLibrary(directory: root)
        #expect(library.settings.automatic)
        #expect(library.settings.images.isEmpty)
        #expect(library.settings.selection == DesktopPrivacyPreset.charcoal.id)
    }

    @Test func privacyProtocolCannotBecomeInputOrAcceptContradictoryStatus() throws {
        let request = DesktopPrivacyMessage(action: .request, enabled: true)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(DesktopPrivacyMessage.self, from: data) == request)
        #expect(try !JSONDecoder().decode(DesktopInput.self, from: data).isValid)
        #expect(!DesktopPrivacyMessage(action: .request, enabled: true, active: true).isValid)
        #expect(!DesktopPrivacyMessage(action: .status, enabled: false, active: true).isValid)
        #expect(!DesktopPrivacyMessage(kind: "button", action: .status, enabled: true).isValid)
        #expect(!DesktopPrivacyMessage(action: .status, enabled: true, failure: String(repeating: "x", count: 1025)).isValid)
        #expect(DesktopPrivacyMessage(action: .status, enabled: true, active: false).isValid) // 锁屏暂停。
    }

    @Test @MainActor func viewerUsesHostConfirmationAndClearsPrivacyOnDisconnect() throws {
        let root = DesktopCenter()
        defer { root.shutdown() }
        let viewer = root.prepareViewer(for: .init(id: UUID(), name: "Host"))
        #expect(!viewer.privacySupported)
        // request 消息不能冒充被控端确认。
        viewer.receivePrivacy(.init(action: .request, enabled: true))
        #expect(!viewer.privacySupported && !viewer.privacyActive)
        viewer.receivePrivacy(.init(action: .status, enabled: true, active: false, changing: true))
        #expect(viewer.privacySupported && viewer.privacyChanging && !viewer.privacyActive)
        viewer.receivePrivacy(.init(action: .status, enabled: true, active: true))
        #expect(viewer.privacyActive && !viewer.privacyChanging)
        viewer.disconnect(notify: false)
        #expect(!viewer.privacyActive && !viewer.privacyRequested && !viewer.privacySupported)
        viewer.receivePrivacy(.init(action: .status, enabled: true, active: true))
        #expect(!viewer.privacyActive)
    }

    @Test @MainActor func curtainPreservesWindowIDsWithoutInterceptingFocusAndCleansUp() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let curtain = DesktopPrivacyCurtain()
        defer { curtain.stop() }
        // 不显示到实体屏幕；验证窗口属性与退出热键的完整注册/释放。
        try curtain.show(preset: .charcoal, image: nil, screens: [screen], present: false)
        let window = try #require(curtain.windows.first)
        #expect(!window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents)
        #expect(window.isOpaque && window.frame == screen.frame)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        let ids = curtain.windowIDs
        #expect(ids.count == 1)
        try curtain.show(preset: .forest, image: nil, screens: [screen], present: false)
        #expect(curtain.windowIDs == ids)
        curtain.stop()
        #expect(curtain.windows.isEmpty && curtain.windowIDs.isEmpty)
        // 再次启用能够重新注册热键，不能残留旧注册。
        try curtain.show(preset: .midnight, image: nil, screens: [screen], present: false)
    }

    @Test @MainActor func exportPrivacySettingsPreview() throws {
        guard let output = ProcessInfo.processInfo.environment["TAOSCREEN_PRIVACY_PREVIEW"] else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DesktopPrivacyLibrary(directory: root)
        let center = DesktopCenter()
        defer { center.shutdown() }
        library.setAutomatic(true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: DesktopPrivacySettingsSheet(center: center, library: library)
                .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: output)
            let destination = dark ? url.deletingPathExtension().appendingPathExtension("dark.png") : url
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAOSCREEN_PRIVACY_CAPTURE_CHECK"] == "1"))
    @MainActor func realCaptureExcludesCurtainAndRevealsUnderlyingWindow() async throws {
        // 显式开启，且仅使用已有录屏权限。只短暂显示一个 180×120 的测试色块，不遮黑整个屏幕。
        try #require(CGPreflightScreenCaptureAccess())
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        let rect = NSRect(x: screen.frame.minX + 12, y: screen.frame.minY + 12, width: 180, height: 120)
        let underlying = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        underlying.isReleasedWhenClosed = false; underlying.ignoresMouseEvents = true
        underlying.backgroundColor = .red; underlying.isOpaque = true
        underlying.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        underlying.orderFrontRegardless()
        let curtain = DesktopPrivacyCurtain()
        defer { curtain.stop(); underlying.close() }
        try curtain.show(preset: .forest, image: nil, screens: [screen], present: false)
        let window = try #require(curtain.windows.first)
        window.setFrame(rect, display: true)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width); config.height = Int(screen.frame.height)
        config.showsCursor = false
        let plain = try await DesktopCapture.contentFilter(displayID: displayID, excludingWindowIDs: [])
        let covered = try await SCScreenshotManager.captureImage(contentFilter: plain, configuration: config)
        let excluding = try await DesktopCapture.contentFilter(displayID: displayID, excludingWindowIDs: curtain.windowIDs)
        let revealed = try await SCScreenshotManager.captureImage(contentFilter: excluding, configuration: config)
        let x = Int((rect.minX + 8 - screen.frame.minX) / screen.frame.width * CGFloat(revealed.width))
        let y = Int((screen.frame.maxY - rect.maxY + 8) / screen.frame.height * CGFloat(revealed.height))
        let before = try pixel(covered, x: x, y: y), after = try pixel(revealed, x: x, y: y)
        #expect(before.0 < 100 && before.1 < 100 && before.2 < 100)
        #expect(after.0 > 200 && after.1 < 70 && after.2 < 70)
        let retired = curtain.windowIDs
        curtain.stop()
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await DesktopCapture.contentFilter(displayID: displayID, excludingWindowIDs: retired)
            Issue.record("消失的遮罩窗口必须使排除校验失败")
        } catch { #expect(error.localizedDescription == L10n.text("无法从远程画面排除隐私屏，共享已停止，请重新连接。")) }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    @MainActor private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let bytes = try #require(bitmap.bitmapData)
        memset(bytes, 160, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
