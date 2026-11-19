import AppKit
import CryptoKit
import Network
import Testing
import WebRTC
@testable import TaoScreen

struct DesktopDirectTests {
    @MainActor private final class TestStore {
        var values: [String: Data] = [:]

        func make(key: P256.Signing.PrivateKey, devices: [DesktopTrustedDevice]) throws -> DesktopTrustedStore {
            values = ["key": key.rawRepresentation, "devices": try JSONEncoder().encode(devices)]
            return .init(read: { [self] in values[$0] }, write: { [self] in values[$0] = $1 })
        }
    }

    @Test func deviceProofIsBoundToSessionAndRole() throws {
        let key = P256.Signing.PrivateKey()
        let id = UUID(), fingerprint = Data(repeating: 4, count: 32)
        let proof = try DesktopDirectDeviceProof(key: key, id: id, fingerprint: fingerprint, role: "host")
        #expect(try proof.verifiedKey(id: id, fingerprint: fingerprint, role: "host") == key.publicKey.x963Representation)
        #expect(throws: CloudError.self) { try proof.verifiedKey(id: id, fingerprint: fingerprint, role: "viewer") }
        #expect(throws: CloudError.self) { try proof.verifiedKey(id: UUID(), fingerprint: fingerprint, role: "host") }
        #expect(DesktopTailscaleAddress.isTailnet(NWEndpoint.Host("100.64.10.11")))
        #expect(DesktopTailscaleAddress.isTailnet(NWEndpoint.Host("fd7a:115c:a1e0::25")))
        #expect(!DesktopTailscaleAddress.isTailnet(NWEndpoint.Host("192.168.0.8")))
    }

    @Test func endpointParsingAndPrivateAddressScope() throws {
        #expect(DesktopDirectEndpoint.parse("studio.example.ts.net") == .hostPort(host: "studio.example.ts.net", port: 45871))
        #expect(DesktopDirectEndpoint.parse(" 192.168.0.20:9000 ") == .hostPort(host: "192.168.0.20", port: 9000))
        #expect(DesktopDirectEndpoint.parse("fd7a::1234") == .hostPort(host: "fd7a::1234", port: 45871))
        #expect(DesktopDirectEndpoint.parse("[fd7a::1234]:9000") == .hostPort(host: "fd7a::1234", port: 9000))
        for invalid in ["", "https://studio.example.ts.net", "abc@192.168.0.20", "192.168.0.20:0", "192.168.0.20/path"] {
            #expect(DesktopDirectEndpoint.parse(invalid) == nil)
        }
        for allowed in ["127.0.0.1", "192.168.2.30", "172.16.1.20", "100.100.11.2", "fd7a::1234", "::ffff:192.168.0.20"] {
            #expect(try DesktopDirectEndpoint.allowsIncoming(#require(DesktopDirectEndpoint.parse(allowed))))
        }
        for denied in ["203.0.113.1", "100.128.0.5", "2001:db8::40", "studio.example.ts.net"] {
            #expect(try !DesktopDirectEndpoint.allowsIncoming(#require(DesktopDirectEndpoint.parse(denied))))
        }
    }

