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
    @State private var loginEmail = ""
    @State private var loginPassword = ""
    @State private var selectedMode: ConnectionMode?

    private enum ConnectionMode: Hashable { case direct, account }
    private var mode: ConnectionMode { selectedMode ?? (account.needsLogin ? .direct : .account) }

    var body: some View {
        VStack(spacing: 0) {
            DesktopGlobalStatus()
            DesktopGlobalStatus(center: DesktopDirectService.shared.center)
            DesktopPortRequestBanner(service: DesktopCenter.shared.portService)
            Picker("连接方式", selection: Binding(get: { mode }, set: { selectedMode = $0 })) {
                Text("免登录直连").tag(ConnectionMode.direct)
                Text("账号连接").tag(ConnectionMode.account)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 260).padding(.top, 17)
            switch mode {
            case .direct: DesktopDirectView(service: .shared)
            case .account:
                if account.needsLogin { loginForm }
                else { DesktopView(center: .shared) }
            }
        }
        .toolbar {
            ToolbarItem {
                DesktopUpdateButton()
            }
            ToolbarItem {
                if let current = account.account, !account.needsLogin {
                    Button { showingAccount = true } label: { Label(current.email, systemImage: "person.crop.circle") }
                        .popover(isPresented: $showingAccount) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(current.email).font(.headline)
                                Text(current.server).font(.caption).textSelection(.enabled)
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
                            }.padding(20).frame(minWidth: 360)
                                .task { await account.loadIdentities(); await account.loadProviders() }
                        }
                }
            }
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("TaoScreen", systemImage: "display.2").font(.largeTitle.bold())
            Text("两台 Mac 登录同一个独立桌面账号，即可连接。")
                .foregroundStyle(.secondary)
            TextField("服务地址，例如 https://desktop.example.com", text: $account.serverText).disabled(account.busy)
            if account.allowsPasswordLogin {
                TextField("邮箱", text: $loginEmail).textContentType(.username).disabled(account.busy)
                SecureField("密码", text: $loginPassword).textContentType(.password).privacySensitive()
                    .disabled(account.busy).onSubmit(signInWithPassword)
                Button(action: signInWithPassword) {
                    Label("使用邮箱和密码登录", systemImage: "key")
                        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderedProminent)
                    .disabled(account.busy || loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loginPassword.isEmpty)
            }
            ForEach(account.enabledProviders) { provider in
                Button { Task { await account.signIn(provider: provider.id) } } label: {
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text("使用 \(provider.id.title) 登录")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(.vertical, 6).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .disabled(account.busy)
            }
            if account.providersLoaded && !account.allowsPasswordLogin && account.enabledProviders.isEmpty {
                Text("服务端尚未启用登录方式，请联系管理员。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = account.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if account.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(account.authorizingInBrowser ? "请在浏览器中完成授权…" : "正在处理账号请求…")
                    Button("取消") { account.cancelLogin() }
                }
            } else if account.account != nil {
                Button("退出当前账号以切换登录") { Task { await account.signOut() } }
            }
            if account.allowsPasswordLogin {
                Text("如需开通本地账号，请联系服务器管理员。").font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
            .padding(36).frame(maxWidth: 540).frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: account.serverText) { await account.loadProviders() }
            .onChange(of: account.serverText) { loginPassword = "" }
            .onDisappear { loginPassword = "" }
    }

    private func signInWithPassword() {
        let email = loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.allowsPasswordLogin, !account.busy, !email.isEmpty, !loginPassword.isEmpty else { return }
        let password = loginPassword
        loginPassword = ""
        Task { await account.signIn(email: email, password: password) }
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
