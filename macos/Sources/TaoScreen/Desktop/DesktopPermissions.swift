import AppKit
import Combine
import SwiftUI
import ScreenCaptureKit

enum DesktopPermission: String, CaseIterable, Identifiable {
    case screenRecording, accessibility
    var id: String { rawValue }
    var title: String { self == .screenRecording ? "屏幕与系统音频录制" : "辅助功能与输入控制" }
    var settingsTitle: String { self == .screenRecording ? "录屏与系统录音（屏幕录制）" : "辅助功能" }
    var purpose: String { self == .screenRecording ? "允许对方查看此电脑的屏幕。" : "允许对方操作鼠标键盘、粘贴和接收文件；仅观看不需要。" }
    var settingsURL: URL {
        let pane = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" + pane)!
    }
}

struct DesktopPermissionSnapshot: Equatable {
    let screenRecording: Bool
    let accessibility: Bool
    let postEvents: Bool

    static var current: Self {
        .init(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted(),
              postEvents: CGPreflightPostEventAccess())
    }
    func granted(_ permission: DesktopPermission) -> Bool {
        permission == .screenRecording ? screenRecording : accessibility && postEvents
    }
    func missing(control: Bool) -> [DesktopPermission] {
        DesktopPermission.allCases.filter { ($0 == .screenRecording || control) && !granted($0) }
    }
    func rejectionMessage(control: Bool) -> String? {
        let missing = missing(control: control)
        guard !missing.isEmpty else { return nil }
        return "被控电脑尚未获得“\(missing.map(\.title).joined(separator: "”、“"))”权限。请在被控电脑打开 TaoScreen 的“权限检查”，完成授权并重新检查；如需重启，重开后请重新发起连接。"
    }
}

@MainActor
final class DesktopPermissions: ObservableObject {
    @Published private(set) var snapshot: DesktopPermissionSnapshot
    @Published private(set) var requester: String?
    @Published private(set) var requestedControl = false
    @Published private(set) var message: String?
    @Published private(set) var checking = false
    private var captureDenied = false
    private var captureGeneration = UUID()
    private let read: () -> DesktopPermissionSnapshot
    private let requestAccess: (DesktopPermission) -> Void
    private let openSettings: (URL) -> Bool
    private let verifyCapture: () async throws -> Void

    init(read: @escaping () -> DesktopPermissionSnapshot = { .current },
         request: @escaping (DesktopPermission) -> Void = { permission in
             switch permission {
             case .screenRecording: _ = CGRequestScreenCaptureAccess()
             case .accessibility:
                 _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
             }
         }, openSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         verifyCapture: @escaping () async throws -> Void = { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }) {
        self.read = read; requestAccess = request; self.openSettings = openSettings
        self.verifyCapture = verifyCapture
        snapshot = read()
    }
    func refresh() {
        let current = read()
        snapshot = .init(screenRecording: current.screenRecording && !captureDenied,
                         accessibility: current.accessibility, postEvents: current.postEvents)
    }
    func recheck() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        message = nil
        if captureDenied, read().screenRecording {
            let generation = captureGeneration
            do {
                try await verifyCapture()
                if generation == captureGeneration { captureDenied = false }
            }
            catch { message = "屏幕采集授权仍未生效：\(error.localizedDescription)。请确认系统设置后重启 TaoScreen。" }
        }
        refresh()
    }
    static func isCapturePermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue
    }
    func recordCaptureDenial() {
        captureGeneration = UUID()
        captureDenied = true
        refresh()
        message = "系统拒绝了屏幕采集。即使权限列表已勾选，也需要重新检查；若仍未生效，请重启 TaoScreen。"
    }
    func request(_ permission: DesktopPermission) {
        refresh()
        guard !snapshot.granted(permission) else { return }
        requestAccess(permission)
        // 系统提示可能异步完成；不能把“已申请”当作“已授权”。
        refresh()
    }
    func open(_ permission: DesktopPermission) {
        message = nil
        if !openSettings(permission.settingsURL) {
            message = "无法打开系统设置。请手动进入“系统设置 → 隐私与安全性 → \(permission.settingsTitle)”。"
        }
    }
    func check(control: Bool, prompt: Bool) -> Bool {
        refresh()
        if prompt, let first = snapshot.missing(control: control).first { request(first) }
        return snapshot.missing(control: control).isEmpty
    }
    func remind(requester: String, control: Bool) {
        self.requester = requester; requestedControl = control
    }
    func requireControl(_ value: Bool) { requestedControl = value }
    func clearReminder() { requester = nil; requestedControl = false }
}

