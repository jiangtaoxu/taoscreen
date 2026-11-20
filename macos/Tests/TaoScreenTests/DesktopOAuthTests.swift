import AuthenticationServices
import Foundation
import Testing
@testable import TaoScreen

struct DesktopOAuthTests {
    @Test @MainActor func loginOptionsOnlyFollowTheSelectedServer() async throws {
        let suite = "TaoScreenLoginOptionsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DesktopAccountState(defaults: defaults) { server in
            switch server.host {
            case "official.example.test":
                return .init(providers: [.init(id: .github, enabled: true), .init(id: .google, enabled: true)],
                             passwordLogin: true)
            case "private.example.test":
                return .init(providers: [.init(id: .github, enabled: false), .init(id: .google, enabled: true)],
                             passwordLogin: false)
            case "local.example.test":
                return .init(providers: [], passwordLogin: true)
            default:
                throw CloudError("服务器不可用")
            }
        }

        account.serverText = "https://official.example.test"
        await account.loadProviders()
        #expect(account.enabledProviders.map(\.id) == [.github, .google])
        #expect(account.allowsPasswordLogin)

        account.serverText = "https://private.example.test"
        #expect(account.enabledProviders.isEmpty)
        #expect(!account.allowsPasswordLogin)
        await account.loadProviders()
        #expect(account.enabledProviders.map(\.id) == [.google])
        #expect(!account.allowsPasswordLogin)

        account.serverText = "https://local.example.test"
        await account.loadProviders()
        #expect(account.enabledProviders.isEmpty && account.allowsPasswordLogin)

