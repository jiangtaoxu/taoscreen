import AppKit
import LocalAuthentication
import Security
import SwiftUI
import Testing
@testable import TaoScreen

struct DesktopRemoteSecurityTests {
    private let locked = DesktopLocalSession(onConsole: true, loggedIn: true, locked: true)
    private let unlocked = DesktopLocalSession(onConsole: true, loggedIn: true, locked: false)

    @Test func passwordScopeAndKeychainQueryRemainLocalAndIsolated() throws {
        let account = CloudAccount(server: "https://one.example.test", userID: UUID(), email: "test@example.test")
        let device = UUID()
        let scope = DesktopRemotePasswordScope(accountID: account.id, peerID: device)
        let otherAccount = CloudAccount(server: account.server, userID: UUID(), email: account.email)
        let otherServer = CloudAccount(server: "https://two.example.test", userID: account.userID, email: account.email)
        #expect(scope.key != DesktopRemotePasswordScope(accountID: otherAccount.id, peerID: device).key)
        #expect(scope.key != DesktopRemotePasswordScope(accountID: otherServer.id, peerID: device).key)
        #expect(scope.key != DesktopRemotePasswordScope(accountID: account.id, peerID: UUID()).key)
        let query = DesktopRemotePasswordKeychain.query(scope)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == "org.taoscreen.development.remote-login.verified")
        #expect(query[kSecAttrAccount as String] as? String == scope.key)
        #expect(query[kSecAttrService as String] as? String != DesktopRuntime.keychainService("sync"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAOSCREEN_KEYCHAIN_FIXTURE_TEST"] == "1"))
    func realKeychainRequiresSystemAuthenticationForNewItems() throws {
        let scope = DesktopRemotePasswordScope(accountID: "taoscreen-keychain-fixture-\(UUID())", peerID: UUID())
        defer { try? DesktopRemotePasswordKeychain.delete(scope) }
        var legacy = DesktopRemotePasswordKeychain.query(scope)
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        legacy[kSecAttrService as String] = DesktopRuntime.keychainService("remote-login.local")
        var legacyItem = legacy
        legacyItem[kSecValueData as String] = Data("Fixture-legacy-123!".utf8)
        try #require(SecItemAdd(legacyItem as CFDictionary, nil) == errSecSuccess)
        let context = LAContext()
        context.interactionNotAllowed = true
        #expect(try !DesktopRemotePasswordKeychain.contains(scope))
        #expect(try DesktopRemotePasswordKeychain.read(scope, context: context) == nil)
        try DesktopRemotePasswordKeychain.save(scope, "Fixture-first-123!")
        #expect(SecItemCopyMatching(legacy as CFDictionary, nil) == errSecItemNotFound)
        #expect(try DesktopRemotePasswordKeychain.contains(scope))
        #expect(throws: (any Error).self) { try DesktopRemotePasswordKeychain.read(scope, context: context) }
        try DesktopRemotePasswordKeychain.save(scope, "Fixture-updated-456!")
        #expect(try DesktopRemotePasswordKeychain.contains(scope))
        #expect(throws: (any Error).self) { try DesktopRemotePasswordKeychain.read(scope, context: context) }
        try DesktopRemotePasswordKeychain.delete(scope)
        #expect(try !DesktopRemotePasswordKeychain.contains(scope))
    }

    @Test @MainActor func localPasswordStatusSurvivesRenameWithoutReadingOrStoringPlaintextInDefaults() throws {
        let suite = "taoscreen.remote-password.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = CloudAccount(server: "https://password.example.test", userID: UUID(), email: "local@example.test")
        defaults.set(try JSONEncoder().encode(account), forKey: DesktopAccountState.accountKey)
        let cloud = DesktopAccountState(defaults: defaults)
        let memory = PasswordMemory()
        let center = DesktopCenter(defaults: defaults, passwordStore: memory.store)
        center.attach(cloud: cloud)
        defer { center.shutdown() }
        let peer = DesktopPeer(id: UUID(), name: "Mac")
        let viewer = center.prepareViewer(for: peer)
        let scope = try #require(viewer.remotePasswordScope)
        let password = "Fixture-password-世界-123!"
        try viewer.saveRemotePassword(password, for: scope)
        #expect(viewer.hasSavedRemotePassword)
        #expect(memory.reads == 0)
        let domain = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(!String(describing: domain).contains(password))
        let other = center.prepareViewer(for: .init(id: UUID(), name: peer.name))
        #expect(!other.hasSavedRemotePassword)
        viewer.disconnect(notify: false)
        let renamed = center.prepareViewer(for: .init(id: peer.id, name: "Renamed Mac"))
        #expect(renamed.remotePasswordScope == scope && renamed.hasSavedRemotePassword)
        try renamed.deleteRemotePassword(for: scope)
        #expect(!renamed.hasSavedRemotePassword && memory.values.isEmpty)
        #expect(memory.reads == 0)
        let failing = DesktopRemotePasswordStore(read: { _ in nil }, contains: { _ in false },
                                                 save: { _, _ in throw CloudError("测试钥匙串写入失败") }, delete: { _ in })
        let failedCenter = DesktopCenter(defaults: defaults, passwordStore: failing)
        failedCenter.attach(cloud: cloud)
        defer { failedCenter.shutdown() }
        let failedViewer = failedCenter.prepareViewer(for: peer)
        #expect(throws: (any Error).self) { try failedViewer.saveRemotePassword(password, for: #require(failedViewer.remotePasswordScope)) }
        #expect(!failedViewer.hasSavedRemotePassword)
        #expect(!String(describing: defaults.persistentDomain(forName: suite)).contains(password))
    }

