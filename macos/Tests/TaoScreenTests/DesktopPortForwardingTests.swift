import AppKit
import Foundation
import Network
import SwiftUI
import Testing
import WebRTC
@testable import TaoScreen

struct DesktopPortForwardingTests {
    @Test @MainActor func nativeNetworkHalfCloseReturnsEntireResponse() async throws {
        let server = try await PortTestServer.make(transport: .tcp, replyAfterEOF: true)
        defer { server.close() }
        let client = PortTestClient(transport: .tcp, port: server.port!)
        defer { client.close() }
        try await wait("直接 TCP 就绪") { client.ready }
        let data = Data(repeating: 1, count: 120000)
        client.send(data, finish: true)
        try await wait("直接 TCP 半关闭返回") { client.eof || client.error != nil }
        #expect(client.data.count == data.count)
        #expect(client.error == nil)
    }
    @Test func ruleValidationAndConflictsDescribeExactEndpoints() throws {
        for host in ["127.0.0.1", "::1", "localhost", "db.example.test", "host.example."] { #expect(DesktopPortRule.validHost(host)) }
        for host in ["", "http://localhost", "localhost:8080", "a/b", "[::1]", "256.1.1.1", "-host", "a..b", "a b", "."] {
            #expect(!DesktopPortRule.validHost(host))
        }
        let local = try DesktopPortRule(listenPort: 8080, destinationHost: "::1", destinationPort: 80)
        #expect(local.destination == "[::1]:80" && local.listener == "127.0.0.1:8080")
        var other = local
        other.transport = .udp
        #expect(!local.conflicts(with: other))
        other.transport = .tcp; other.direction = .remoteToLocal
        #expect(!local.conflicts(with: other))
        other.direction = .localToRemote; other.listenAddress = "0.0.0.0"
        #expect(local.conflicts(with: other))
        #expect(throws: CloudError.self) { try DesktopPortRule(listenPort: 0, destinationHost: "127.0.0.1", destinationPort: 80) }
        #expect(throws: CloudError.self) { try DesktopPortRule(listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 65536) }
        let legacy = try JSONDecoder().decode(DesktopUnattendedSettings.self,
            from: Data(#"{"enabled":true,"control":true,"audio":false}"#.utf8))
        #expect(legacy.portForwarding == nil) // 旧授权不自动扩展为网络访问授权。
    }

    @Test func datagramFragmentsPreserveEmptyAndMaximumMessagesAndRejectMixing() throws {
        for count in [0, 1, 1400, 16384, 16385, 65507] {
            let data = Data((0..<count).map { UInt8($0 % 251) })
            let packets = DesktopPortPacket.datagrams(id: UUID(), data: data)
            var assembly = DesktopPortDatagramAssembly()
            var result: Data?
            for packet in packets {
                #expect(packet.isValid)
                let encoded = try packet.encoded()
                #expect(encoded.count <= DesktopPortLimits.packet)
                let decoded = try DesktopPortPacket.decode(encoded)
                result = try assembly.append(decoded, now: 1)
            }
            #expect(result == data && assembly.id == nil)
        }
        let packets = DesktopPortPacket.datagrams(id: UUID(), data: Data(repeating: 8, count: 32000))
        var assembly = DesktopPortDatagramAssembly()
        _ = try assembly.append(packets[0], now: 0)
        var mixed = packets[1]; mixed.datagramID = UUID()
        do { _ = try assembly.append(mixed, now: 0); Issue.record("不得混合不同 UDP 数据报") } catch { }
        var expired = DesktopPortDatagramAssembly()
        _ = try expired.append(packets[0], now: 0)
        do { _ = try expired.append(packets[1], now: 11); Issue.record("不得接受超时数据报") } catch { }
        var malformed = packets[0]; malformed.parts = Int.max
        #expect(!malformed.isValid)
        malformed = packets[0]; malformed.length = Int.max
        #expect(!malformed.isValid)
        var forged = DesktopPortPacket(kind: .status, allowed: true); forged.id = UUID()
        #expect(!forged.isValid)
        #expect(throws: (any Error).self) { try DesktopPortPacket.decode(Data(repeating: 0, count: DesktopPortLimits.packet + 1)) }
    }

    @Test @MainActor func savedRulesAreIsolatedAndCorruptionCannotBeOverwritten() throws {
        let suite = "taoscreen.forward.store.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = UUID(), account = "https://one.example.test/user-a"
        let store = DesktopPortRuleStore(defaults: defaults, accountID: account, peerID: peer)
        let rule = try DesktopPortRule(name: "DNS", transport: .udp, direction: .remoteToLocal,
            listenPort: 15353, destinationHost: "127.0.0.1", destinationPort: 53)
        try store.save([rule])
        #expect(try store.load() == [rule])
        #expect(try DesktopPortRuleStore(defaults: defaults, accountID: account, peerID: UUID()).load().isEmpty)
        #expect(try DesktopPortRuleStore(defaults: defaults, accountID: "https://two.example.test/user-a", peerID: peer).load().isEmpty)
        #expect(try DesktopPortRuleStore(defaults: defaults, accountID: "https://one.example.test/user-b", peerID: peer).load().isEmpty)
        let restored = DesktopPortForwarder(host: false, store: store, allowed: { true }, send: { _ in true })
        defer { restored.close() }
        #expect(restored.rules.count == 1 && restored.rules[0].phase == .stopped)
        let key = "taoscreen.desktop.port-forward.\(account).\(peer.uuidString)"
        let corrupt = Data("invalid".utf8)
        defaults.set(corrupt, forKey: key)
        let invalid = DesktopPortForwarder(host: false, store: store, allowed: { true }, send: { _ in true })
        defer { invalid.close() }
        #expect(invalid.error != nil && !invalid.canEdit)
        #expect(throws: CloudError.self) { try invalid.save(rule) }
        #expect(defaults.data(forKey: key) == corrupt)
    }

    @Test(arguments: DesktopPortProtocol.allCases, DesktopPortDirection.allCases)
    @MainActor func bothDirectionsPreserveTCPBytesAndUDPBoundaries(transport: DesktopPortProtocol, direction: DesktopPortDirection) async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: transport)
        defer { server.close() }
        let port = try await unusedPort(transport)
        let rule = try DesktopPortRule(transport: transport, direction: direction,
            listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("监听启动") { pair.viewer.rules.first?.phase == .listening || pair.viewer.rules.first?.phase == .failed }
        try #require(pair.viewer.rules.first?.phase == .listening, "\(pair.viewer.rules.first?.error ?? pair.viewer.error ?? "未知错误")")
        let client = PortTestClient(transport: transport, port: port)
        defer { client.close() }
        try await wait("本机连接") { client.ready || client.error != nil }
        try #require(client.error == nil)
        if transport == .tcp {
            let data = Data((0..<(512 * 1024 + 31)).map { UInt8($0 % 251) })
            client.send(data)
            try await wait("TCP 全量返回", seconds: 10) { client.data.count == data.count || client.error != nil }
            #expect(client.data == data && client.error == nil)
        } else {
            let datagrams = [Data(), Data([1]), Data(repeating: 2, count: 1400),
                             Data(repeating: 3, count: 16385), Data(repeating: 4, count: 65507)]
            for datagram in datagrams { client.send(datagram) }
            try await wait("UDP 完整返回", seconds: 10) { client.messages.count == datagrams.count || client.error != nil }
            #expect(client.messages.sorted { $0.count < $1.count } == datagrams)
            #expect(server.messages.sorted { $0.count < $1.count } == datagrams)
            #expect(client.error == nil)
        }
        pair.viewer.stop(rule.id)
        try await wait("停止确认") { pair.viewer.rules.first?.phase == .stopped }
        #expect(pair.host.incomingRules.isEmpty && pair.host.connectionCount == 0 && pair.viewer.connectionCount == 0)
        #expect(!pair.host.closed && !pair.viewer.closed)
    }

    @Test(arguments: DesktopPortDirection.allCases)
    @MainActor func tcpHalfCloseStillReceivesFinalResponse(direction: DesktopPortDirection) async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: .tcp, replyAfterEOF: true)
        defer { server.close() }
        let port = try await unusedPort(.tcp)
        let rule = try DesktopPortRule(direction: direction, listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("监听") { pair.viewer.rules.first?.phase == .listening }
        let client = PortTestClient(transport: .tcp, port: port)
        defer { client.close() }
        try await wait("TCP 建连") { client.ready }
        let data = Data(repeating: 7, count: 120000)
        client.send(data, finish: true)
        try await wait("半关闭后的响应", seconds: 10) { client.eof || client.error != nil }
        #expect(client.eof)
        #expect(client.data.count == data.count)
        #expect(client.data == data)
        #expect(client.error == nil, "host=\(pair.host.error ?? "nil") viewer=\(pair.viewer.error ?? "nil") trace=\(pair.link.trace)")
    }

    @Test(arguments: DesktopPortDirection.allCases)
    @MainActor func occupiedPortFailsWithoutChangingTheConfiguredPort(direction: DesktopPortDirection) async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let occupied = try await PortTestServer.make(transport: .tcp)
        defer { occupied.close() }
        let rule = try DesktopPortRule(direction: direction, listenPort: occupied.port!, destinationHost: "127.0.0.1", destinationPort: 80)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("端口冲突回执") { pair.viewer.rules.first?.phase == .failed }
        #expect(pair.viewer.rules.first?.rule.listenPort == occupied.port)
        #expect(pair.viewer.rules.first?.error?.contains("监听") == true)
        #expect(pair.host.incomingRules.isEmpty)
    }