enum DesktopPermissionRelaunch {
    @MainActor static func prepareForTermination(windows: [NSWindow]) {
        // 仅在用户确认重启之后解除模态窗口的退出阻止。
        for window in windows { window.preventsApplicationTerminationWhenModal = false }
    }
    static func process(app: URL, pid: Int32) throws -> Process {
        guard app.isFileURL, app.pathExtension == "app", pid > 0 else { throw CloudError("无法确认当前应用的位置，未执行重启。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 等待当前进程正常结束，再打开同一个应用；不会强杀或打开另一个副本。
        process.arguments = ["-c", "attempt=0; while /bin/kill -0 \"$1\" 2>/dev/null; do attempt=$((attempt + 1)); [ \"$attempt\" -lt 150 ] || exit 1; /bin/sleep 0.2; done; /usr/bin/open \"$2\"", "taoscreen-relaunch", String(pid), app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

struct DesktopPermissionSection: View {
    @ObservedObject var permissions: DesktopPermissions
    let control: Bool
    let restart: () -> Void
    @State private var confirmRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("此电脑的权限", systemImage: "lock.shield").font(.headline)
                Spacer()
                Button(permissions.checking ? "正在检查…" : "重新检查") { Task { await permissions.recheck() } }
                    .disabled(permissions.checking)
            }
            ForEach(DesktopPermission.allCases) { permission in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: permissions.snapshot.granted(permission) ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(permissions.snapshot.granted(permission) ? .green : .orange)
                        Text(permission.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(permissions.snapshot.granted(permission) ? "已生效" : permission == .accessibility && !control ? "仅观看不需要" : "未生效")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                    if !permissions.snapshot.granted(permission) {
                        HStack {
                            Button("申请\(permission == .screenRecording ? "录屏" : "辅助功能")权限…") { permissions.request(permission) }
                            Button("打开\(permission == .screenRecording ? "录屏" : "辅助功能")设置") { permissions.open(permission) }
                        }.controlSize(.small)
                    }
                }
            }
            Text("在系统设置中允许 TaoScreen，回到这里后会重新检查。若已允许但仍显示未生效，请重启 TaoScreen；安装位置或签名变更后，可能需要在权限列表中重新添加当前应用。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(permissions.snapshot.missing(control: control).isEmpty ? "所需权限已生效" : "请在此电脑完成授权", systemImage: permissions.snapshot.missing(control: control).isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(permissions.snapshot.missing(control: control).isEmpty ? .green : .orange)
                Spacer()
                Button("重启 TaoScreen…") { confirmRestart = true }.controlSize(.small)
            }
            if let message = permissions.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { permissions.refresh() }
        .onChange(of: control) { _, _ in permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
        .alert("重启 TaoScreen？", isPresented: $confirmRestart) {
            Button("取消", role: .cancel) { }
            Button("退出并重新打开", role: .destructive, action: restart)
        } message: {
            Text("将结束当前远程连接、待确认请求，并放弃未保存的设置。重新打开后会重新检查权限，对方需重新发起连接。")
        }
    }
}

struct DesktopPermissionSettingsView: View {
    @ObservedObject var center: DesktopCenter
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("远程桌面权限检查", systemImage: "lock.shield").font(.title2.bold())
            Text("其他设备连接此电脑时，权限需要在此 Mac 上开启；连接另一台电脑时，请对方在被控电脑完成授权。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DesktopPermissionSection(permissions: center.permissions, control: true, restart: center.restartForPermissions)
            if let message = center.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("完成授权不会自动接受旧请求。请让对方重新连接，再按本机的共享设置确认。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 570)
    }
}
