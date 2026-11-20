import AppKit
import SwiftUI

@main
struct TaoScreenApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate
    @StateObject private var account = DesktopAccountState()

    var body: some Scene {
        Window("TaoScreen", id: "main") {
            DesktopRootView(account: account)
                .frame(minWidth: 820, minHeight: 560)
                .task { DesktopCenter.shared.attach(cloud: account); DesktopUpdates.shared.startMonitoring() }
        }
        .defaultSize(width: 960, height: 640)
        .commands { CommandGroup(after: .appInfo) { UpdateMenuButton() } }
        Window("端口映射", id: "ports") {
            DesktopPortForwardingSheet(service: DesktopCenter.shared.portService)
                .task { DesktopCenter.shared.attach(cloud: account) }
        }.defaultSize(width: 1040, height: 660)
        Settings {
            Form {
                RemoteAvailabilitySettings()
                DesktopUpdateSettings()
            }.formStyle(.grouped).frame(width: 480, height: 390)
        }
        MenuBarExtra("TaoScreen", systemImage: "display.2") {
            DesktopMenu()
        }
    }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DesktopCenter.shared.portService.shutdown()
        DesktopCenter.shared.shutdown()
        DesktopDirectService.shared.shutdown()
        RemoteAvailability.shared.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct DesktopRootView: View {
    @ObservedObject var account: DesktopAccountState
    @State private var showingAccount = false
    @State private var loginSheet: LoginSheet?
    @State private var selectedMode: ConnectionMode = .direct

    private enum ConnectionMode: CaseIterable, Hashable {
        case direct, account

        var title: String { self == .direct ? "免登录直连" : "账号直连" }
        var symbol: String { self == .direct ? "point.3.connected.trianglepath.dotted" : "person.crop.circle" }
    }
    private enum LoginSheet: String, Identifiable {
        case settings, password
        var id: Self { self }
    }
    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            DesktopGlobalStatus()
            DesktopGlobalStatus(center: DesktopDirectService.shared.center)
            DesktopPortRequestBanner(service: DesktopCenter.shared.portService)
            switch selectedMode {
            case .direct: DesktopDirectView(service: .shared)
            case .account:
                if account.needsLogin {
                    DesktopAccountLoginView(account: account) { loginSheet = .password }
                } else {
                    DesktopView(center: .shared)
                }
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [DesktopWorkspaceStyle.accent.opacity(0.13), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .tint(DesktopWorkspaceStyle.accent)
        .toolbar {
            ToolbarItem { DesktopUpdateButton() }
        }
        .sheet(item: $loginSheet) { sheet in
            DesktopLoginSettings(account: account, startsWithPassword: sheet == .password)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Button { selectedMode = mode } label: {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                    .buttonStyle(DesktopModeButtonStyle(selected: selectedMode == mode))
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            }
            .padding(4)
            .background(DesktopWorkspaceStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("连接方式")
            Spacer()
            accountControl
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var accountControl: some View {
        if let current = account.account, !account.needsLogin {
            Button { showingAccount = true } label: {
                Label(current.email, systemImage: "person.crop.circle")
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 216, alignment: .trailing)
            .popover(isPresented: $showingAccount) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.email).font(.headline)
                    Text("已绑定的登录方式").foregroundStyle(.secondary)
                    ForEach(account.identities) { identity in
                        Label("\(identity.provider.title) · \(identity.email)", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    ForEach(account.enabledProviders) { provider in
                        if !account.identities.contains(where: { $0.provider == provider.id }) {
                            Button("绑定 \(provider.id.title)") { Task { await account.link(provider: provider.id) } }
                                .disabled(account.busy)
                        }
                    }
                    if account.busy { Button("取消登录") { account.cancelLogin() } }
                    if let message = account.message { Text(message).foregroundStyle(.red) }
                    Button("退出账号") { Task { await account.signOut() } }.disabled(account.busy)
                }
                .padding(20).frame(minWidth: 360)
                .task { await account.loadIdentities(); await account.loadProviders() }
            }
        } else {
            Button { loginSheet = .settings } label: {
                Label("账号登录设置", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .help("账号登录设置")
            .disabled(account.busy)
        }
    }
}

private struct DesktopModeButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? DesktopWorkspaceStyle.accent : Color(nsColor: .secondaryLabelColor))
            .frame(width: 128, height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesktopWorkspaceStyle.surface)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

enum DesktopWorkspaceStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.52, green: 0.74, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.12, green: 0.35, blue: 0.69, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
}

extension View {
    func desktopWorkspacePanel(padding: CGFloat = 16, emphasized: Bool = false) -> some View {
        let outline = emphasized ? DesktopWorkspaceStyle.accent.opacity(0.30) : Color(nsColor: .separatorColor)
        let shape = RoundedRectangle(cornerRadius: 14)
        return self.padding(padding)
            .background(DesktopWorkspaceStyle.surface, in: shape)
            .overlay { shape.strokeBorder(outline).allowsHitTesting(false) }
    }
}

private struct DesktopMenu: View {
    @ObservedObject private var center = DesktopCenter.shared
    @ObservedObject private var direct = DesktopDirectService.shared.center
    @ObservedObject private var directService = DesktopDirectService.shared
    @ObservedObject private var permissions = DesktopPermissions.shared
    @Environment(\.openWindow) private var openWindow
    private var needsHostPermissionAttention: Bool {
        (center.enabled || directService.unattendedEnabled || directService.unattendedPasswordSettings.enabled || directService.receiving)
            && permissions.snapshot.hasAnyMissing
    }
    var body: some View {
        Text(center.status)
        if needsHostPermissionAttention {
            Button("⚠️ 缺少被控权限（点击打开主窗口授权）") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Button("端口映射…") { center.portService.activateMappingWindow(); openWindow(id: "ports"); NSApp.activate(ignoringOtherApps: true) }
        Button("显示主窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if center.isHost { Button("停止共享", role: .destructive) { center.disconnect() } }
        if direct.isHost { Button("停止免登录共享", role: .destructive) { direct.disconnect() } }
        Toggle("开启远程桌面", isOn: $center.enabled)
        Divider()
        UpdateMenuButton()
        Button("退出 TaoScreen") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct UpdateMenuButton: View {
    @ObservedObject private var updates = DesktopUpdates.shared
    var body: some View {
        Button("检查更新…") { updates.downloadUpdate() }
            .disabled(!updates.canCheck)
    }
}