    @Test @MainActor func permissionRevocationClosesReverseListenerAndBothDirections() async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: .udp)
        defer { server.close() }
        for direction in DesktopPortDirection.allCases {
            let port = try await unusedPort(.udp)
            let rule = try DesktopPortRule(transport: .udp, direction: direction, listenPort: port,
                destinationHost: "127.0.0.1", destinationPort: server.port!)
            try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        }
        try await wait("双向监听") { pair.viewer.rules.allSatisfy { $0.phase == .listening } }
        pair.policy.allowed = false; pair.host.refreshPermission()
        try await wait("撤销授权") { pair.viewer.remoteAllowed == false && pair.viewer.rules.allSatisfy { !$0.running } }
        #expect(pair.host.incomingRules.isEmpty)
        #expect(pair.host.connectionCount == 0 && pair.viewer.connectionCount == 0)
        #expect(throws: CloudError.self) { try pair.viewer.start(pair.viewer.rules[0].id) }
        // 重新授权不会自动重新开启任意一条监听。
        pair.policy.allowed = true; pair.host.refreshPermission()
        #expect(pair.viewer.canStart && pair.viewer.runningCount == 0)
    }

    @Test @MainActor func ungrantedRequestsAndUnknownRunCannotOpenSockets() throws {
        let pair = PortTestPair(allowed: false)
        defer { pair.close() }
        let rule = try DesktopPortRule(listenPort: 12345, destinationHost: "127.0.0.1", destinationPort: 80)
        try pair.viewer.save(rule)
        #expect(!pair.viewer.canStart)
        #expect(throws: CloudError.self) { try pair.viewer.start(rule.id) }
        pair.host.receive(try DesktopPortPacket(kind: .startRule, id: UUID(), rule: rule).encoded())
        pair.host.receive(try DesktopPortPacket(kind: .open, id: UUID(), runID: UUID()).encoded())
        #expect(pair.host.incomingRules.isEmpty && pair.host.connectionCount == 0)
        // 由对方发送的 status 不能替代本机授权开关。
        pair.host.receive(try DesktopPortPacket(kind: .status, allowed: true).encoded())
        #expect(pair.host.closed && !pair.policy.allowed)
    }

    @Test @MainActor func startTimeoutClosesChannelWithoutAssumingSuccess() throws {
        let clock = PortTestClock(); clock.value = 10
        let pair = PortTestPair(clock: clock)
        defer { pair.close() }
        pair.link.toHostEnabled = false
        let rule = try DesktopPortRule(direction: .remoteToLocal, listenPort: 12345, destinationHost: "127.0.0.1", destinationPort: 80)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        #expect(pair.viewer.rules[0].phase == .starting)
        clock.value = 21; pair.viewer.tick()
        #expect(pair.viewer.closed && pair.viewer.error?.contains("启动确认超时") == true)
        #expect(!pair.viewer.rules[0].running)
    }

    @Test @MainActor func lateStartAndStopConfirmationsBelongToOneRunAndStoppingTimeoutIsExplicit() async throws {
        let clock = PortTestClock(); clock.value = 10
        let pair = PortTestPair(clock: clock)
        defer { pair.close() }
        let port = try await unusedPort(.udp)
        let rule = try DesktopPortRule(transport: .udp, direction: .remoteToLocal,
            listenPort: port, destinationHost: "127.0.0.1", destinationPort: 53)
        try pair.viewer.save(rule)
        pair.link.toViewerEnabled = false
        try pair.viewer.start(rule.id)
        let oldRun = try #require(pair.link.controlsToHost.last?.id)
        pair.viewer.stop(rule.id)
        #expect(pair.viewer.rules[0].phase == .stopping)
        pair.viewer.receive(try DesktopPortPacket(kind: .ruleStarted, id: oldRun).encoded())
        #expect(pair.viewer.rules[0].phase == .stopping)
        pair.link.toViewerEnabled = true
        try await wait("迟到的停止回执") { pair.viewer.rules[0].phase == .stopped }
        pair.viewer.receive(try DesktopPortPacket(kind: .ruleStarted, id: oldRun).encoded())
        #expect(pair.viewer.rules[0].phase == .stopped)
        try pair.viewer.start(rule.id)
        try await wait("新一轮启动") { pair.viewer.rules[0].phase == .listening }
        let newRun = try #require(pair.link.controlsToHost.last(where: { $0.kind == .startRule })?.id)
        #expect(newRun != oldRun)
        pair.link.toViewerEnabled = false; pair.viewer.stop(rule.id)
        clock.value = 21; pair.viewer.tick()
        #expect(pair.viewer.closed && pair.viewer.error?.contains("停止确认") == true)
        #expect(pair.host.incomingRules.isEmpty)
    }

    @Test @MainActor func udpIdleConversationCanBeRecreatedOnSameClientSocket() async throws {
        let clock = PortTestClock(); clock.value = 10
        let pair = PortTestPair(clock: clock)
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: .udp)
        defer { server.close() }
        let port = try await unusedPort(.udp)
        let rule = try DesktopPortRule(transport: .udp, listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("UDP 监听") { pair.viewer.rules[0].phase == .listening }
        let client = PortTestClient(transport: .udp, port: port)
        defer { client.close() }
        try await wait("UDP 就绪") { client.ready }
        client.send(Data([1]))
        try await wait("首次 UDP 返回") { client.messages.count == 1 }
        clock.value = 71; pair.viewer.tick(); pair.host.tick()
        #expect(pair.viewer.connectionCount == 0 && pair.host.connectionCount == 0)
        #expect(pair.viewer.rules[0].phase == .listening)
        client.send(Data([2]))
        try await wait("空闲后 UDP 返回") { client.messages.count == 2 }
        #expect(client.messages == [Data([1]), Data([2])])
    }

    @Test @MainActor func backpressureResumesWithoutDroppingBytes() async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: .tcp)
        defer { server.close() }
        let port = try await unusedPort(.tcp)
        let rule = try DesktopPortRule(listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("监听") { pair.viewer.rules[0].phase == .listening }
        let client = PortTestClient(transport: .tcp, port: port)
        defer { client.close() }
        try await wait("转发连接") { pair.viewer.rules[0].connections == 1 }
        pair.link.toHostEnabled = false
        let data = Data(repeating: 37, count: 1024 * 1024 + 73)
        client.send(data)
        try await Task.sleep(for: .milliseconds(200))
        #expect(pair.viewer.bufferedByteCount <= DesktopPortLimits.queue + DesktopPortLimits.chunk)
        #expect(!pair.viewer.closed && client.data.isEmpty)
        pair.link.toHostEnabled = true
        try await wait("拥塞恢复后完整返回", seconds: 10) { client.data.count == data.count || client.error != nil }
        #expect(client.data == data && !pair.viewer.closed)
    }

    @Test @MainActor func concurrentTCPClientsShareTheWindowWithoutMixingStreams() async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let server = try await PortTestServer.make(transport: .tcp)
        defer { server.close() }
        let port = try await unusedPort(.tcp)
        let rule = try DesktopPortRule(listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
        try pair.viewer.save(rule); try pair.viewer.start(rule.id)
        try await wait("并发测试监听") { pair.viewer.rules[0].phase == .listening }
        let clients = (0..<8).map { _ in PortTestClient(transport: .tcp, port: port) }
        defer { for client in clients { client.close() } }
        try await wait("并发客户端") { clients.allSatisfy(\.ready) }
        let data = (0..<clients.count).map { Data(repeating: UInt8($0 + 1), count: 256 * 1024 + $0) }
        for index in clients.indices { clients[index].send(data[index]) }
        try await wait("八条连接完整返回", seconds: 10) { clients.indices.allSatisfy { clients[$0].data.count == data[$0].count } }
        for index in clients.indices { #expect(clients[index].data == data[index] && clients[index].error == nil) }
        #expect(!pair.host.closed && !pair.viewer.closed)
    }

    @Test @MainActor func nativeRTCExchangesBothProtocolsAndDirectionsAndClosesOnlyPortChannelOnMalformedData() async throws {
        let configuration = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let hostRTC = try DesktopRTC(configuration: configuration, host: true, purpose: .ports)
        let viewerRTC = try DesktopRTC(configuration: configuration, host: false, purpose: .ports)
        let host = DesktopPortForwarder(host: true, allowed: { true }, send: { hostRTC.sendPortData($0) },
            transportFailure: { hostRTC.closePortChannel() })
        let viewer = DesktopPortForwarder(host: false, allowed: { true }, send: { viewerRTC.sendPortData($0) },
            transportFailure: { viewerRTC.closePortChannel() })
        defer { host.close(); viewer.close(); hostRTC.close(); viewerRTC.close() }
        hostRTC.onSignal = { type, value in if type == "candidate" { viewerRTC.addCandidate(value) } }
        viewerRTC.onSignal = { type, value in if type == "candidate" { hostRTC.addCandidate(value) } }
        hostRTC.onPortState = { host.channelChanged(open: $0) }; hostRTC.onPortData = { host.receive($0) }
        viewerRTC.onPortState = { viewer.channelChanged(open: $0) }; viewerRTC.onPortData = { viewer.receive($0) }
        let offer = try await viewerRTC.makeDescription(offer: true)
        try await hostRTC.setRemote(offer, offer: true)
        let answer = try await hostRTC.makeDescription(offer: false)
        try await viewerRTC.setRemote(answer, offer: false)
        try await wait("RTC 端口通道", seconds: 10) { viewer.canStart }
        for transport in DesktopPortProtocol.allCases {
            let server = try await PortTestServer.make(transport: transport)
            defer { server.close() }
            for direction in DesktopPortDirection.allCases {
                let port = try await unusedPort(transport)
                let rule = try DesktopPortRule(transport: transport, direction: direction, listenPort: port,
                    destinationHost: "127.0.0.1", destinationPort: server.port!)
                try viewer.save(rule); try viewer.start(rule.id)
                try await wait("RTC 监听确认") { [.listening, .failed].contains(viewer.rules.first(where: { $0.id == rule.id })?.phase) }
                try #require(viewer.rules.first(where: { $0.id == rule.id })?.phase == .listening, "\(viewer.rules.first(where: { $0.id == rule.id })?.error ?? viewer.error ?? viewer.statusText)")
                let client = PortTestClient(transport: transport, port: port)
                defer { client.close() }
                try await wait("RTC 客户端") { client.ready }
                let data = Data(repeating: 84, count: transport == .udp ? 65507 : 256 * 1024 + 11)
                client.send(data)
                try await wait("RTC 转发返回", seconds: 10) {
                    transport == .tcp ? client.data.count == data.count : client.messages.count == 1
                }
                #expect(transport == .tcp ? client.data == data : client.messages == [data])
                viewer.stop(rule.id)
                try await wait("RTC 停止确认") { viewer.rules.first(where: { $0.id == rule.id })?.phase == .stopped }
            }
        }
        let cleanupPort = try await unusedPort(.udp)
        let cleanupRule = try DesktopPortRule(transport: .udp, direction: .remoteToLocal,
            listenPort: cleanupPort, destinationHost: "127.0.0.1", destinationPort: 53)
        try viewer.save(cleanupRule); try viewer.start(cleanupRule.id)
        try await wait("用于断连清理验证的反向监听") { viewer.rules.last?.phase == .listening }
        #expect(viewerRTC.sendPortData(Data("malformed".utf8)))
        try await wait("仅关闭端口通道") { host.closed && viewer.closed }
        #expect(!hostRTC.closed && !viewerRTC.closed)
        #expect(host.incomingRules.isEmpty && viewer.runningCount == 0)
        let rebound = try DesktopPortUDPListener(address: "127.0.0.1", port: cleanupPort)
        rebound.close() // 验证远端监听的实际描述符已释放。
    }

    @Test @MainActor func independentSessionsKeepExistingTCPAndUDPFlowsAfterDesktopCloses() async throws {
        let pair = PortSessionTestPair()
        defer { pair.close() }
        pair.viewer.request()
        #expect(pair.host.phase == .awaitingApproval)
        #expect(pair.configurations == 0 && !pair.viewer.forwarder.canStart)
        pair.host.accept()
        try await wait("独立端口连接", seconds: 10) { pair.viewer.forwarder.canStart && pair.host.connected }
        #expect(pair.configurations == 2)
        for value in pair.signals where value.type == "offer" || value.type == "answer" {
            let sdp = try #require(value.payload?.sdp)
            #expect(sdp.contains("m=application "))
            #expect(!sdp.contains("m=video ") && !sdp.contains("m=audio "))
        }
        let config = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let desktopHost = try DesktopRTC(configuration: config, host: true)
        let desktopViewer = try DesktopRTC(configuration: config, host: false)
        defer { desktopHost.close(); desktopViewer.close() }
        desktopHost.onSignal = { kind, value in if kind == "candidate" { desktopViewer.addCandidate(value) } }
        desktopViewer.onSignal = { kind, value in if kind == "candidate" { desktopHost.addCandidate(value) } }
        var controlOpen = false
        desktopViewer.onControlOpen = { controlOpen = true }
        let offer = try await desktopViewer.makeDescription(offer: true)
        try await desktopHost.setRemote(offer, offer: true)
        let answer = try await desktopHost.makeDescription(offer: false)
        try await desktopViewer.setRemote(answer, offer: false)
        try await wait("并行桌面连接", seconds: 10) { controlOpen }
        var servers: [PortTestServer] = [], clients: [(DesktopPortProtocol, PortTestClient)] = []
        defer { for server in servers { server.close() }; for (_, client) in clients { client.close() } }
        for transport in DesktopPortProtocol.allCases {
            let server = try await PortTestServer.make(transport: transport); servers.append(server)
            for direction in DesktopPortDirection.allCases {
                let port = try await unusedPort(transport)
                let rule = try DesktopPortRule(transport: transport, direction: direction,
                    listenPort: port, destinationHost: "127.0.0.1", destinationPort: server.port!)
                try pair.viewer.forwarder.save(rule); try pair.viewer.forwarder.start(rule.id)
                try await wait("独立转发监听") { [.listening, .failed].contains(pair.viewer.forwarder.rules.first(where: { $0.id == rule.id })?.phase) }
                try #require(pair.viewer.forwarder.rules.first(where: { $0.id == rule.id })?.phase == .listening, "\(pair.viewer.forwarder.rules.first(where: { $0.id == rule.id })?.error ?? pair.viewer.failure ?? pair.viewer.forwarder.statusText)")
                let client = PortTestClient(transport: transport, port: port); clients.append((transport, client))
                try await wait("转发客户端") { client.ready }
                client.send(Data([7]))
                try await wait("桌面仍连接时转发成功") { transport == .tcp ? client.data == Data([7]) : client.messages == [Data([7])] }
            }
        }
        desktopHost.close(); desktopViewer.close()
        for (transport, client) in clients {
            let data = Data(repeating: 43, count: transport == .tcp ? 256000 : 65507)
            client.send(data)
            try await wait("桌面断开后既有流继续转发", seconds: 10) {
                transport == .tcp ? client.data.count == data.count + 1 : client.messages.count == 2
            }
            #expect(transport == .tcp ? client.data == Data([7]) + data : client.messages == [Data([7]), data])
        }
        #expect(pair.host.connected && pair.viewer.connected)
        #expect(pair.viewer.forwarder.runningCount == 4)
        pair.host.disconnect()
        try await wait("独立断开清理两端监听") { pair.viewer.phase == .closed }
        #expect(pair.host.forwarder.closed && pair.viewer.forwarder.closed)
        #expect(pair.host.forwarder.incomingRules.isEmpty && pair.viewer.forwarder.runningCount == 0)
    }

    @Test @MainActor func independentConsentCannotBeReplacedByForgedOrDesktopMessages() async throws {
        let pair = PortSessionTestPair()
        defer { pair.close() }
        pair.viewer.request()
        await pair.viewer.receive(.init(type: "accept", id: pair.viewer.id, from: UUID()))
        await pair.host.receive(.init(type: "offer", id: pair.host.id, from: pair.host.peer.id, payload: .init(sdp: "unapproved")))
        #expect(pair.configurations == 0 && !pair.viewer.forwarder.canStart)
        pair.host.reject()
        try await wait("拒绝独立授权") { pair.viewer.phase == .closed }
        #expect(pair.configurations == 0)
        let rtc = try DesktopRTC(configuration: .init(iceServers: [], relayAvailable: false), host: true, purpose: .ports)
        defer { rtc.close() }
        do {
            try await rtc.setRemote("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n", offer: true)
            Issue.record("端口通道不能接受桌面视频轨道")
        } catch { #expect(error.localizedDescription == "独立端口连接不接受屏幕或声音轨道。") }
    }

    @Test @MainActor func independentRecoveryRequiresOriginalNonceAndPortDisconnectKeepsDesktop() async throws {
        let pair = PortSessionTestPair()
        defer { pair.close() }
        pair.viewer.signalHello(resume: true, keepalive: true)
        pair.viewer.request(); pair.host.accept()
        try await wait("独立端口就绪", seconds: 10) { pair.viewer.forwarder.canStart }
        pair.viewer.signalInterrupted()
        #expect(pair.viewer.recovering && pair.viewer.forwarder.canStart)
        pair.viewer.signalHello(resume: true, keepalive: true)
        let request = try #require(pair.signals.last(where: { $0.type == "resume" }))
        await pair.viewer.receive(.init(type: "resumed", id: request.id, from: pair.viewer.peer.id,
            payload: .init(resumeToken: UUID())))
        #expect(pair.viewer.recovering)
        await pair.viewer.receive(.init(type: "resumed", id: request.id, from: pair.viewer.peer.id,
            payload: .init(resumeToken: request.payload?.resumeToken)))
        #expect(!pair.viewer.recovering && pair.viewer.connected)
        let config = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: config, host: true), viewer = try DesktopRTC(configuration: config, host: false)
        defer { host.close(); viewer.close() }
        host.onSignal = { kind, value in if kind == "candidate" { viewer.addCandidate(value) } }
        viewer.onSignal = { kind, value in if kind == "candidate" { host.addCandidate(value) } }
        var controlOpen = false, received = false
        viewer.onControlOpen = { controlOpen = true }; host.onInput = { _ in received = true }
        try await host.setRemote(viewer.makeDescription(offer: true), offer: true)
        try await viewer.setRemote(host.makeDescription(offer: false), offer: false)
        try await wait("并行桌面数据通道", seconds: 10) { controlOpen }
        pair.viewer.disconnect()
        try await wait("独立断开") { pair.host.phase == .closed }
        #expect(!host.closed && !viewer.closed)
        viewer.send(.init(kind: "release"))
        try await wait("关闭转发后桌面控制仍可用") { received }
    }

    @Test @MainActor func desktopShutdownDoesNotChangeIndependentServicePreferenceOrWakeRequest() throws {
        let suite = "taoscreen.ports.lifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DesktopCenter(defaults: defaults)
        center.portService.enabled = true
        center.disconnect(); center.shutdown(); center.enabled = false
        #expect(center.portService.enabled && defaults.bool(forKey: DesktopPortService.enabledKey))
        var begins = 0, ends = 0
        let availability = RemoteAvailability(defaults: defaults, begin: { begins += 1; return NSObject() }, end: { _ in ends += 1 })
        availability.setActive(.ports, true); availability.setActive(.desktop, true)
        availability.setActive(.desktop, false)
        #expect(availability.keepingAwake && begins == 1 && ends == 0)
        availability.setActive(.ports, false)
        #expect(!availability.keepingAwake && ends == 1)
    }

    @Test func legacyRulesStayDisabledAndDuplicateDraftNeedsANewPort() throws {
        let original = try DesktopPortRule(name: "数据库", transport: .udp, direction: .remoteToLocal,
            listenPort: 15432, destinationHost: "db.example.test", destinationPort: 5432, isEnabled: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "isEnabled")
        let legacy = try JSONDecoder().decode(DesktopPortRule.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!legacy.isEnabled)
        #expect(try JSONDecoder().decode(DesktopPortRule.self, from: JSONEncoder().encode(original)).isEnabled)
        var draft = DesktopPortRuleDraft(rule: original, duplicate: true)
        #expect(draft.id != original.id && !draft.editing && draft.listenPort.isEmpty)
        #expect(draft.errors[.listenPort] == "必填")
        #expect(draft.destinationHost == original.destinationHost && draft.transport == .udp && draft.direction == .remoteToLocal)
        #expect(throws: CloudError.self) { try draft.makeRule() }
        draft.listenPort = " 15433 "
        let copy = try draft.makeRule()
        #expect(copy.listenPort == 15433 && copy.isEnabled && copy.id != original.id)
        for invalid in ["0", "65536", "+22", "22.0", "２２", "22/tcp"] {
            draft.listenPort = invalid
            #expect(draft.errors[.listenPort] != nil)
        }
    }

    @Test @MainActor func enabledIntentWaitsForAuthorizationAndDoesNotCreateDuplicateListeners() async throws {
        let pair = PortTestPair(allowed: false)
        defer { pair.close() }
        let rule = try await DesktopPortRule(listenPort: unusedPort(.tcp), destinationHost: "127.0.0.1", destinationPort: 80, isEnabled: true)
        try pair.viewer.save(rule)
        #expect(pair.viewer.rules[0].rule.isEnabled && pair.viewer.runningCount == 0)
        #expect(pair.link.controlsToHost.isEmpty)
        pair.policy.allowed = true; pair.host.refreshPermission()
        try await wait("授权后启动已启用规则") { pair.viewer.rules[0].phase == .listening }
        for _ in 0..<3 { pair.viewer.refreshPermission(); pair.host.refreshPermission() }
        #expect(pair.link.controlsToHost.filter { $0.kind == .startRule }.count == 1)
        try pair.viewer.setEnabled(rule.id, false)
        try await wait("停用释放监听") { !pair.viewer.rules[0].running }
        #expect(!pair.viewer.rules[0].rule.isEnabled)
        #expect(pair.host.incomingRules.isEmpty)
    }

    @Test(arguments: DesktopPortProtocol.allCases, DesktopPortDirection.allCases)
    @MainActor func enabledRulesRestoreAcrossConnectionsAndPreserveRealTraffic(transport: DesktopPortProtocol, direction: DesktopPortDirection) async throws {
        let suite = "taoscreen.mapping.restore.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DesktopPortRuleStore(defaults: defaults, accountID: "test-account", peerID: UUID())
        let server = try await PortTestServer.make(transport: transport)
        defer { server.close() }
        let port = try await unusedPort(transport)
        let rule = try DesktopPortRule(transport: transport, direction: direction, listenPort: port,
            destinationHost: "127.0.0.1", destinationPort: server.port!, isEnabled: true)
        let offline = DesktopPortForwarder(host: false, store: store, allowed: { false }, send: { _ in false })
        try offline.save(rule)
        #expect(offline.runningCount == 0)
        offline.close()
        #expect(!offline.canEdit)
        let pair = PortTestPair(store: store)
        defer { pair.close() }
        try await wait("重连恢复启用规则") { pair.viewer.rules.first?.phase == .listening }
        let client = PortTestClient(transport: transport, port: port)
        defer { client.close() }
        try await wait("映射客户端连接") { client.ready }
        let data = Data("自动恢复后的真实转发".utf8)
        client.send(data)
        try await wait("映射回包") { transport == .tcp ? client.data == data : client.messages == [data] }
        #expect(client.error == nil)
        pair.close()
        let restored = PortTestPair(store: store)
        defer { restored.close() }
        try await wait("再次恢复原端口") { restored.viewer.rules.first?.phase == .listening }
        try restored.viewer.setEnabled(rule.id, false)
        try await wait("保存停用状态") { restored.viewer.runningCount == 0 }
        restored.close()
        let disabled = PortTestPair(store: store)
        defer { disabled.close() }
        #expect(!disabled.viewer.rules[0].rule.isEnabled && disabled.viewer.runningCount == 0)
        #expect(disabled.link.controlsToHost.isEmpty)
    }

    @Test @MainActor func resumeWaitsForPreviousStopReceiptAndUsesANewRunID() async throws {
        let pair = PortTestPair()
        defer { pair.close() }
        let rule = try await DesktopPortRule(transport: .udp, direction: .remoteToLocal,
            listenPort: unusedPort(.udp), destinationHost: "127.0.0.1", destinationPort: 53, isEnabled: true)
        try pair.viewer.save(rule)
        try await wait("初始自动监听") { pair.viewer.rules[0].phase == .listening }
        let previous = try #require(pair.link.controlsToHost.last(where: { $0.kind == .startRule })?.id)
        pair.link.toViewerEnabled = false; pair.viewerPolicy.allowed = false
        pair.viewer.sessionInterrupted()
        #expect(pair.viewer.rules[0].phase == .stopping)
        pair.viewerPolicy.allowed = true; pair.viewer.refreshPermission()
        #expect(pair.link.controlsToHost.filter { $0.kind == .startRule }.count == 1)
        pair.link.toViewerEnabled = true
        try await wait("停止回执后重新监听") { pair.viewer.rules[0].phase == .listening }
        let current = try #require(pair.link.controlsToHost.last(where: { $0.kind == .startRule })?.id)
        #expect(current != previous)
        pair.viewer.receive(try DesktopPortPacket(kind: .ruleStopped, id: previous).encoded())
        #expect(pair.viewer.rules[0].phase == .listening)
    }

    @Test @MainActor func occupiedEnabledRuleReportsFailureAndOnlyRetriesWhenRequested() async throws {
        let occupied = try await PortTestServer.make(transport: .tcp)
        defer { occupied.close() }
        let pair = PortTestPair()
        defer { pair.close() }
        let rule = try DesktopPortRule(listenPort: occupied.port!, destinationHost: "127.0.0.1", destinationPort: 80, isEnabled: true)
        try pair.viewer.save(rule)
        try await wait("端口占用失败") { pair.viewer.rules[0].phase == .failed }
        #expect(pair.viewer.rules[0].rule.isEnabled && pair.viewer.rules[0].error != nil)
        for _ in 0..<3 { pair.host.refreshPermission(); pair.viewer.refreshPermission() }
        #expect(pair.link.controlsToHost.filter { $0.kind == .startRule }.count == 1)
        try pair.viewer.setEnabled(rule.id, false)
        #expect(!pair.viewer.rules[0].rule.isEnabled)
    }

    @Test func offlineDeviceCatalogIsIsolatedAndRejectsCorruption() throws {
        let suite = "taoscreen.mapping.devices.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = DesktopPortDeviceStore(defaults: defaults, accountID: "one")
        let other = DesktopPortDeviceStore(defaults: defaults, accountID: "other")
        let peer = DesktopPeer(id: UUID(), name: "工作电脑")
        try one.save([peer])
        #expect(try one.load() == [peer] && other.load().isEmpty)
        #expect(throws: CloudError.self) { try one.save([peer, peer]) }
        #expect(try one.load() == [peer])
        defaults.set(Data("broken".utf8), forKey: "taoscreen.ports.devices.one")
        #expect(throws: (any Error).self) { try one.load() }
    }

    @Test @MainActor func exportPortEditorPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["TAOSCREEN_PORTS_PREVIEW"] else { return }
        _ = NSApplication.shared
        let suite = "taoscreen.ports.preview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DesktopPortService(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let view = NSHostingView(rootView: DesktopPortForwardingSheet(service: service)
            .frame(width: 740, height: 760).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = view; view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        let output = URL(fileURLWithPath: path).deletingLastPathComponent()
        let forwarder = DesktopPortForwarder(host: false, allowed: { false }, send: { _ in false })
        defer { forwarder.close() }
        try forwarder.save(DesktopPortRule(name: "开发后台", listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 3000, isEnabled: true))
        try forwarder.save(DesktopPortRule(name: "数据库", listenPort: 15432, destinationHost: "db.internal.example", destinationPort: 5432))
        try forwarder.save(DesktopPortRule(name: "局域网 DNS", transport: .udp, listenPort: 15353, destinationHost: "192.168.1.1", destinationPort: 53, isEnabled: true))
        func export<V: View>(_ content: V, name: String, width: CGFloat, height: CGFloat, dark: Bool) throws {
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false; preview.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { preview.close() }
            let host = NSHostingView(rootView: content.frame(width: width, height: height)
                .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            preview.contentView = host; host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        }
        for dark in [false, true] {
            let content = VStack(alignment: .leading, spacing: 20) {
                HStack { Text("工作电脑").font(.title2.bold()); Text("未连接").foregroundStyle(.secondary); Spacer(); Button("重新连接") {} }
                DesktopPortRulesEditor(forwarder: forwarder, peerName: "工作电脑")
            }.padding(20)
            try export(content, name: dark ? "mapping-list-dark.png" : "mapping-list-light.png", width: 940, height: 520, dark: dark)
            try export(DesktopPortRuleEditorSheet(draft: .init(), forwarder: forwarder, peerName: "工作电脑"),
                name: dark ? "mapping-editor-dark.png" : "mapping-editor-light.png", width: 560, height: 540, dark: dark)
        }
    }

    @MainActor private func unusedPort(_ transport: DesktopPortProtocol) async throws -> Int {
        let server = try await PortTestServer.make(transport: transport)
        let port = server.port!
        try await server.closeAndWait()
        return port
    }
    @MainActor private func wait(_ description: String, seconds: Double = 5, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { throw CloudError("测试等待超时：\(description)") }
    }
}

