import Foundation
import Testing
@testable import TaoScreen

struct DesktopAccountTests {
    @Test func independentStorageAndServerValidation() throws {
        #expect(DesktopRuntime.supportDirectory.lastPathComponent == "org.taoscreen.development")
        #expect(DesktopRuntime.keychainService("sync") == "org.taoscreen.development.sync")
        #expect(try CloudCoding.serverURL(" http://127.0.0.1:28080/ ").absoluteString == "http://127.0.0.1:28080")
        for value in ["http://example.com", "https://user:password@example.com", "https://example.com/v1", "https://example.com?token=secret"] {
            #expect(throws: (any Error).self) { try CloudCoding.serverURL(value) }
        }
    }

    @Test @MainActor func newInstallDoesNotReadBerthAccountOrEndpoint() throws {
        let suite = "taoscreen-account-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://berth.example.test", forKey: "berth.cloud.server")
        let state = DesktopAccountState(defaults: defaults)
        #expect(state.account == nil && state.needsLogin && state.serverText.isEmpty)
        #expect(state.peerClient == nil)
        let device = try #require(defaults.string(forKey: "taoscreen.deviceID"))
        #expect(UUID(uuidString: device) != nil)
        _ = DesktopAccountState(defaults: defaults)
        #expect(defaults.string(forKey: "taoscreen.deviceID") == device)
    }

    @Test @MainActor func malformedAccountIsReportedWithoutSelectingAnotherAccount() throws {
        let suite = "taoscreen-account-invalid-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: DesktopAccountState.accountKey)
        let state = DesktopAccountState(defaults: defaults)
        #expect(state.account == nil && state.needsLogin && state.message != nil)
        state.requireLogin("会话已撤销")
        #expect(state.peerClient == nil && state.message == "会话已撤销")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAOSCREEN_LIVE_TEST_URL"] != nil))
    func nativeClientAuthenticatesRefreshesAndLogsOutAgainstStandaloneServer() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["TAOSCREEN_LIVE_TEST_URL"])
        let server = try CloudCoding.serverURL(endpoint)
        let client = DesktopAPI(server: server, persist: { _ in })
        try await client.verifyService()
        let methods = try await client.loginMethods()
        #expect(methods.passwordLogin == true)
        let email = "native-desktop-\(UUID().uuidString.lowercased())@example.test"
        let device = UUID()
        try await client.register(email: email, password: "TaoScreen-live-tests-only-123!")
        var credentials = try await client.login(email: email, password: "TaoScreen-live-tests-only-123!", deviceID: device, name: "原生桌面自动测试")
        #expect(credentials.deviceID == device && credentials.account.server == endpoint && credentials.account.email == email)
        try await client.acceptCredentials(credentials)
        let request = try await client.desktopRequest()
        #expect(request.url?.path == "/v1/desktop/signal")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credentials.accessToken)")
        let portsRequest = try await client.portsRequest()
        #expect(portsRequest.url?.path == "/v1/ports/signal")
        #expect(portsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(credentials.accessToken)")
        struct Metadata: Decodable { let service: String }
        let metadata = try await client.get("/v1/me", as: Metadata.self)
        #expect(metadata.service == "taoscreen")
        credentials.accessExpiresAt = .distantPast
        let refreshing = DesktopAPI(server: server, credentials: credentials, persist: { _ in })
        async let first = refreshing.desktopPeers()
        async let second = refreshing.desktopConfiguration()
        async let portsPeers = refreshing.portsPeers()
        async let portsConfiguration = refreshing.portsConfiguration()
        let (peers, configuration) = try await (first, second)
        let (independentPeers, independentConfiguration) = try await (portsPeers, portsConfiguration)
        #expect(peers.isEmpty && !configuration.relayAvailable)
        #expect(independentPeers.isEmpty && !independentConfiguration.relayAvailable)
        try await refreshing.logout()
        await #expect(throws: (any Error).self) { try await refreshing.desktopPeers() }
    }
}
