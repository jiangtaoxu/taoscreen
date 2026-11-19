import Foundation
import Testing
@testable import TaoScreen

struct DesktopHTTPRecoveryTests {
    @Test func desktopRoutesCanRecoverAfterProxy404WithoutChangingLogin() async throws {
        let server = URL(string: "https://desktop-route.example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopRouteProtocol.self]
        let credentials = CloudCredentials(
            account: .init(server: server.absoluteString, userID: UUID(), email: "route@example.test"),
            deviceID: UUID(), accessToken: "route-test-access", refreshToken: "route-test-refresh",
            accessExpiresAt: Date().addingTimeInterval(3600))
        let api = DesktopAPI(server: server, credentials: credentials,
                             persist: { _ in Issue.record("路由 404 不应改写登录凭据") }, configuration: configuration)
        let portsSocket = try await api.portsRequest()
        #expect(portsSocket.url?.absoluteString == "wss://desktop-route.example.test/v1/ports/signal")
        #expect(portsSocket.value(forHTTPHeaderField: "Authorization") == "Bearer route-test-access")
        for path in ["/v1/desktop/config", "/v1/desktop/peers", "/v1/ports/config", "/v1/ports/peers"] {
            do {
                if path == "/v1/ports/config" { _ = try await api.portsConfiguration() }
                else if path == "/v1/ports/peers" { _ = try await api.portsPeers() }
                else if path.hasSuffix("config") { _ = try await api.desktopConfiguration() }
                else { _ = try await api.desktopPeers() }
                Issue.record("第一次请求应收到代理 404")
            } catch let error as CloudHTTPError {
                #expect(error.statusCode == 404 && error.path == path)
                let failure = DesktopSignalFailure.classify(error, httpStatus: nil, closeCode: nil)
                #expect(failure == .endpointUnavailable && !failure.endsSession)
            }
            // 同一 API 和账号在路由恢复后即可继续请求，无需重新登录。
            if path.hasSuffix("config") {
                let result = try await (path.hasPrefix("/v1/ports/") ? api.portsConfiguration() : api.desktopConfiguration())
                #expect(result.iceServers.isEmpty && !result.relayAvailable)
            } else {
                let result = try await (path.hasPrefix("/v1/ports/") ? api.portsPeers() : api.desktopPeers())
                #expect(result.isEmpty)
            }
        }
    }
}

private final class DesktopRouteReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String: Int] = [:]

    func response(for path: String) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        attempts[path, default: 0] += 1
        if attempts[path] == 1 { return (404, "404 page not found\n") }
        switch path {
        case "/v1/desktop/config", "/v1/ports/config": return (200, #"{"ice_servers":[],"relay_available":false}"#)
        case "/v1/desktop/peers", "/v1/ports/peers": return (200, #"{"peers":[]}"#)
        default: return (500, "unexpected route")
        }
    }
}

private final class DesktopRouteProtocol: URLProtocol, @unchecked Sendable {
    private static let replies = DesktopRouteReplies()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "desktop-route.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.value(forHTTPHeaderField: "Authorization") == "Bearer route-test-access" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let (status, body) = Self.replies.response(for: url.path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": status == 200 ? "application/json" : "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