/// 模拟已认证的独立信令路由；两端逐条处理，实际数据通过原生 WebRTC 传输。
@MainActor private final class PortSessionTestPair {
    var host: DesktopPortSession!
    var viewer: DesktopPortSession!
    var signals: [DesktopSignal] = []
    var configurations = 0
    private var hostQueue: Task<Void, Never>?
    private var viewerQueue: Task<Void, Never>?
    init() {
        let id = UUID(), hostID = UUID(), viewerID = UUID()
        let configuration: () async throws -> DesktopConfiguration = { [unowned self] in
            configurations += 1; return .init(iceServers: [], relayAvailable: false)
        }
        host = DesktopPortSession(id: id, peer: .init(id: viewerID, name: "请求设备"), host: true,
            configuration: configuration, send: { [weak self] in self?.route($0, from: hostID, toHost: false) })
        viewer = DesktopPortSession(id: id, peer: .init(id: hostID, name: "目标设备"), host: false,
            configuration: configuration, send: { [weak self] in self?.route($0, from: viewerID, toHost: true) })
    }
    private func route(_ signal: DesktopSignal, from: UUID, toHost: Bool) {
        var value = signal; value.from = from; signals.append(value)
        if value.type == "invite" { host.awaitApproval(); return }
        let previous = toHost ? hostQueue : viewerQueue
        let target = toHost ? host! : viewer!
        let task = Task { await previous?.value; await target.receive(value) }
        if toHost { hostQueue = task } else { viewerQueue = task }
    }
    func close() { host.disconnect(notify: false); viewer.disconnect(notify: false); hostQueue?.cancel(); viewerQueue?.cancel() }
}