    @Test func protocolNeverConfusesPasswordsWithOrdinaryInputOrDiagnostics() throws {
        let password = "Fixture-secret-密码-123!"
        let request = DesktopRemoteSecurityMessage(action: .unlock, requestID: UUID(), password: password)
        #expect(request.isValid)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(DesktopRemoteSecurityMessage.self, from: data).password == password)
        #expect(try !JSONDecoder().decode(DesktopInput.self, from: data).isValid)
        #expect(!String(describing: request).contains(password) && !String(reflecting: request).contains(password))
        for invalid in ["", "abc\n123", "abc\t123", "abc\0def", String(repeating: "a", count: 1025)] {
            #expect(!DesktopRemoteSecurityMessage(action: .unlock, requestID: UUID(), password: invalid).isValid)
        }
        #expect(!DesktopRemoteSecurityMessage(action: .configure, requestID: UUID(), lockOnDisconnect: true, password: password).isValid)
        #expect(!DesktopRemoteSecurityMessage(action: .status, lockOnDisconnect: true, password: password).isValid)
        #expect(!DesktopRemoteSecurityMessage(action: .unlockResult, requestID: UUID(), submitted: true, failure: .permission).isValid)
    }

    @Test func hostRejectsUnauthorizedUnlockedReplayedOrFrequentAttemptsAndLocksOnlyOnce() {
        var host = DesktopRemoteSecurityHost()
        let denied = host.configure(true, authorized: false)
        #expect(!denied && !host.lockOnDisconnect)
        let id = UUID()
        let permission = host.authorizeUnlock(id, authorized: false, locked: true, now: 0)
        let notLocked = host.authorizeUnlock(id, authorized: true, locked: false, now: 0)
        let accepted = host.authorizeUnlock(id, authorized: true, locked: true, now: 0)
        let repeated = host.authorizeUnlock(id, authorized: true, locked: true, now: 10)
        let limited = host.authorizeUnlock(UUID(), authorized: true, locked: true, now: 1)
        #expect(permission == .permission && notLocked == .notLocked && accepted == nil && repeated == .repeated && limited == .limit)
        let configured = host.configure(true, authorized: true)
        let firstEnd = host.end(established: true, authorized: true, localSession: unlocked)
        let secondEnd = host.end(established: true, authorized: true, localSession: unlocked)
        #expect(configured && firstEnd && !secondEnd)
        for (established, authorized, session) in [(false, true, unlocked), (true, false, unlocked), (true, true, locked),
                                                  (true, true, DesktopLocalSession(onConsole: false, loggedIn: true, locked: false))] {
            let enabled = host.configure(true, authorized: true)
            let lock = host.end(established: established, authorized: authorized, localSession: session)
            #expect(enabled && !lock)
        }
    }

