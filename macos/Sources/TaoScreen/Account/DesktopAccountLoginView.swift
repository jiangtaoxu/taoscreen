import SwiftUI

struct DesktopAccountLoginView: View {
    @ObservedObject var account: DesktopAccountState
    let openPasswordLogin: () -> Void
    @State private var retry = 0

    private struct Lookup: Equatable {
        let server: String
        let retry: Int
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                loginPanel
                    .frame(maxWidth: 420)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewport.size.height)
            }
        }
        .task(id: Lookup(server: account.serverText, retry: retry)) { await account.loadProviders() }
    }

    private var loginPanel: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(DesktopWorkspaceStyle.accent)
                    .frame(width: 58, height: 58)
                    .background(DesktopWorkspaceStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                Text(L10n.text("登录 TaoScreen")).font(.title.weight(.semibold))
                Text(L10n.text("在两台 Mac 上登录同一个账号，即可连接。"))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(account.enabledProviders) { provider in
                    Button { Task { await account.signIn(provider: provider.id) } } label: {
                        HStack(spacing: 10) {
                            providerLogo(provider.id)
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(L10n.text("使用 \(provider.id.title) 登录"))
                        }
                    }
                    .buttonStyle(DesktopProviderButtonStyle())
                    .disabled(account.busy)
                }
                if account.enabledProviders.isEmpty { loginOptionsStatus }
            }
            if let provider = account.loginConflictProvider {
                VStack(spacing: 8) {
                    Text(L10n.text("此邮箱已开通 TaoScreen 账号")).font(.headline)
                    Text(L10n.text("账号开通后可能从未登录。请先用原来的方式登录，再从右上角账号菜单绑定 \(provider.title)。"))
                        .foregroundStyle(.secondary)
                    if account.allowsPasswordLogin {
                        Button(L10n.text("使用邮箱和密码登录"), action: openPasswordLogin).disabled(account.busy)
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            if let message = account.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if account.busy {
                DesktopLoginProgress(account: account)
            } else if account.account != nil {
                Button(L10n.text("退出当前账号以切换登录")) { Task { await account.signOut() } }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .desktopWorkspacePanel(padding: 28, emphasized: true)
    }

    @ViewBuilder private var loginOptionsStatus: some View {
        if account.serverText.isEmpty {
            Text(L10n.text("请在右上角的设置中配置登录服务器。")).foregroundStyle(.secondary)
        } else if account.loginMethodsUnavailable {
            Text(L10n.text("无法检测当前服务器的登录方式。")).foregroundStyle(.secondary)
            Button(L10n.text("重试")) { retry += 1 }
        } else if account.providersLoaded {
            Text(account.allowsPasswordLogin
                 ? L10n.text("请在右上角的设置中使用邮箱和密码登录。")
                 : L10n.text("当前服务器未启用登录方式，请联系管理员。"))
                .foregroundStyle(.secondary)
        } else {
            ProgressView(L10n.text("正在检查登录方式…")).controlSize(.small)
        }
    }

    private func providerLogo(_ provider: DesktopLoginProvider.ID) -> Image {
        let name = provider == .google ? "GoogleSignInLogo" : "GitHubSignInLogo"
        #if SWIFT_PACKAGE
        return Image(name, bundle: .module)
        #else
        return Image(name)
        #endif
    }
}

private struct DesktopProviderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .frame(width: 246, height: 42)
            .background(configuration.isPressed ? Color(white: 0.92) : .white, in: shape)
            .overlay(shape.strokeBorder(Color(red: 0.45, green: 0.47, blue: 0.46)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct DesktopLoginSettings: View {
    @ObservedObject var account: DesktopAccountState
    @Environment(\.dismiss) private var dismiss
    @State private var usesDefaultServer: Bool
    @State private var customServer: String
    @State private var showsPasswordForm: Bool
    @State private var selectionError: String?

    init(account: DesktopAccountState, startsWithPassword: Bool) {
        self.account = account
        let usesDefault = !DesktopAccountState.defaultServer.isEmpty
            && account.serverText == DesktopAccountState.defaultServer
        _usesDefaultServer = State(initialValue: usesDefault)
        _customServer = State(initialValue: usesDefault ? "" : account.serverText)
        _showsPasswordForm = State(initialValue: startsWithPassword)
    }

    private var selectedServer: String {
        usesDefaultServer ? DesktopAccountState.defaultServer : customServer
    }

    private var selectionChanged: Bool { selectedServer != account.serverText }

    var body: some View {
        Group {
            if showsPasswordForm {
                DesktopPasswordLoginView(account: account) { showsPasswordForm = false }
            } else {
                serverSettings
            }
        }
        .padding(24)
        .frame(width: 400)
        .interactiveDismissDisabled(account.busy)
        .onChange(of: account.needsLogin) { _, needsLogin in
            if !needsLogin { dismiss() }
        }
    }

    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("登录设置")).font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                if !DesktopAccountState.defaultServer.isEmpty {
                    Picker(L10n.text("登录服务器"), selection: $usesDefaultServer) {
                        Text(L10n.text("默认服务器")).tag(true)
                        Text(L10n.text("自定义服务器")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if !usesDefaultServer {
                    Text(L10n.text("服务器地址")).font(.subheadline)
                    TextField("https://", text: $customServer)
                        .textContentType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("服务器地址"))
                }
            }
            .disabled(account.busy || account.account != nil)
            if account.account != nil {
                Text(L10n.text("退出当前账号后可切换服务器。")).font(.caption).foregroundStyle(.secondary)
            }
            if account.allowsPasswordLogin && !selectionChanged {
                Divider()
                Button(L10n.text("使用邮箱和密码登录")) { showsPasswordForm = true }
                    .disabled(account.busy)
            }
            if let selectionError { Text(selectionError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.text("取消"), role: .cancel) { dismiss() }
                Button(selectionChanged ? L10n.text("保存") : L10n.text("完成"), action: applySelection)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: selectedServer) { _, _ in selectionError = nil }
    }

    private func applySelection() {
        do {
            if selectionChanged { try account.selectServer(selectedServer) }
            dismiss()
        } catch { selectionError = error.localizedDescription }
    }
}

private struct DesktopPasswordLoginView: View {
    @ObservedObject var account: DesktopAccountState
    let goBack: () -> Void
    @State private var email = ""
    @State private var password = ""

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSignIn: Bool {
        account.allowsPasswordLogin && !account.busy && !trimmedEmail.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("邮箱登录")).font(.title2.bold())
            Group {
                TextField(L10n.text("邮箱"), text: $email).textContentType(.username)
                SecureField(L10n.text("密码"), text: $password).textContentType(.password).privacySensitive()
            }
            .disabled(account.busy)
            if let message = account.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if account.busy { DesktopLoginProgress(account: account) }
            HStack {
                Button(L10n.text("返回"), action: goBack).disabled(account.busy)
                Spacer()
                Button(L10n.text("登录"), action: signIn).keyboardShortcut(.defaultAction).disabled(!canSignIn)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func signIn() {
        guard canSignIn else { return }
        let submittedEmail = trimmedEmail
        let submittedPassword = password
        password = ""
        Task { await account.signIn(email: submittedEmail, password: submittedPassword) }
    }
}

private struct DesktopLoginProgress: View {
    @ObservedObject var account: DesktopAccountState

    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(account.authorizingInBrowser ? L10n.text("请在浏览器中完成授权…") : L10n.text("正在处理账号请求…"))
            Button(L10n.text("取消")) { account.cancelLogin() }
        }
    }
}