@MainActor private final class PortTestClock {
    var value: TimeInterval?
    var time: TimeInterval { value ?? ProcessInfo.processInfo.systemUptime }
}
@MainActor private final class PortTestPolicy { var allowed = true }
@MainActor private final class PortTestLink {
    weak var host: DesktopPortForwarder?
    weak var viewer: DesktopPortForwarder?
    var toHostEnabled = true
    var toViewerEnabled = true
    var trace: [String] = []
    var controlsToHost: [DesktopPortPacket] = []
    func toHost(_ data: Data) -> Bool {
        guard toHostEnabled else { return false }
        if let packet = try? DesktopPortPacket.decode(data) {
            trace.append("H \(packet.kind) \(packet.payload?.count ?? packet.bytes ?? 0) \(packet.message ?? "")")
            if packet.kind == .startRule || packet.kind == .stopRule { controlsToHost.append(packet) }
        }
        host?.receive(data); return true
    }
    func toViewer(_ data: Data) -> Bool {
        guard toViewerEnabled else { return false }
        if let packet = try? DesktopPortPacket.decode(data) { trace.append("V \(packet.kind) \(packet.payload?.count ?? packet.bytes ?? 0) \(packet.message ?? "")") }
        viewer?.receive(data); return true
    }
}
@MainActor private final class PortTestPair {
    let link = PortTestLink()
    let policy = PortTestPolicy()
    let viewerPolicy = PortTestPolicy()
    let host: DesktopPortForwarder
    let viewer: DesktopPortForwarder
    init(allowed: Bool = true, clock: PortTestClock = PortTestClock(), store: DesktopPortRuleStore? = nil) {
        policy.allowed = allowed
        let link = self.link, policy = self.policy, viewerPolicy = self.viewerPolicy
        host = DesktopPortForwarder(host: true, allowed: { policy.allowed }, send: { link.toViewer($0) }, now: { clock.time })
        viewer = DesktopPortForwarder(host: false, store: store, allowed: { viewerPolicy.allowed }, send: { link.toHost($0) }, now: { clock.time })
        link.host = host; link.viewer = viewer
        host.channelChanged(open: true); viewer.channelChanged(open: true)
    }
    func close() { host.close(); viewer.close() }
}