    @Test func trustedGrantPreservesItsDisplayChoiceAndReadsLegacyGrants() throws {
        let legacy = try JSONDecoder().decode(DesktopTrustedGrant.self, from: Data(#"{"control":true,"audio":false}"#.utf8))
        #expect(legacy.shareDisplay == .main && legacy.control && !legacy.audio)
        var virtual = legacy
        virtual.virtualDisplayPreset = .ultraHD
        let restored = try JSONDecoder().decode(DesktopTrustedGrant.self, from: JSONEncoder().encode(virtual))
        #expect(restored == virtual && restored.shareDisplay == .virtual(.ultraHD))
    }

    @Test(.enabled(if: DesktopLocalSession.current.canStart(unattended: false)))
    @MainActor func authenticatedDirectInvitationRequiresHostConsent() async throws {
        _ = NSApplication.shared
        let host = DesktopDirectService(center: DesktopCenter(isDirect: true), port: .any,
                                        showWindow: false, loopbackOnly: true)
        let viewer = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false)
        defer { viewer.shutdown(); host.shutdown() }

        host.startReceiving()
        try await wait { host.code != nil }
        let value = try #require(host.code)
        let endpoint = try NWEndpoint.hostPort(host: "127.0.0.1", port: #require(host.listeningPort.flatMap(NWEndpoint.Port.init(rawValue:))))
        let code = try #require(DesktopDirectCode(value))
        let wrong = DesktopDirectCode(fingerprint: code.fingerprint)
        let other = try DesktopDirectIdentity()

        // TLS 拒绝其他证书，连接码的随机部分也要通过验证，两种失败都不会得到授权弹窗。
        for rejected in [other.code.text, wrong.text] {
            viewer.connect(endpoint: endpoint, code: rejected)
            try await wait { !viewer.busy }
            #expect(viewer.message != nil)
            #expect(host.center.invitation == nil && host.code == value)
        }

        viewer.connect(endpoint: endpoint, code: value)
        try await wait { host.center.invitation != nil && !viewer.center.viewerSessions.isEmpty }
        #expect(host.code == nil && !host.receiving)
        #expect(host.center.sessionID == nil && !host.center.isHost && !host.center.connected)
        #expect(viewer.center.viewerSessions.first?.sessionID == host.center.invitation?.id)

        host.center.reject(reason: "本次测试拒绝连接")
        try await wait { !viewer.busy && !host.busy }
        #expect(viewer.center.viewerSessions.isEmpty && host.center.invitation == nil)
        #expect(viewer.center.message?.contains("本次测试拒绝连接") == true)
    }

    @Test(.enabled(if: DesktopLocalSession.current.canHost))
    @MainActor func negotiatesWebRTCOverAuthenticatedLocalSignaling() async throws {
        _ = NSApplication.shared
        struct Hello: Decodable { let version: Int; let id: UUID; let proof: Data }
        struct Reply: Encodable { let version = 1; let id: UUID; let name = "测试被控 Mac" }
        @MainActor final class State {
            var listenPort: NWEndpoint.Port?
            var socket: DesktopDirectTransport?
            var hostConnected = false
            var input: DesktopInput?
        }
        let identity = try DesktopDirectIdentity()
        let parameters = DesktopDirectIdentity.parameters(identity: identity.identity)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let host = try DesktopRTC(configuration: .init(iceServers: [], relayAvailable: false), host: true)
        let viewer = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false)
        let state = State()
        defer { viewer.shutdown(); state.socket?.cancel(); host.close(); listener.cancel() }

        host.onState = { if $0 == .connected { state.hostConnected = true } }
        host.onInput = { state.input = $0 }
        listener.stateUpdateHandler = { phase in
            if case .ready = phase { Task { @MainActor in state.listenPort = listener.port } }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                guard state.socket == nil else { connection.cancel(); return }
                let transport = DesktopDirectTransport(connection)
                state.socket = transport
                transport.onFrame = { [weak transport] data in
                    guard let transport else { return }
                    let hello = try JSONDecoder().decode(Hello.self, from: data)
                    guard hello.version == 1, identity.code.verifies(hello.proof, for: hello.id) else {
                        throw CloudError("测试收到未经认证的邀请。")
                    }
                    transport.confirmed()
                    host.onSignal = { [weak transport] type, payload in
                        try? transport?.send(DesktopSignal(type: type, id: hello.id, payload: payload))
                    }
                    transport.onFrame = { [weak transport] data in
                        let signal = try JSONDecoder().decode(DesktopSignal.self, from: data)
                        switch signal.type {
                        case "candidate":
                            if let payload = signal.payload { host.addCandidate(payload) }
                        case "offer":
                            try await host.setRemote(try #require(signal.payload?.sdp), offer: true)
                            let sdp = try await host.makeDescription(offer: false)
                            try transport?.send(DesktopSignal(type: "answer", id: hello.id, payload: .init(sdp: sdp)))
                        default: break
                        }
                    }
                    try transport.send(Reply(id: hello.id))
                    try transport.send(DesktopSignal(type: "accept", id: hello.id, payload: .init(control: true)))
                }
                transport.start()
            }
        }
        listener.start(queue: .main)
        try await wait { state.listenPort != nil }
        let port = try #require(state.listenPort)
        viewer.connect(endpoint: .hostPort(host: "127.0.0.1", port: port), code: identity.code.text)
        try await wait { state.hostConnected && viewer.center.viewerSessions.first?.connected == true }
        let connection = try #require(viewer.center.viewerSessions.first)
        try await wait {
            connection.sendInput(.init(kind: "move", x: 0.4, y: 0.6))
            return state.input != nil
        }
        #expect(state.input?.kind == "move" && state.input?.x == 0.4 && state.input?.y == 0.6)
    }

    @Test(.enabled(if: DesktopLocalSession.current.canHost))
    @MainActor func unattendedListenerChecksBothIdentitiesAndCurrentGrant() async throws {
        try await verifyUnattendedListener(on: "127.0.0.1", loopbackOnly: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAOSCREEN_TEST_LOCAL_TAILSCALE"] == "1"))
    @MainActor func unattendedListenerBindsTheActualTailscaleAddress() async throws {
        let local = try #require(await DesktopTailscaleAddress.current())
        let hostKey = P256.Signing.PrivateKey(), viewerKey = P256.Signing.PrivateKey()
        let viewer = DesktopTrustedDevice(publicKey: viewerKey.publicKey.x963Representation, name: "Viewer",
                                          canRequest: true, grant: .init())
        let host = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false,
            store: try TestStore().make(key: hostKey, devices: [viewer]), trustedPort: .any,
            findTailscaleAddress: { local })
        defer { host.shutdown() }
        host.restoreTrust(); host.setUnattended(true)
        try await wait("Tailscale 地址监听就绪") {
            host.unattendedListeningPort != nil && host.unattendedStatus.hasPrefix("正在通过 Tailscale 接收")
        }
        host.updateGrant(nil, for: viewer.publicKey)
        #expect(host.unattendedListeningPort == nil)
    }

    @MainActor private func verifyUnattendedListener(on local: NWEndpoint.Host, loopbackOnly: Bool) async throws {
        _ = NSApplication.shared
        let hostKey = P256.Signing.PrivateKey(), viewerKey = P256.Signing.PrivateKey()
        let hostRecord = DesktopTrustedDevice(publicKey: hostKey.publicKey.x963Representation, name: "Host", canConnect: true)
        let viewerRecord = DesktopTrustedDevice(publicKey: viewerKey.publicKey.x963Representation, name: "Viewer", canRequest: true)

        var permissionChecks = 0
        let permissions = DesktopPermissions(read: {
            permissionChecks += 1
            return .init(screenRecording: false, accessibility: false, postEvents: false)
        }, request: { _ in Issue.record("无人值守不得弹出系统权限申请") })
        let host = DesktopDirectService(center: DesktopCenter(permissions: permissions, isDirect: true),
            showWindow: false, loopbackOnly: loopbackOnly, store: try TestStore().make(key: hostKey, devices: [viewerRecord]),
            trustedPort: .any, findTailscaleAddress: { local })
        let viewer = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false, loopbackOnly: loopbackOnly,
            store: try TestStore().make(key: viewerKey, devices: [hostRecord]), findTailscaleAddress: { local })
        let unknown = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false, loopbackOnly: loopbackOnly,
            store: try TestStore().make(key: P256.Signing.PrivateKey(), devices: [hostRecord]), findTailscaleAddress: { local })
        defer { viewer.shutdown(); unknown.shutdown(); host.shutdown() }
        host.restoreTrust(); viewer.restoreTrust(); unknown.restoreTrust()
        host.setUnattended(true)
        #expect(host.unattendedListeningPort == nil)
        host.updateGrant(.init(), for: viewerRecord.publicKey)
        try await wait("无人值守监听就绪") { host.unattendedListeningPort != nil }
        let port = try #require(host.unattendedListeningPort)
        let address = if case .ipv6 = local { "[\(local)]:\(port)" } else { "\(local):\(port)" }
        let before = permissionChecks

        unknown.connectTrusted(hostRecord.publicKey, address: address)
        try await wait("拒绝未授权设备") { !unknown.busy }
        #expect(unknown.message != nil && permissionChecks == before)
        #expect(!host.center.isHost && host.center.invitation == nil)

        viewer.connectTrusted(hostRecord.publicKey, address: address)
        try await wait("已授权设备通过 TLS 后检查权限") { !viewer.busy }
        // 双向 TLS 验证成功后进入 macOS 权限检查，并通过信令说明拒绝原因。
        #expect(viewer.center.message?.contains("屏幕录制") == true && permissionChecks > before)
        #expect(viewer.center.viewerSessions.isEmpty && !host.center.isHost)
        host.updateGrant(nil, for: viewerRecord.publicKey)
        #expect(host.unattendedListeningPort == nil)
        #expect(host.trustedDevices.first?.grant == nil)
    }

