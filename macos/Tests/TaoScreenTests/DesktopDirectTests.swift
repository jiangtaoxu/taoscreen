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

    @MainActor private func wait(_ description: String = "直连测试状态", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CloudError("等待\(description)超时。") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