@MainActor private final class PortTestServer {
    private var listener: NWListener?
    private var udpListener: DesktopPortUDPListener?
    private var udpSockets: [DesktopPortUDPSocket] = []
    let transport: DesktopPortProtocol
    let replyAfterEOF: Bool
    var port: Int?
    var error: String?
    var messages: [Data] = []
    private var stopped = false
    private var sockets: [NWConnection] = []
    private var collected: [ObjectIdentifier: Data] = [:]
    private init(transport: DesktopPortProtocol, replyAfterEOF: Bool) throws {
        self.transport = transport; self.replyAfterEOF = replyAfterEOF
        if transport == .udp {
            let listener = try DesktopPortUDPListener(address: "127.0.0.1", port: 0)
            self.udpListener = listener; port = listener.port
            listener.onConnection = { [weak self] socket in
                guard let self else { socket.close(); return }
                self.udpSockets.append(socket); self.readUDP(socket)
            }
            listener.onError = { [weak self] in self?.error = $0 }
            return
        }
        let parameters: NWParameters = transport == .tcp ? .tcp : .udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.port = self.listener?.port.map { Int($0.rawValue) }
                case .failed(let error), .waiting(let error): self.error = error.localizedDescription
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] socket in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { socket.cancel(); return }
                self.sockets.append(socket)
                socket.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated { if case .ready = state { self?.read(socket) } }
                }
                socket.start(queue: .main)
            }
        }
        listener.start(queue: .main)
    }
    private func readUDP(_ socket: DesktopPortUDPSocket) {
        socket.receive { [weak self, weak socket] data, error in
            guard let self, let socket, !self.stopped else { return }
            guard let data, error == nil else { self.error = error ?? "UDP 测试服务读取失败"; return }
            self.messages.append(data)
            socket.send(data) { [weak self] error in if let error { self?.error = error } }
            self.readUDP(socket)
        }
    }
    static func make(transport: DesktopPortProtocol, replyAfterEOF: Bool = false) async throws -> PortTestServer {
        let server = try PortTestServer(transport: transport, replyAfterEOF: replyAfterEOF)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while server.port == nil && server.error == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard server.port != nil else { server.close(); throw CloudError("测试服务监听失败：\(server.error ?? "超时")") }
        return server
    }
    private func read(_ socket: NWConnection) {
        guard !stopped else { return }
        let receive: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, error == nil else { return }
                if self.transport == .udp {
                    let message = data ?? Data(); self.messages.append(message)
                    socket.send(content: message, completion: .contentProcessed { _ in })
                    self.read(socket)
                } else if self.replyAfterEOF {
                    let key = ObjectIdentifier(socket)
                    if let data { self.collected[key, default: Data()].append(data) }
                    if complete {
                        socket.send(content: self.collected.removeValue(forKey: key) ?? Data(), contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in })
                    } else { self.read(socket) }
                } else {
                    if let data, !data.isEmpty { socket.send(content: data, completion: .contentProcessed { _ in }) }
                    if complete { socket.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
                    else { self.read(socket) }
                }
            }
        }
        if transport == .udp { socket.receiveMessage(completion: receive) }
        else { socket.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: receive) }
    }
    func closeAndWait() async throws {
        guard let listener else { close(); return } // UDP 描述符在 close 中同步释放。
        var cancelled = false
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated { if case .cancelled = state { cancelled = true } }
        }
        close(preserveListenerState: true)
        defer { listener.stateUpdateHandler = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !cancelled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard cancelled else { throw CloudError("测试监听未确认关闭，未复用该端口。") }
    }
    func close(preserveListenerState: Bool = false) {
        stopped = true
        if !preserveListenerState { listener?.stateUpdateHandler = nil }
        listener?.newConnectionHandler = nil; listener?.cancel()
        udpListener?.close(); udpListener = nil
        for socket in udpSockets { socket.close() }; udpSockets.removeAll()
        for socket in sockets { socket.stateUpdateHandler = nil; socket.cancel() }
        sockets.removeAll()
    }
}