    @Test func elligator2MapsToCurve25519MainGroupAndSupportsCommutativePAKE() throws {
        let aMont = Field25519(u64: 486_662)
        for _ in 0..<100 {
            let uniform = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let uBytes = Field25519.mapToCurve25519(uniform)
            #expect(uBytes.count == 32)
            #expect(uBytes != Data(repeating: 0, count: 32))
            let u = Field25519(littleEndianBytes: uBytes)
            let rhs = u.squared() * u + aMont * u.squared() + u
            #expect(rhs.isSquareOrZero())
        }

        let sessionID = UUID()
        let fingerprint = Data(repeating: 0x2A, count: 32)
        let nonce = Data(repeating: 0x7B, count: 16)
        let prs = Data("test-shared-secret".utf8)
        let hostPAKE = try DesktopDirectPAKE(prs: prs, mode: .temporary, sessionID: sessionID,
                                             certFingerprint: fingerprint, nonce: nonce)
        let clientPAKE = try DesktopDirectPAKE(prs: prs, mode: .temporary, sessionID: sessionID,
                                               certFingerprint: fingerprint, nonce: nonce)
        let (clientConfirm, expectedHostConfirm) = try clientPAKE.clientConfirm(hostShare: hostPAKE.localShare)
        let actualHostConfirm = try #require(hostPAKE.hostConfirm(clientShare: clientPAKE.localShare, clientConfirm: clientConfirm))
        #expect(DesktopDirectPAKE.constantTimeEqual(actualHostConfirm, expectedHostConfirm))

        let wrongPasswordPAKE = try DesktopDirectPAKE(prs: Data("wrong-secret".utf8), mode: .temporary,
                                                      sessionID: sessionID, certFingerprint: fingerprint, nonce: nonce)
        let (badConfirm, _) = try wrongPasswordPAKE.clientConfirm(hostShare: hostPAKE.localShare)
        #expect(hostPAKE.hostConfirm(clientShare: wrongPasswordPAKE.localShare, clientConfirm: badConfirm) == nil)

        let mitmPAKE = try DesktopDirectPAKE(prs: prs, mode: .temporary, sessionID: sessionID,
                                             certFingerprint: Data(repeating: 0x3C, count: 32), nonce: nonce)
        let (mitmConfirm, _) = try mitmPAKE.clientConfirm(hostShare: hostPAKE.localShare)
        #expect(hostPAKE.hostConfirm(clientShare: mitmPAKE.localShare, clientConfirm: mitmConfirm) == nil)

        let wrongModePAKE = try DesktopDirectPAKE(prs: prs, mode: .unattendedPassword, sessionID: sessionID,
                                                  certFingerprint: fingerprint, nonce: nonce)
        let (modeConfirm, _) = try wrongModePAKE.clientConfirm(hostShare: hostPAKE.localShare)
        #expect(hostPAKE.hostConfirm(clientShare: wrongModePAKE.localShare, clientConfirm: modeConfirm) == nil)
    }