    @Test func viewerRequiresMatchingConfirmationAndDoesNotClaimSubmittedPasswordUnlocked() throws {
        var viewer = DesktopRemoteSecurityViewer()
        let unsupportedLock = viewer.configure(true), unsupportedUnlock = viewer.beginUnlock()
        #expect(unsupportedLock == nil && unsupportedUnlock == nil)
        let initial = viewer.receive(.init(action: .status, lockOnDisconnect: false))
        #expect(initial == nil)
        let optionalRequest = viewer.configure(true)
        let request = try #require(optionalRequest)
        #expect(!viewer.preference && viewer.lockChanging && viewer.selectedLock)
        _ = viewer.receive(.init(action: .status, requestID: UUID(), lockOnDisconnect: true))
        #expect(!viewer.preference)
        viewer.expireLock(try #require(request.requestID))
        #expect(viewer.confirmedLock == nil && viewer.lockFailure != nil)
        let optionalRetry = viewer.configure(true)
        let retry = try #require(optionalRetry)
        _ = viewer.receive(.init(action: .status, requestID: request.requestID, lockOnDisconnect: true))
        #expect(!viewer.preference)
        _ = viewer.receive(.init(action: .status, requestID: retry.requestID, lockOnDisconnect: true))
        #expect(viewer.preference && viewer.confirmedLock == true && !viewer.lockChanging)
        let optionalUnlock = viewer.beginUnlock()
        let unlock = try #require(optionalUnlock)
        _ = viewer.receive(.init(action: .unlockResult, requestID: UUID(), submitted: true))
        #expect(viewer.unlockRequest == unlock)
        _ = viewer.receive(.init(action: .unlockResult, requestID: unlock, submitted: true))
        #expect(viewer.unlockRequest == unlock && viewer.unlockMessage?.contains("等待") == true)
        viewer.confirmUnlocked()
        #expect(viewer.unlockRequest == nil && viewer.unlockMessage == "远端已确认解锁。")
        let optionalTimeout = viewer.beginUnlock()
        let timeout = try #require(optionalTimeout); viewer.expireUnlock(timeout)
        #expect(viewer.unlockRequest == nil && viewer.unlockMessage?.contains("不会自动重试") == true)
        var restored = DesktopRemoteSecurityViewer(); restored.preference = true
        let optionalAutomatic = restored.receive(.init(action: .status, lockOnDisconnect: false))
        let automatic = try #require(optionalAutomatic)
        #expect(automatic.action == .configure && automatic.lockOnDisconnect == true && automatic.password == nil)
    }

    @Test @MainActor func unicodePasswordUsesKeyboardEventsWithoutClipboardAndStopsOnSessionChange() throws {
        var posted: [CGEvent] = []
        var state = locked
        let receiver = DesktopSecurityInput(canPost: { true }, session: { state }, post: { posted.append($0) })
        let clipboardVersion = NSPasteboard.general.changeCount
        let password = "Abc世界😀👨‍👩‍👧‍👦e\u{301}!"
        try receiver.submitPassword(password)
        var entered = ""
        for event in posted where event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 0 && event.flags.isEmpty {
            var count = 0, characters = [UniChar](repeating: 0, count: 32)
            characters.withUnsafeMutableBufferPointer { event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &count, unicodeString: $0.baseAddress) }
            entered += String(decoding: characters.prefix(count), as: UTF16.self)
        }
        #expect(entered == password)
        #expect(NSPasteboard.general.changeCount == clipboardVersion)
        #expect(posted.allSatisfy { $0.timestamp > 0 })
        #expect(posted.suffix(2).map { $0.getIntegerValueField(.keyboardEventKeycode) } == [36, 36])
        posted.removeAll(); state = unlocked
        #expect(throws: (any Error).self) { try receiver.submitPassword(password) }
        #expect(posted.isEmpty)
        state = locked
        let changing = DesktopSecurityInput(canPost: { true }, session: { state }, post: { posted.append($0); state = unlocked })
        #expect(throws: (any Error).self) { try changing.submitPassword(password) }
        #expect(!posted.contains { $0.getIntegerValueField(.keyboardEventKeycode) == 36 })
        posted.removeAll()
        let denied = DesktopSecurityInput(canPost: { false }, session: { state }, post: { posted.append($0) })
        #expect(throws: (any Error).self) { try denied.submitPassword(password) }
        #expect(posted.isEmpty)
    }

    @Test @MainActor func disconnectLockUsesStandardChordOnlyForActiveUnlockedSession() throws {
        var posted: [CGEvent] = [], state = unlocked
        let input = DesktopSecurityInput(canPost: { true }, session: { state }, post: { posted.append($0) })
        try input.lock()
        #expect(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59, 55, 12, 12, 55, 59])
        #expect(posted[2].flags.contains([.maskControl, .maskCommand]))
        #expect(posted.last?.flags.isEmpty == true)
        posted.removeAll(); state = locked
        try input.lock(); #expect(posted.isEmpty)
        state = .init(onConsole: false, loggedIn: true, locked: false)
        #expect(throws: (any Error).self) { try input.lock() }
        #expect(posted.isEmpty)
    }

