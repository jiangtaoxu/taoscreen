import AppKit
import Combine
import Foundation

/// 只管理独立桌面账号；不启动笔记同步，也不读取 Berth 数据。
@MainActor
final class DesktopAccountState: ObservableObject {
    static let accountKey = "taoscreen.account"
    private static let serverKey = "taoscreen.server"
    static let defaultServer = (Bundle.main.object(forInfoDictionaryKey: "TaoScreenDefaultServerURL") as? String)
        .flatMap { try? CloudCoding.serverURL($0) }?.absoluteString ?? ""
    @Published private(set) var serverText: String
    @Published private(set) var account: CloudAccount?
    @Published private(set) var needsLogin = true
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var loginConflictProvider: DesktopLoginProvider.ID?
    @Published private var loginMethods: DesktopLoginMethods?
    @Published private(set) var loginMethodsUnavailable = false
    @Published private(set) var authorizingInBrowser = false
    private var loginMethodsServer: URL?
    private var currentLoginMethods: DesktopLoginMethods? {
        guard let loginMethodsServer, (try? CloudCoding.serverURL(serverText)) == loginMethodsServer else { return nil }
        return loginMethods
    }
    var providersLoaded: Bool { currentLoginMethods != nil }
    var enabledProviders: [DesktopLoginProvider] { currentLoginMethods?.providers.filter(\.enabled) ?? [] }
    var allowsPasswordLogin: Bool { currentLoginMethods?.passwordLogin == true }
    @Published private(set) var identities: [DesktopLinkedIdentity] = []
    private let browser = DesktopOAuthBrowser()
    private var loginCancelled = false
    private var client: DesktopAPI?
    private let defaults: UserDefaults
    private let fetchLoginMethods: (URL) async throws -> DesktopLoginMethods
    private let deviceID: UUID
    var peerClient: DesktopAPI? { needsLogin ? nil : client }