@MainActor private final class PortTestClient {
    private var socket: NWConnection?
    private var udpSocket: DesktopPortUDPSocket?
    let transport: DesktopPortProtocol
    var ready = false
    var error: String?
    var eof = false
    var data = Data()
    var messages: [Data] = []
    private var stopped = false
    init(transport: DesktopPortProtocol, port: Int) {
        self.transport = transport
        if transport == .udp {
            do {
                let address = try DesktopPortUDPAddress(endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!))
                let udp = try DesktopPortUDPSocket(target: address); udpSocket = udp
                udp.onError = { [weak self] in self?.error = $0 }
                ready = true; read()
            } catch { self.error = error.localizedDescription }
            return
        }
        let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        self.socket = socket
        socket.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.ready = true; self.read()
                case .failed(let error), .waiting(let error): if !self.ready { self.error = error.localizedDescription }
                default: break
                }
            }
        }
        socket.start(queue: .main)
    }
    func send(_ data: Data, finish: Bool = false) {
        if let udpSocket { udpSocket.send(data) { [weak self] in if let error = $0 { self?.error = error } }; return }
        socket?.send(content: data, contentContext: finish ? .finalMessage : .defaultMessage,
            isComplete: true, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated { if let error { self?.error = error.localizedDescription } }
            })
    }
    private func read() {
        guard !stopped else { return }
        if let udpSocket {
            udpSocket.receive { [weak self] data, error in
                guard let self, !self.stopped else { return }
                if let error { self.error = error; return }
                if let data { self.messages.append(data) }
                self.read()
            }
            return
        }
        let receive: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if let error { self.error = error.localizedDescription; return }
                if self.transport == .udp { self.messages.append(data ?? Data()); self.read() }
                else {
                    if let data { self.data.append(data) }
                    if complete { self.eof = true } else { self.read() }
                }
            }
        }
        socket?.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: receive)
    }
    func close() { stopped = true; socket?.stateUpdateHandler = nil; socket?.cancel(); udpSocket?.close(); udpSocket = nil }
}