    @Test @MainActor func realEncryptedChannelNegotiatesLockAndSubmitsPasswordWithoutInputOrClipboardMessages() async throws {
        let configuration = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: configuration, host: true)
        let viewer = try DesktopRTC(configuration: configuration, host: false)
        defer { host.close(); viewer.close() }
        let password = "Fixture-WebRTC-密码-123!"
        var hostPolicy = DesktopRemoteSecurityHost(), viewerPolicy = DesktopRemoteSecurityViewer()
        viewerPolicy.preference = true
        var connected = false, submitted = 0, unexpectedInput = false, leakedSignal = false
        var events: [CGEvent] = []
        let passwordInput = DesktopSecurityInput(canPost: { true }, session: { locked }, post: { events.append($0) })
        host.onState = { if $0 == .connected { connected = true } }
        host.onInput = { _ in unexpectedInput = true }
        host.onClipboard = { _ in unexpectedInput = true }
        host.onSignal = { kind, value in
            if (try? String(data: JSONEncoder().encode(value), encoding: .utf8)?.contains(password)) == true { leakedSignal = true }
            if kind == "candidate" { viewer.addCandidate(value) }
        }
        viewer.onSignal = { kind, value in
            if (try? String(data: JSONEncoder().encode(value), encoding: .utf8)?.contains(password)) == true { leakedSignal = true }
            if kind == "candidate" { host.addCandidate(value) }
        }
        host.onControlOpen = { host.sendSecurity(.init(action: .status, lockOnDisconnect: false)) }
        host.onSecurity = { value in
            if value.action == .configure, let enabled = value.lockOnDisconnect {
                let accepted = hostPolicy.configure(enabled, authorized: true)
                host.sendSecurity(.init(action: .status, requestID: value.requestID, lockOnDisconnect: hostPolicy.lockOnDisconnect, failure: accepted ? nil : .permission))
            } else if value.action == .unlock, let id = value.requestID, let secret = value.password {
                var failure = hostPolicy.authorizeUnlock(id, authorized: true, locked: true, now: ProcessInfo.processInfo.systemUptime)
                if failure == nil {
                    do { try passwordInput.submitPassword(secret); submitted += 1 }
                    catch { failure = .inputUnavailable }
                }
                host.sendSecurity(.init(action: .unlockResult, requestID: id, submitted: failure == nil, failure: failure))
            }
        }
        viewer.onSecurity = { value in
            if let reply = viewerPolicy.receive(value) { viewer.sendSecurity(reply) }
        }
        viewer.onSessionStatus = { if !$0.locked { viewerPolicy.confirmUnlocked() } }
        let offer = try await viewer.makeDescription(offer: true)
        try await host.setRemote(offer, offer: true)
        let answer = try await host.makeDescription(offer: false)
        try await viewer.setRemote(answer, offer: false)
        #expect(!offer.contains(password) && !answer.contains(password))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (viewerPolicy.confirmedLock != true || !connected) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(viewerPolicy.supported && viewerPolicy.preference && viewerPolicy.confirmedLock == true)
        let optionalID = viewerPolicy.beginUnlock()
        let id = try #require(optionalID)
        #expect(viewer.sendSecurity(.init(action: .unlock, requestID: id, password: password)))
        while (submitted == 0 || viewerPolicy.unlockMessage?.contains("等待远端确认") != true) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(submitted == 1 && !events.isEmpty && viewerPolicy.unlockRequest == id)
        #expect(!unexpectedInput && !leakedSignal && !String(reflecting: hostPolicy).contains(password))
        host.sendSessionStatus(.init(locked: false))
        while viewerPolicy.unlockRequest != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(viewerPolicy.unlockMessage == "远端已确认解锁。")
        viewer.close()
        let shouldLock = hostPolicy.end(established: connected, authorized: true, localSession: unlocked)
        #expect(shouldLock && !hostPolicy.lockOnDisconnect)
    }

    @Test @MainActor func securitySettingsPreviewUsesHiddenPasswordAndExistingAccountScope() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAOSCREEN_REMOTE_SECURITY_PREVIEW"] else { return }
        _ = NSApplication.shared
        let suite = "taoscreen.password-preview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = CloudAccount(server: "https://preview.example.test", userID: UUID(), email: "preview@example.test")
        defaults.set(try JSONEncoder().encode(account), forKey: DesktopAccountState.accountKey)
        let cloud = DesktopAccountState(defaults: defaults), memory = PasswordMemory()
        let center = DesktopCenter(defaults: defaults, passwordStore: memory.store)
        center.attach(cloud: cloud)
        defer { center.shutdown() }
        let viewer = center.prepareViewer(for: .init(id: UUID(), name: "测试 Mac"))
        try viewer.saveRemotePassword("Fixture-hidden-only", for: #require(viewer.remotePasswordScope))
        viewer.receiveRemoteSecurity(.init(action: .status, lockOnDisconnect: false))
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let view = NSHostingView(rootView: DesktopRemoteSecuritySettings(center: viewer).padding(20).frame(width: 440, height: 600, alignment: .top)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = view
        defer { window.contentView = nil }
        view.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("remote-password-settings.png"))
    }
}

@MainActor private final class PasswordMemory {
    var values: [String: String] = [:]
    var reads = 0
    var store: DesktopRemotePasswordStore {
        .init(read: { self.reads += 1; return self.values[$0.key] }, contains: { self.values[$0.key] != nil },
              save: { self.values[$0.key] = $1 }, delete: { self.values.removeValue(forKey: $0.key) })
    }
}
