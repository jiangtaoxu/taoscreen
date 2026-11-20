import CryptoKit
import Foundation

enum CloudCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data { try SyncCoding.encode(value) }
    static func date(_ value: String) throws -> Date { try SyncCoding.date(value) }
    static func timestamp(_ date: Date) -> CloudJSON { SyncCoding.timestamp(date) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func serverURL(_ text: String) throws -> URL {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
            c.path.isEmpty || c.path == "/",
            c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else {
            throw CloudError(L10n.text("请输入 HTTPS 服务根地址；本机开发可使用 http://127.0.0.1:28080。"))
        }
        c.path = ""
        c.host = host.lowercased()
        guard let url = c.url else { throw CloudError(L10n.text("服务地址无效。")) }
        return url
    }
}

/// 保留 HTTP 状态和请求路径；仅凭 404 无法判断服务端是否支持某项功能。
struct CloudHTTPError: LocalizedError {
    let statusCode: Int
    let path: String
    var errorDescription: String? {
        L10n.text("TaoScreen 服务的 \(path) 返回 HTTP \(statusCode)，请核对服务器地址与服务状态。")
    }
}

struct CloudAccount: Codable, Identifiable, Equatable {
    let server: String
    let userID: UUID
    let email: String
    var id: String { CloudCoding.sha(Data((server + "\n" + userID.uuidString.lowercased()).utf8)) }
}
struct CloudCredentials: Codable {
    let account: CloudAccount
    let deviceID: UUID
    var accessToken: String
    var refreshToken: String
    var accessExpiresAt: Date
}

struct CloudAPIError: Decodable, LocalizedError {
    let code: String
    let message: String
    let details: CloudJSON?
    var errorDescription: String? { "\(L10n.value(message)) (\(code))" }
}

struct DesktopLoginMethods: Decodable {
    let providers: [DesktopLoginProvider]
    let passwordLogin: Bool?

    enum CodingKeys: String, CodingKey {
        case providers
        case passwordLogin = "password_login"
    }
}

struct DesktopLoginProvider: Decodable, Identifiable {
    enum ID: String, Decodable, CaseIterable, Identifiable {
        case google, github
        var id: Self { self }
        var title: String { self == .google ? "Google" : "GitHub" }
    }
    let id: ID
    let enabled: Bool
}

struct DesktopLinkedIdentity: Decodable, Identifiable {
    let provider: DesktopLoginProvider.ID
    let email: String
    let name: String
    var id: DesktopLoginProvider.ID { provider }
}