    @Test func credentialsPBKDF2AndRateLimiterBehaveAsExpected() throws {
        let code = DesktopDirectCode(fingerprint: Data(repeating: 9, count: 32)).text
        if case .directURI(let ep, let parsed) = DesktopDirectCredential.parse("taoscreen-direct://100.64.0.10:45871#\(code)") {
            #expect(ep == .hostPort(host: "100.64.0.10", port: 45871))
            #expect(parsed.text == code)
        } else {
            Issue.record("未能解析 taoscreen-direct URI")
        }
        if case .legacyCode(let parsed) = DesktopDirectCredential.parse(code) {
            #expect(parsed.text == code)
        } else {
            Issue.record("未能解析完整连接码")
        }
        if case .temporaryPassword(let norm) = DesktopDirectCredential.parse("k7m 9p4") {
            #expect(norm == "K7M9P4")
            #expect(DesktopTemporaryPassword.format(norm) == "K7M 9P4")
        } else {
            Issue.record("未能解析 6 位临时密码")
        }
        if case .fixedPassword(let fixed) = DesktopDirectCredential.parse("MyServerPass#2026") {
            #expect(fixed == "MyServerPass#2026")
        } else {
            Issue.record("未能解析固定访问密码")
        }
        for invalid in ["", "12345", "01OIAB", "short"] {
            if case .invalid = DesktopDirectCredential.parse(invalid) {} else {
                Issue.record("不应接受无效凭据：\(invalid)")
            }
        }

        let verifier = try DesktopFixedPasswordVerifier.create(password: "MyServerPass#2026", rounds: 10_000)
        #expect(try DesktopFixedPasswordVerifier.deriveKey(password: "MyServerPass#2026", salt: verifier.salt, rounds: verifier.rounds) == verifier.derivedKey)
        #expect(try DesktopFixedPasswordVerifier.deriveKey(password: "WrongPass#2026", salt: verifier.salt, rounds: verifier.rounds) != verifier.derivedKey)

        var limiter = DesktopDirectRateLimiter(maxAttempts: 5, lockoutSeconds: 60)
        let now = Date()
        for attempt in 1...4 {
            let result = limiter.recordFailure(now: now)
            #expect(!result.lockedOut && result.remainingAttempts == 5 - attempt)
            #expect(limiter.remainingLockout(now: now) == nil)
        }
        let locked = limiter.recordFailure(now: now)
        #expect(locked.lockedOut && locked.remainingAttempts == 0)
        #expect(limiter.remainingLockout(now: now) == 60)
        limiter.recordSuccess()
        #expect(limiter.remainingLockout(now: now) == nil)
    }

