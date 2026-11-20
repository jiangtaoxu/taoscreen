import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import TaoScreen

struct DesktopPermissionTests {
    @Test func viewingNeedsScreenAccessAndControlNeedsBothInputChecks() {
        for screen in [false, true] {
            for accessibility in [false, true] {
                for post in [false, true] {
                    let state = DesktopPermissionSnapshot(screenRecording: screen, accessibility: accessibility, postEvents: post)
                    #expect(state.missing(control: false).isEmpty == screen)
                    #expect(state.missing(control: true).isEmpty == (screen && accessibility && post))
                    #expect((state.rejectionMessage(control: true) == nil) == state.missing(control: true).isEmpty)
                }
            }
        }
    }

    @Test @MainActor func remoteChecksNeverPromptAndRequestsAreNotTreatedAsGrants() {
        var current = DesktopPermissionSnapshot(screenRecording: false, accessibility: false, postEvents: false)
        var prompts: [DesktopPermission] = []
        let permissions = DesktopPermissions(read: { current }, request: { prompts.append($0) })
        permissions.remind(requester: "仅观看设备", control: false)
        permissions.refresh()
        #expect(!permissions.requestedControl)
        #expect(!permissions.check(control: true, prompt: false))
        #expect(prompts.isEmpty)
        #expect(!permissions.check(control: true, prompt: true))
        #expect(prompts == [.screenRecording])
        #expect(!permissions.snapshot.screenRecording)
        current = .init(screenRecording: true, accessibility: false, postEvents: false)
        permissions.refresh()
        #expect(permissions.check(control: false, prompt: false))
        #expect(!permissions.requestedControl)
        #expect(!permissions.check(control: true, prompt: true))
        #expect(prompts == [.screenRecording, .accessibility])
        current = .init(screenRecording: true, accessibility: true, postEvents: false)
        permissions.refresh()
        #expect(!permissions.snapshot.granted(.accessibility))
        current = .init(screenRecording: true, accessibility: true, postEvents: true)
        permissions.refresh()
        #expect(permissions.check(control: true, prompt: false))
        current = .init(screenRecording: false, accessibility: true, postEvents: true)
        permissions.refresh()
        #expect(!permissions.check(control: false, prompt: false))
    }