        account.serverText = "https://offline.example.test"
        await account.loadProviders()
        #expect(account.enabledProviders.isEmpty && !account.providersLoaded)
    }

    @Test func generatesIndependentPKCEAndOnlyAcceptsOwnServerAndProvider() throws {
        let login = try DesktopOAuthLogin(), other = try DesktopOAuthLogin()
        #expect(DesktopOAuthLogin.validSecret(login.state))
        #expect(DesktopOAuthLogin.validSecret(login.verifier))
        #expect(DesktopOAuthLogin.validSecret(login.challenge))
        #expect(login.state != other.state && login.verifier != other.verifier)
        let server = try CloudCoding.serverURL("https://taoscreen.example.test")
        let valid = "https://taoscreen.example.test/v1/auth/oauth/google/authorize?ticket=\(login.state)"
        #expect(try login.authorizationURL(valid, server: server, provider: .google).host == server.host)
        for invalid in [valid.replacingOccurrences(of: "taoscreen.example.test", with: "other.example.test"),
                        valid.replacingOccurrences(of: "/google/", with: "/github/"),
                        valid + "&redirect=https://other.example.test", valid + "#fragment"] {
            #expect(throws: (any Error).self) { try login.authorizationURL(invalid, server: server, provider: .google) }
        }
    }

    @Test func callbackRequiresMatchingStateUniqueParametersAndShortCode() throws {
        let login = try DesktopOAuthLogin()
        let code = try DesktopOAuthLogin().state
        let callback = "taoscreen://auth/callback?state=\(login.state)&code=\(code)"
        #expect(try login.code(from: URL(string: callback)!) == code)
        for invalid in [callback.replacingOccurrences(of: "taoscreen://", with: "berth://"),
                        callback.replacingOccurrences(of: login.state, with: code),
                        callback + "&code=\(code)", callback + "&error=access_denied", callback + "&access_token=secret",
                        callback.replacingOccurrences(of: "/callback", with: "/other")] {
            #expect(throws: (any Error).self) { try login.code(from: URL(string: invalid)!) }
        }
        #expect(!DesktopOAuthLogin.validSecret(String(repeating: "A", count: 42) + "B"))
    }

    @MainActor private final class Session: DesktopOAuthSession {
        let completion: (URL?, Error?) -> Void
        var started = false
        var cancelled = false
        var canStart = true
        init(_ completion: @escaping (URL?, Error?) -> Void) { self.completion = completion }
        func start() -> Bool { started = true; return canStart }
        func cancel() { cancelled = true }
    }

    @Test @MainActor func simultaneousAppInstancesReceiveOnlyTheirOwnAuthenticationCallback() async throws {
        let firstLogin = try DesktopOAuthLogin(), secondLogin = try DesktopOAuthLogin()
        var first: Session?, second: Session?
        let firstBrowser = DesktopOAuthBrowser(makeSession: { _, completion in
            let session = Session(completion); first = session; return session
        })
        let secondBrowser = DesktopOAuthBrowser(makeSession: { _, completion in
            let session = Session(completion); second = session; return session
        })
        let url = URL(string: "https://taoscreen.example.test/login")!
        let firstWork = Task { try await firstBrowser.authenticate(url, login: firstLogin) }
        let secondWork = Task { try await secondBrowser.authenticate(url, login: secondLogin) }
        while first == nil || second == nil { await Task.yield() }
        let callback = URL(string: "taoscreen://auth/callback?state=\(secondLogin.state)&code=\(firstLogin.state)")!
        second!.completion(callback, nil)
        second!.completion(callback, nil) // 重复完成不得再次恢复 continuation。
        #expect(try await secondWork.value == callback)
        #expect(second!.cancelled && !first!.cancelled)
        firstBrowser.cancel()
        await #expect(throws: CancellationError.self) { try await firstWork.value }
    }

    @Test @MainActor func cancelledSessionsCannotFinishANewerRequestAndTimeoutClosesSession() async throws {
        let login = try DesktopOAuthLogin()
        var sessions: [Session] = []
        let browser = DesktopOAuthBrowser(makeSession: { _, completion in
            let session = Session(completion); sessions.append(session); return session
        })
        let url = URL(string: "https://taoscreen.example.test/login")!
        let first = Task { try await browser.authenticate(url, login: login) }
        while sessions.isEmpty { await Task.yield() }
        browser.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(sessions[0].cancelled)
        let nextLogin = try DesktopOAuthLogin()
        let next = Task { try await browser.authenticate(url, login: nextLogin) }
        while sessions.count < 2 { await Task.yield() }
        sessions[0].completion(nil, NSError(domain: ASWebAuthenticationSessionErrorDomain, code: 1))
        #expect(!sessions[1].cancelled)
        let callback = URL(string: "taoscreen://auth/callback?state=\(nextLogin.state)&code=\(login.state)")!
        sessions[1].completion(callback, nil)
        #expect(try await next.value == callback)
        let timed = DesktopOAuthBrowser(timeoutDuration: .milliseconds(15), makeSession: { _, completion in
            let session = Session(completion); sessions.append(session); return session
        })
        await #expect(throws: (any Error).self) { try await timed.authenticate(url, login: login) }
        #expect(sessions.last!.cancelled)
    }

    @Test @MainActor func invalidSystemCallbacksFailImmediatelyAndSessionFailuresAreReported() async throws {
        let login = try DesktopOAuthLogin(), other = try DesktopOAuthLogin()
        let url = URL(string: "https://taoscreen.example.test/login")!
        for callback in [nil,
                         URL(string: "taoscreen://auth/callback?state=\(other.state)&code=\(other.state)"),
                         URL(string: "taoscreen://auth/callback?state=\(login.state)&code=invalid"),
                         URL(string: "taoscreen://auth/callback?state=\(login.state)&error=authentication_failed")] as [URL?] {
            var session: Session?
            let browser = DesktopOAuthBrowser(makeSession: { _, completion in
                let value = Session(completion); session = value; return value
            })
            let work = Task { try await browser.authenticate(url, login: login) }
            while session == nil { await Task.yield() }
            session!.completion(callback, nil)
            await #expect(throws: (any Error).self) { try await work.value }
            #expect(session!.cancelled)
        }
        var session: Session?
        let browser = DesktopOAuthBrowser(makeSession: { _, completion in
            let value = Session(completion); session = value; return value
        })
        let work = Task { try await browser.authenticate(url, login: login) }
        while session == nil { await Task.yield() }
        session!.completion(nil, NSError(domain: ASWebAuthenticationSessionErrorDomain, code: 1))
        await #expect(throws: CancellationError.self) { try await work.value }
        let failed = DesktopOAuthBrowser(makeSession: { _, completion in
            let session = Session(completion); session.canStart = false; return session
        })
        await #expect(throws: (any Error).self) { try await failed.authenticate(url, login: login) }
    }
}