    @Test(.enabled(if: DesktopLocalSession.current.canStart(unattended: false)))
    @MainActor func temporaryShortPasswordAuthenticatesAndRateLimits() async throws {
        _ = NSApplication.shared
        let host = DesktopDirectService(center: DesktopCenter(isDirect: true), port: .any,
                                        showWindow: false, loopbackOnly: true)
        let viewer = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false)
        defer { viewer.shutdown(); host.shutdown() }

        host.startReceiving()
        try await wait("主机临时密码就绪") { host.temporaryPassword != nil && host.listeningPort != nil }
        let initialPassword = try #require(host.temporaryPassword)
        let endpoint = try NWEndpoint.hostPort(host: "127.0.0.1", port: #require(host.listeningPort.flatMap(NWEndpoint.Port.init(rawValue:))))

        let wrongPassword = initialPassword == "222222" ? "333333" : "222222"
        for attempt in 1...5 {
            viewer.connectWithPassword(endpoint: endpoint, password: wrongPassword, unattended: false)
            try await wait("第 \(attempt) 次错误密码响应") { !viewer.busy }
            #expect(viewer.message != nil)
            #expect(host.center.invitation == nil)
        }
        try await wait("触发限流后自动更换临时密码") { host.temporaryPassword != initialPassword }
        #expect(viewer.message?.contains("60 秒") == true)

        // 新主机实例验证正确 6 位临时密码能正常建立连接确认。
        let host2 = DesktopDirectService(center: DesktopCenter(isDirect: true), port: .any,
                                         showWindow: false, loopbackOnly: true)
        defer { host2.shutdown() }
        host2.startReceiving()
        try await wait("新主机临时密码就绪") { host2.temporaryPassword != nil && host2.listeningPort != nil }
        let endpoint2 = try NWEndpoint.hostPort(host: "127.0.0.1", port: #require(host2.listeningPort.flatMap(NWEndpoint.Port.init(rawValue:))))
        let password2 = try #require(host2.temporaryPassword)

        viewer.connectWithPassword(endpoint: endpoint2, password: DesktopTemporaryPassword.format(password2).lowercased(), unattended: false)
        try await wait("临时密码校验成功弹出确认") { host2.center.invitation != nil && !viewer.center.viewerSessions.isEmpty }
        #expect(!host2.receiving && host2.temporaryPassword == nil)

        host2.center.reject(reason: "测试拒绝临时密码连接")
        try await wait("拒绝后双方清理完成") { !viewer.busy && !host2.busy }
        #expect(viewer.center.message?.contains("测试拒绝临时密码连接") == true)
    }

    @Test(.enabled(if: DesktopLocalSession.current.canHost))
    @MainActor func tailscaleFixedPasswordUnattendedFlowAndPermissionReminder() async throws {
        _ = NSApplication.shared
        var storage: [String: Data] = [:]
        let realStore = DesktopTrustedStore(read: { storage[$0] }, write: { key, val in
            if val.isEmpty { storage.removeValue(forKey: key) } else { storage[key] = val }
        })
        var permissionChecks = 0
        let permissions = DesktopPermissions(read: {
            permissionChecks += 1
            return .init(screenRecording: false, accessibility: false, postEvents: false)
        }, request: { _ in Issue.record("固定密码无人值守不得弹出系统权限申请") })

        let suite = "taoscreen.direct.fixedpass.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = DesktopDirectService(center: DesktopCenter(permissions: permissions, isDirect: true),
                                        showWindow: false, loopbackOnly: true, store: realStore, defaults: defaults,
                                        passwordPort: .any, findTailscaleAddress: { "127.0.0.1" })
        let viewer = DesktopDirectService(center: DesktopCenter(isDirect: true), showWindow: false,
                                          loopbackOnly: true, passwordPort: .any, findTailscaleAddress: { "127.0.0.1" })
        defer { viewer.shutdown(); host.shutdown() }

        let saved = await host.saveUnattendedPassword("ServerPass#2026")
        #expect(saved && host.hasUnattendedPassword && host.unattendedPasswordSettings.enabled)
        try await wait("固定密码无人值守监听就绪") { host.unattendedPasswordListeningPort != nil }
        let port = try #require(host.unattendedPasswordListeningPort)
        let address = "127.0.0.1:\(port)"
        let before = permissionChecks

        viewer.connect(address: address, credential: "WrongServerPass#99")
        try await wait("错误固定密码被拒") { !viewer.busy }
        #expect(viewer.message?.contains("错误") == true && permissionChecks == before)
        #expect(!host.center.isHost && host.center.invitation == nil)

        viewer.connect(address: address, credential: "ServerPass#2026")
        try await wait("正确固定密码通过认证并进入权限检查") { !viewer.busy }
        #expect(permissionChecks > before)
        #expect(host.center.permissions.requester != nil)
        #expect(viewer.center.message?.contains("屏幕录制") == true)
        #expect(viewer.center.viewerSessions.isEmpty && !host.center.isHost)

        host.clearUnattendedPassword()
        #expect(!host.hasUnattendedPassword && !host.unattendedPasswordSettings.enabled)
        #expect(host.unattendedPasswordListeningPort == nil)
    }

    @MainActor private func wait(_ description: String = "直连测试状态", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CloudError("等待\(description)超时。") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
