import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// 浏览器只返回短期授权码；会话令牌通过 HTTPS + PKCE 兑换，不放进回调 URL。
struct DesktopOAuthLogin {
    static let callbackScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "taoscreen"
    }()
    let state: String
    let verifier: String

    init() throws {
        state = try Self.randomSecret()
        verifier = try Self.randomSecret()
    }
    init(state: String, verifier: String) { self.state = state; self.verifier = verifier }
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CloudError(L10n.text("无法生成安全登录请求，请重试。"))
        }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func validSecret(_ value: String) -> Bool {
        guard value.count == 43,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32 else { return false }
        return base64URL(data) == value
    }
    func authorizationURL(_ value: String, server: URL, provider: DesktopLoginProvider.ID) throws -> URL {
        guard let url = URL(string: value), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == server.scheme, url.host == server.host, url.port == server.port,
              c.user == nil, c.password == nil, c.fragment == nil,
              c.path == "/v1/auth/oauth/\(provider.rawValue)/authorize",
              let items = c.queryItems, items.count == 1, items[0].name == "ticket",
              let ticket = items[0].value, Self.validSecret(ticket) else {
            throw CloudError(L10n.text("服务端返回的登录地址无效。"))
        }
        return url
    }
    func matchesCallback(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == Self.callbackScheme, c.host == "auth", c.path == "/callback",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let items = c.queryItems, Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["state", "code", "error"].contains($0.name) }),
              items.first(where: { $0.name == "state" })?.value == state else {
            return false
        }
        return true
    }
    func code(from url: URL) throws -> String {
        guard matchesCallback(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CloudError(L10n.text("登录回调与本次请求不匹配，请重新登录。"))
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            guard !items.contains(where: { $0.name == "code" }) else { throw CloudError(L10n.text("登录回调无效。")) }
            if error == "account_denied" {
                throw CloudError(L10n.text("此身份未获授权、邮箱未验证或与已有 TaoScreen 账户绑定不符，请联系管理员。"))
            }
            throw CloudError(L10n.text("第三方登录未完成授权，请重新登录。"))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, Self.validSecret(code) else {
            throw CloudError(L10n.text("登录回调缺少有效授权码。"))
        }
        return code
    }

}

/// 认证会话直接把回调交给发起实例，不依赖系统对同名 App 的 URL 分发。
@MainActor
protocol DesktopOAuthSession: AnyObject {
    func start() -> Bool
    func cancel()
}

@MainActor
private final class DesktopSystemOAuthSession: NSObject, DesktopOAuthSession, ASWebAuthenticationPresentationContextProviding {
    private let session: ASWebAuthenticationSession
    private let window: NSWindow?

    init(url: URL, completion: @escaping (URL?, Error?) -> Void) {
        window = NSApp.keyWindow ?? NSApp.mainWindow
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: DesktopOAuthLogin.callbackScheme) { url, error in
            Task { @MainActor in completion(url, error) }
        }
        super.init()
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // start() 已确认存在发起登录的窗口。
        window!
    }
    func start() -> Bool { window != nil && session.start() }
    func cancel() { session.cancel() }
}

@MainActor
final class DesktopOAuthBrowser {
    typealias SessionFactory = (URL, @escaping (URL?, Error?) -> Void) -> any DesktopOAuthSession
    private var requestID: UUID?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var session: (any DesktopOAuthSession)?
    private let makeSession: SessionFactory
    private let timeoutDuration: Duration

    init(timeoutDuration: Duration = .seconds(300), makeSession: SessionFactory? = nil) {
        self.timeoutDuration = timeoutDuration
        self.makeSession = makeSession ?? { DesktopSystemOAuthSession(url: $0, completion: $1) }
    }

    func authenticate(_ url: URL, login: DesktopOAuthLogin) async throws -> URL {
        guard continuation == nil else { throw CloudError(L10n.text("已有登录正在进行。")) }
        try Task.checkCancellation()
        let requestID = UUID()
        self.requestID = requestID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self, timeoutDuration] in
                    do { try await Task.sleep(for: timeoutDuration) } catch { return }
                    guard self?.requestID == requestID else { return }
                    self?.finish(.failure(CloudError(L10n.text("登录已超时，请重新登录。"))))
                }
                let session = makeSession(url) { [weak self] callback, error in
                    guard let self, self.requestID == requestID else { return }
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            self.finish(.failure(CancellationError()))
                        } else {
                            self.finish(.failure(CloudError(L10n.text("浏览器登录未完成：\(error.localizedDescription)"))))
                        }
                        return
                    }
                    guard let callback else {
                        self.finish(.failure(CloudError(L10n.text("浏览器未返回登录回调，请重新登录。"))))
                        return
                    }
                    do {
                        _ = try login.code(from: callback)
                        self.finish(.success(callback))
                    } catch { self.finish(.failure(error)) }
                }
                self.session = session
                guard session.start() else {
                    finish(.failure(CloudError(L10n.text("无法启动浏览器认证会话，请在 TaoScreen 主窗口中重试。"))))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == requestID else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        requestID = nil
        timeout?.cancel(); timeout = nil
        let session = self.session
        self.session = nil
        session?.cancel()
        continuation.resume(with: result)
    }
}
