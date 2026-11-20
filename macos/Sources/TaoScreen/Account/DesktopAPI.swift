import Foundation
import Security

/// TaoScreen 会话独立于 GitHub/Codex，钥匙串写入失败不转存文件。
enum CloudKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: DesktopRuntime.keychainService("sync"),
            kSecAttrAccount as String: account,
        ]
    }
    static func read(_ account: String) throws -> CloudCredentials? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CloudError(L10n.text("读取登录凭据失败（\(status)）。")) }
        return try JSONDecoder().decode(CloudCredentials.self, from: data)
    }
    static func save(_ credentials: CloudCredentials) throws {
        let data = try CloudCoding.encode(credentials)
        let q = query(credentials.account.id)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudError(L10n.text("保存登录凭据失败（\(status)）。")) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError(L10n.text("删除登录凭据失败（\(status)）。")) }
    }
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

actor DesktopAPI {
    private let server: URL
    private let session: URLSession
    private var credentials: CloudCredentials?
    private var refreshing: Task<CloudCredentials, Error>?
    private let persist: @Sendable (CloudCredentials) throws -> Void

    init(
        server: URL, credentials: CloudCredentials? = nil,
        persist: @escaping @Sendable (CloudCredentials) throws -> Void = { try CloudKeychain.save($0) },
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.server = server
        self.credentials = credentials
        self.persist = persist
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }
    func verifyService() async throws {
        struct Metadata: Decodable { let service: String }
        let data = try await raw("GET", "/health/ready")
        guard try JSONDecoder().decode(Metadata.self, from: data).service == "taoscreen" else {
            throw CloudError(L10n.text("请填写有效的 TaoScreen 服务地址。"))
        }
    }

    func loginMethods() async throws -> DesktopLoginMethods {
        try JSONDecoder().decode(DesktopLoginMethods.self, from: await raw("GET", "/v1/auth/providers"))
    }

    func beginOAuth(_ login: DesktopOAuthLogin, provider: DesktopLoginProvider.ID,
                    deviceID: UUID, name: String, linking: Bool = false) async throws -> URL {
        let path = linking ? "/v1/auth/identities/\(provider.rawValue)/start" : "/v1/auth/oauth/\(provider.rawValue)/start"
        let body: CloudJSON = .object(["state": .string(login.state), "code_challenge": .string(login.challenge),
                                      "device_id": .id(deviceID), "device_name": .string(name)])
        let token = linking ? try await accessToken() : nil
        let data = try await raw("POST", path, body: body, token: token)
        struct Result: Decodable { let authorization_url: String }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return try login.authorizationURL(result.authorization_url, server: server, provider: provider)
    }

    func exchangeOAuth(_ login: DesktopOAuthLogin, provider: DesktopLoginProvider.ID,
                       code: String, deviceID: UUID) async throws -> CloudCredentials {
        let data = try await raw("POST", "/v1/auth/oauth/\(provider.rawValue)/exchange", body: .object([
            "code": .string(code), "state": .string(login.state), "code_verifier": .string(login.verifier)]))
        return try decodeCredentials(data, deviceID: deviceID)
    }

    private func decodeCredentials(_ data: Data, deviceID: UUID) throws -> CloudCredentials {
        let value = try JSONDecoder().decode(CloudJSON.self, from: data)
        guard try value.id("device_id") == deviceID else { throw CloudError(L10n.text("登录返回的设备身份不匹配。")) }
        let credentials = CloudCredentials(
            account: .init(server: server.absoluteString, userID: try value.id("user_id"), email: try value.string("email")),
            deviceID: deviceID, accessToken: try value.string("access_token"), refreshToken: try value.string("refresh_token"),
            accessExpiresAt: try value.date("access_expires_at"))
        guard DesktopOAuthLogin.validSecret(credentials.accessToken), DesktopOAuthLogin.validSecret(credentials.refreshToken),
              credentials.accessExpiresAt > Date(), !credentials.account.email.isEmpty else { throw CloudError(L10n.text("服务端返回的登录凭据无效。")) }
        return credentials
    }

    func acceptCredentials(_ value: CloudCredentials) throws {
        try persist(value)
        credentials = value
    }

    func revokeUnacceptedCredentials(_ value: CloudCredentials) async throws {
        _ = try await raw("POST", "/v1/auth/logout", token: value.accessToken)
    }

    func exchangeOAuthLink(_ login: DesktopOAuthLogin, provider: DesktopLoginProvider.ID, code: String) async throws {
        let data = try await raw("POST", "/v1/auth/oauth/\(provider.rawValue)/exchange", body: .object([
            "code": .string(code), "state": .string(login.state), "code_verifier": .string(login.verifier)]), token: accessToken())
        struct Result: Decodable { let linked: Bool; let provider: DesktopLoginProvider.ID }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.linked, result.provider == provider else { throw CloudError(L10n.text("服务端未确认账号绑定。")) }
    }

    func linkedIdentities() async throws -> [DesktopLinkedIdentity] {
        struct Envelope: Decodable { let identities: [DesktopLinkedIdentity] }
        return try await get("/v1/auth/identities", as: Envelope.self).identities
    }

    func login(email: String, password: String, deviceID: UUID, name: String) async throws -> CloudCredentials {
        let data = try await raw(
            "POST", "/v1/auth/login",
            body: .object([
                "email": .string(email), "password": .string(password), "device_id": .id(deviceID),
                "device_name": .string(name),
            ]))
        return try decodeCredentials(data, deviceID: deviceID)
    }
    func register(email: String, password: String) async throws {
        _ = try await raw(
            "POST", "/v1/auth/register", body: .object(["email": .string(email), "password": .string(password)]))
    }
    private func accessToken() async throws -> String {
        guard let current = credentials else { throw CloudError(L10n.text("请登录 TaoScreen 账户。")) }
        if current.accessExpiresAt.timeIntervalSinceNow > 30 { return current.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { () throws -> CloudCredentials in
            let data = try await self.raw(
                "POST", "/v1/auth/refresh", body: .object(["refresh_token": .string(current.refreshToken)]))
            let result = try JSONDecoder().decode(CloudJSON.self, from: data)
            var updated = current
            updated.accessToken = try result.string("access_token")
            updated.refreshToken = try result.string("refresh_token")
            updated.accessExpiresAt = try result.date("access_expires_at")
            try self.persist(updated)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        let updated = try await task.value
        credentials = updated
        return updated.accessToken
    }
    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await raw("GET", path, token: accessToken())
        return try JSONDecoder().decode(type, from: data)
    }
    func logout() async throws { _ = try await raw("POST", "/v1/auth/logout", token: accessToken()) }
    func desktopRequest() async throws -> URLRequest {
        try await authenticatedSocketRequest(path: "/v1/desktop/signal")
    }
    func portsRequest() async throws -> URLRequest {
        try await authenticatedSocketRequest(path: "/v1/ports/signal")
    }
    func portsConfiguration() async throws -> DesktopConfiguration {
        try JSONDecoder().decode(DesktopConfiguration.self, from: await raw("GET", "/v1/ports/config", token: accessToken()))
    }
    func portsPeers() async throws -> [DesktopPeer] {
        struct Envelope: Decodable { let peers: [DesktopPeer] }
        return try JSONDecoder().decode(Envelope.self, from: await raw("GET", "/v1/ports/peers", token: accessToken())).peers
    }
    func desktopConfiguration() async throws -> DesktopConfiguration {
        try JSONDecoder().decode(DesktopConfiguration.self, from: await raw("GET", "/v1/desktop/config", token: accessToken()))
    }
    func desktopPeers() async throws -> [DesktopPeer] {
        struct Envelope: Decodable { let peers: [DesktopPeer] }
        return try JSONDecoder().decode(Envelope.self, from: await raw("GET", "/v1/desktop/peers", token: accessToken())).peers
    }
    private func authenticatedSocketRequest(path: String) async throws -> URLRequest {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { throw CloudError(L10n.text("服务地址无效。")) }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = path
        guard let url = components.url else { throw CloudError(L10n.text("服务地址无效。")) }
        var request = URLRequest(url: url)
        request.setValue(L10n.language.rawValue, forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }
    private func raw(
        _ method: String, _ path: String, body: CloudJSON? = nil, binary: Data? = nil,
        headers: [String: String] = [:], token: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: server.absoluteString + path) else { throw CloudError(L10n.text("请求地址无效。")) }
        var req = URLRequest(url: url)
        req.setValue(L10n.language.rawValue, forHTTPHeaderField: "Accept-Language")
        req.httpMethod = method
        if let body {
            req.httpBody = try CloudCoding.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let binary {
            req.httpBody = binary
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(binary.count), forHTTPHeaderField: "Content-Length")
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw CloudError(L10n.text("服务器未返回 HTTP 响应。")) }
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable { let error: CloudAPIError }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) { throw envelope.error }
            throw CloudHTTPError(statusCode: response.statusCode, path: path)
        }
        return data
    }

}