    init(defaults: UserDefaults = DesktopRuntime.defaults,
         fetchLoginMethods: @escaping (URL) async throws -> DesktopLoginMethods = { server in
             let api = DesktopAPI(server: server)
             try await api.verifyService()
             return try await api.loginMethods()
         }) {
        self.defaults = defaults
        self.fetchLoginMethods = fetchLoginMethods
        serverText = defaults.string(forKey: Self.serverKey) ?? Self.defaultServer
        if let stored = defaults.string(forKey: "taoscreen.deviceID") {
            guard let id = UUID(uuidString: stored) else {
                fatalError("独立桌面设备标识损坏，请检查应用偏好，拒绝自动替换设备身份。")
            }
            deviceID = id
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString.lowercased(), forKey: "taoscreen.deviceID")
        }
        do {
            guard let data = defaults.data(forKey: Self.accountKey) else { return }
            let saved = try JSONDecoder().decode(CloudAccount.self, from: data)
            account = saved
            serverText = saved.server
            guard let credentials = try CloudKeychain.read(saved.id) else { return }
            guard credentials.account == saved, credentials.deviceID == deviceID else {
                throw CloudError("登录凭据与当前账号或设备不匹配，请重新登录。")
            }
            client = DesktopAPI(server: try CloudCoding.serverURL(saved.server), credentials: credentials)
            needsLogin = false
        } catch { message = error.localizedDescription }
    }

    func selectServer(_ text: String) throws {
        let server = try CloudCoding.serverURL(text)
        guard server.absoluteString != serverText else { return }
        guard !busy, account == nil else { throw CloudError("请先退出当前账号，再切换登录服务器。") }
        defaults.set(server.absoluteString, forKey: Self.serverKey)
        loginMethods = nil
        loginMethodsServer = nil
        loginMethodsUnavailable = false
        message = nil
        loginConflictProvider = nil
        serverText = server.absoluteString
    }

    func loadProviders() async {
        guard !Task.isCancelled, !serverText.isEmpty else { return }
        let requestedServer = serverText
        loginMethods = nil
        loginMethodsServer = nil
        loginMethodsUnavailable = false
        do {
            let server = try CloudCoding.serverURL(requestedServer)
            let result = try await fetchLoginMethods(server)
            try Task.checkCancellation()
            guard serverText == requestedServer else { return }
            loginMethodsServer = server
            loginMethods = result
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled && serverText == requestedServer { loginMethodsUnavailable = true }
        }
    }

    func signIn(provider: DesktopLoginProvider.ID) async {
        await authenticate(provider: provider, linking: false)
    }

    func signIn(email: String, password: String) async {
        guard !busy, allowsPasswordLogin else { return }
        busy = true
        message = nil
        loginConflictProvider = nil
        loginCancelled = false
        defer { busy = false }
        do {
            let server = try CloudCoding.serverURL(serverText)
            let api = DesktopAPI(server: server)
            try await api.verifyService()
            guard !loginCancelled else { throw CancellationError() }
            let value = try await api.login(email: email, password: password, deviceID: deviceID, name: deviceName)
            try await completeSignIn(value, api: api, server: server)
        } catch is CancellationError { message = "已取消登录。" }
        catch { message = error.localizedDescription }
    }

    private var deviceName: String {
        let name = (Host.current().localizedName ?? "Mac").trimmingCharacters(in: .whitespacesAndNewlines)
        var limited = ""
        for character in name {
            if limited.utf8.count + String(character).utf8.count > 120 { break }
            limited.append(character)
        }
        return limited.isEmpty ? "Mac" : limited
    }

    func link(provider: DesktopLoginProvider.ID) async {
        await authenticate(provider: provider, linking: true)
    }

    func cancelLogin() {
        loginCancelled = true
        browser.cancel()
    }

    private func authenticate(provider: DesktopLoginProvider.ID, linking: Bool) async {
        guard !busy, enabledProviders.contains(where: { $0.id == provider }) else { return }
        busy = true
        message = nil
        loginConflictProvider = nil
        loginCancelled = false
        authorizingInBrowser = true
        defer {
            authorizingInBrowser = false
            busy = false
        }
        do {
            let server = try CloudCoding.serverURL(linking ? (account?.server ?? "") : serverText)
            let api: DesktopAPI
            if linking {
                guard let current = peerClient else { throw CloudError("请先登录再绑定账号。") }
                api = current
            } else { api = DesktopAPI(server: server) }
            try await api.verifyService()
            let login = try DesktopOAuthLogin()
            let url = try await api.beginOAuth(login, provider: provider, deviceID: deviceID,
                name: deviceName, linking: linking)
            guard !loginCancelled else { throw CancellationError() }
            let callback = try await browser.authenticate(url, login: login)
            authorizingInBrowser = false
            let code = try login.code(from: callback)
            guard !loginCancelled else { throw CancellationError() }
            if linking {
                try await api.exchangeOAuthLink(login, provider: provider, code: code)
                await loadIdentities()
                message = "已绑定 \(provider.title)，两种登录方式现在使用同一个 TaoScreen 账号。"
                return
            }
            let value = try await api.exchangeOAuth(login, provider: provider, code: code, deviceID: deviceID)
            try await completeSignIn(value, api: api, server: server)
        } catch is CancellationError { message = "已取消登录。" }
        // 旧版服务端在登录兑换时也使用 identity_conflict 表示邮箱已占用。
        catch let error as CloudAPIError where !linking && ["email_already_registered", "identity_conflict"].contains(error.code) {
            loginConflictProvider = provider
        }
        catch { message = error.localizedDescription }
    }

    private func completeSignIn(_ value: CloudCredentials, api: DesktopAPI, server: URL) async throws {
        guard !loginCancelled, (try? CloudCoding.serverURL(serverText)) == server else {
            try await api.revokeUnacceptedCredentials(value)
            throw CancellationError()
        }
        if let previous = account, previous.id != value.account.id {
            try await api.revokeUnacceptedCredentials(value)
            throw CloudError("本次登录与已保存的 TaoScreen 账号不同。请先退出当前账号，再切换账号。")
        }
        let encodedAccount = try JSONEncoder().encode(value.account)
        do { try await api.acceptCredentials(value) }
        catch {
            try? await api.revokeUnacceptedCredentials(value)
            throw error
        }
        DesktopCenter.shared.shutdown()
        client = api
        account = value.account
        needsLogin = false
        defaults.set(encodedAccount, forKey: Self.accountKey)
        defaults.set(server.absoluteString, forKey: Self.serverKey)
        serverText = server.absoluteString
        await loadIdentities()
    }

    func loadIdentities() async {
        guard let api = peerClient, let id = account?.id else { return }
        do {
            let result = try await api.linkedIdentities()
            guard account?.id == id else { return }
            identities = result
        } catch { message = error.localizedDescription }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true
        message = nil
        loginConflictProvider = nil
        defer { busy = false }
        DesktopCenter.shared.shutdown()
        do {
            if let client {
                do { try await client.logout() }
                catch let error as CloudAPIError where ["unauthorized", "refresh_replayed", "session_revoked"].contains(error.code) {
                    // 服务端明确报告登录已失效，无需再次撤销。
                }
            }
            if let account { try CloudKeychain.delete(account.id) }
            client = nil
            needsLogin = true
            account = nil
            identities = []
            defaults.removeObject(forKey: Self.accountKey)
        } catch {
            message = "退出未完成：\(error.localizedDescription)"
        }
    }

    func requireLogin(_ reason: String) {
        cancelLogin()
        DesktopCenter.shared.shutdown()
        needsLogin = true
        client = nil
        message = reason
    }
}