    @Test @MainActor func captureDenialNeedsRealRevalidationAndIgnoresOldSuccess() async {
        var fail = true
        var verify: CheckedContinuation<Void, Never>?
        let permissions = DesktopPermissions(read: { .init(screenRecording: true, accessibility: true, postEvents: true) },
                                            request: { _ in Issue.record("重新检查不应申请权限") }, verifyCapture: {
            if fail { throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue) }
            await withCheckedContinuation { verify = $0 }
        })
        permissions.recordCaptureDenial()
        await permissions.recheck()
        #expect(!permissions.snapshot.screenRecording && permissions.message != nil)
        fail = false
        let old = Task { await permissions.recheck() }
        while verify == nil { await Task.yield() }
        permissions.recordCaptureDenial()
        verify?.resume(); verify = nil
        await old.value
        #expect(!permissions.snapshot.screenRecording)
        let fresh = Task { await permissions.recheck() }
        while verify == nil { await Task.yield() }
        verify?.resume(); verify = nil
        await fresh.value
        #expect(permissions.snapshot.screenRecording)
        #expect(permissions.message == nil)
        #expect(!DesktopPermissions.isCapturePermissionError(CloudError("所选屏幕已断开")))
    }

    @Test @MainActor func settingsOpenFailureIsReportedAndDoesNotChangePermissionState() {
        var opened: [URL] = []
        let permissions = DesktopPermissions(read: { .init(screenRecording: false, accessibility: false, postEvents: false) },
                                            request: { _ in Issue.record("打开设置不应自动申请授权") },
                                            openSettings: { opened.append($0); return false })
        permissions.open(.screenRecording)
        #expect(opened == [DesktopPermission.screenRecording.settingsURL])
        #expect(permissions.message == L10n.text("无法打开系统设置。请手动进入“系统设置 → 隐私与安全性 → \(DesktopPermission.screenRecording.settingsTitle)”。"))
        #expect(!permissions.snapshot.screenRecording)
        let process = try? DesktopPermissionRelaunch.process(app: URL(fileURLWithPath: "/Applications/Test $(echo wrong).app"), pid: 123)
        #expect(process?.arguments?.suffix(2) == ["123", "/Applications/Test $(echo wrong).app"])
        #expect(throws: (any Error).self) { try DesktopPermissionRelaunch.process(app: URL(string: "https://example.com/Test.app")!, pid: 123) }
        let modal = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        modal.isReleasedWhenClosed = false
        defer { modal.close() }
        modal.preventsApplicationTerminationWhenModal = true
        DesktopPermissionRelaunch.prepareForTermination(windows: [modal])
        #expect(!modal.preventsApplicationTerminationWhenModal)
    }

    @Test @MainActor func remotePermissionReasonsSurviveRejectAndCaptureEnd() async throws {
        let root = DesktopCenter()
        defer { root.shutdown() }
        let peer = DesktopPeer(id: UUID(), name: "测试电脑")
        let reason = DesktopPermissionSnapshot(screenRecording: false, accessibility: false, postEvents: false).rejectionMessage(control: true)!
        for type in ["reject", "end"] {
            let viewer = root.prepareViewer(for: peer)
            let id = try #require(viewer.sessionID)
            let signal = DesktopSignal(type: type, id: id, from: peer.id, payload: .init(message: reason))
            let roundTrip = try JSONDecoder().decode(DesktopSignal.self, from: JSONEncoder().encode(signal))
            await viewer.receive(roundTrip)
            #expect(viewer.sessionID == nil)
            #expect(root.message?.contains(DesktopPermission.screenRecording.title) == true)
            #expect(root.message?.contains(DesktopPermission.accessibility.title) == true)
        }
    }

    @Test @MainActor func exportPermissionGuidePreview() throws {
        guard let output = ProcessInfo.processInfo.environment["TAOSCREEN_PERMISSION_PREVIEW"] else { return }
        _ = NSApplication.shared
        let permissions = DesktopPermissions(read: { .init(screenRecording: false, accessibility: false, postEvents: false) }, request: { _ in })
        let view = NSHostingView(rootView: DesktopPermissionSection(permissions: permissions, control: true, restart: { })
            .padding(20).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }

    @Test @MainActor func detailReasonAndRequestGuidanceClarifyMissingPermissions() {
        let none = DesktopPermissionSnapshot(screenRecording: false, accessibility: false, postEvents: false)
        #expect(none.hasAnyMissing)
        #expect(none.missingAll == [.screenRecording, .accessibility])
        #expect(none.detailReason(for: .screenRecording) == L10n.text("未授权，其他设备无法查看此电脑的屏幕画面与系统声音。"))
        #expect(none.detailReason(for: .accessibility) == L10n.text("未授权，其他设备无法操作鼠标、键盘、粘贴和拖放文件（仅观看模式不需要）。"))

        let partialInput = DesktopPermissionSnapshot(screenRecording: true, accessibility: true, postEvents: false)
        #expect(partialInput.hasAnyMissing)
        #expect(partialInput.detailReason(for: .accessibility).contains(L10n.text("投递输入事件")))

        let ready = DesktopPermissionSnapshot(screenRecording: true, accessibility: true, postEvents: true)
        #expect(!ready.hasAnyMissing)
        #expect(ready.detailReason(for: .screenRecording) == L10n.text("已授权，其他设备可以查看此电脑的屏幕与系统声音。"))
        #expect(ready.detailReason(for: .accessibility) == L10n.text("已授权，其他设备可以控制此电脑的鼠标和键盘。"))

        let permissions = DesktopPermissions(read: { none }, request: { _ in })
        permissions.request(.screenRecording)
        #expect(permissions.message == L10n.text("已发起“屏幕与系统音频录制”授权请求。如系统未自动弹窗，请点击“打开录屏设置”手动勾选 TaoScreen；首次开启后通常需重启 TaoScreen 才会生效。"))
        permissions.request(.accessibility)
        #expect(permissions.message == L10n.text("已发起“辅助功能”授权请求。如系统未自动弹窗，请点击“打开辅助功能设置”手动勾选 TaoScreen。"))
    }
}
