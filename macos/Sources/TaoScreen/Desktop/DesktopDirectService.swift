import Combine
import CryptoKit
import Foundation
import Network

struct DesktopNearbyDevice: Identifiable {
    let endpoint: NWEndpoint
    let name: String
    var id: NWEndpoint { endpoint }
}

enum DesktopDirectEndpoint {
    static let port = NWEndpoint.Port(integerLiteral: 45871)

    static func parse(_ input: String, defaultPort: NWEndpoint.Port = port) -> NWEndpoint? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ipv6 = IPv6Address(address) { return .hostPort(host: .ipv6(ipv6), port: defaultPort) }
        guard let url = URLComponents(string: "tcp://\(address)"), let name = url.host, !name.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              !address.contains(where: \.isWhitespace) else { return nil }
        let host = NWEndpoint.Host(name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name)
        if let number = url.port {
            guard let value = UInt16(exactly: number), value != 0, let selected = NWEndpoint.Port(rawValue: value) else {
                return nil
            }
            return .hostPort(host: host, port: selected)
        }
        return .hostPort(host: host, port: defaultPort)
    }

    static func allowsIncoming(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return allowsIPv4(Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return allowsIPv4(Array(bytes.suffix(4)))
            }
            return address == .loopback || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        default: return false
        }
    }

    private static func allowsIPv4(_ bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (172, 16...31), (192, 168), (169, 254), (100, 64...127): return true
        default: return false
        }
    }
}

/// TLS 上承载有长度上限的 JSON 帧。每个方向按发送顺序处理信令。
@MainActor
final class DesktopDirectTransport {
    private static let frameLimit = 64 * 1024
    private let connection: NWConnection
    private var reader: Task<Void, Never>?
    private var handshakeTimeout: Task<Void, Never>?
    private var ended = false
    private var queuedWrites = 0
    var onReady: (() throws -> Void)?
    var onFrame: ((Data) async throws -> Void)?
    var onClose: ((String?) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }
    var peerPublicKey: Data? { DesktopDirectIdentity.peerPublicKey(connection) }
    var remoteEndpoint: NWEndpoint { connection.currentPath?.remoteEndpoint ?? connection.endpoint }

    func start() {
        handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.cancel("连接超时，请检查地址、防火墙和连接码。")
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.ended else { return }
                switch state {
                case .ready:
                    do { try self.onReady?() } catch { self.cancel(error.localizedDescription); return }
                    self.reader = Task { [weak self] in await self?.readFrames() }
                case .failed(let error), .waiting(let error):
                    if case .tls = error { self.cancel("无法验证直连身份，请检查连接码或设备授权。") }
                    else { self.cancel("直连网络不可用：\(error.localizedDescription)") }
                case .cancelled: self.cancel("直连已关闭。")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    func confirmed() { handshakeTimeout?.cancel(); handshakeTimeout = nil }

    func send<Message: Encodable>(_ message: Message) throws {
        let data = try JSONEncoder().encode(message)
        guard !ended, data.count <= Self.frameLimit, queuedWrites < 256 else {
            throw CloudError("直连信令通道不可用或消息过大。")
        }
        let count = UInt32(data.count)
        let header = Data([UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                           UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        queuedWrites += 1
        connection.send(content: header + data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queuedWrites -= 1
                if let error { self.cancel(error.localizedDescription) }
            }
        })
    }

    func cancel(_ reason: String? = nil) {
        guard !ended else { return }
        let onClose = self.onClose
        stopReading()
        connection.cancel()
        onClose?(reason)
    }

    func finish() {
        guard !ended else { return }
        stopReading()
        let connection = self.connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection.cancel() }
    }

    private func stopReading() {
        ended = true
        reader?.cancel(); reader = nil
        confirmed()
        connection.stateUpdateHandler = nil
        onClose = nil; onFrame = nil; onReady = nil
    }

    private func readFrames() async {
        do {
            while !ended {
                let header = try await read(count: 4)
                guard !ended else { return }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                guard (1...Self.frameLimit).contains(length) else { throw CloudError("收到无效的直连信令长度。") }
                let data = try await read(count: length)
                guard !ended else { return }
                try await onFrame?(data)
            }
        } catch { cancel(error.localizedDescription) }
    }

    private func read(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CloudError("对方已关闭直连。")) }
            }
        }
    }
}

@MainActor
final class DesktopDirectService: ObservableObject {
    static let shared: DesktopDirectService = {
        let service = DesktopDirectService(center: DesktopCenter(isDirect: true), alternateHost: .shared,
                                           store: .keychain, defaults: DesktopRuntime.defaults)
        service.center.observeLocalSession()
        service.restoreTrust()
        return service
    }()
    static let serviceType = "_taoscreen._tcp"
    let center: DesktopCenter
    @Published private(set) var nearby: [DesktopNearbyDevice] = []
    @Published private(set) var browseMessage: String?
    @Published private(set) var code: String?
    @Published private(set) var receiving = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var trustedDevices: [DesktopTrustedDevice] = []
    @Published private(set) var unattendedEnabled = false
    @Published private(set) var unattendedStatus = "无人值守已关闭"
    var listeningPort: UInt16? { reception?.listener.port?.rawValue }
    var unattendedListeningPort: UInt16? { trustedListener?.port?.rawValue }

    private struct Reception {
        let listener: NWListener
        let code: DesktopDirectCode
        let expires: Date
    }

    private struct Hello: Codable {
        var version = 1
        let id: UUID
        let name: String
        var proof: Data? = nil
        var device: DesktopDirectDeviceProof? = nil
    }

    private struct Reply: Codable {
        var version = 1
        let id: UUID
        let name: String
        var refusal: String? = nil
        var device: DesktopDirectDeviceProof? = nil
    }

    private var reception: Reception?
    private var expiry: Task<Void, Never>?
    private var pending: [UUID: DesktopDirectTransport] = [:]
    private var browser: NWBrowser?
    private var transport: DesktopDirectTransport?
    private let discoveryID = UUID().uuidString
    private let deviceName = DesktopDirectService.name(Host.current().localizedName ?? "Mac") ?? "Mac"
    private let port: NWEndpoint.Port
    private let showWindow: Bool
    private let loopbackOnly: Bool
    private let store: DesktopTrustedStore?
    private let defaults: UserDefaults?
    private let findTailscaleAddress: () async -> NWEndpoint.Host?
    private var deviceKey: P256.Signing.PrivateKey?
    private var trustedTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var trustedListener: NWListener?
    private var trustedHost: NWEndpoint.Host?
    private var trustedPending: [UUID: DesktopDirectTransport] = [:]
    private var trustedSessionKey: Data?
    private var trustedSessionIncoming = false
    private let trustedPort: NWEndpoint.Port

    init(center: DesktopCenter, alternateHost: DesktopCenter? = nil, port: NWEndpoint.Port = DesktopDirectEndpoint.port,
         showWindow: Bool = true, loopbackOnly: Bool = false, store: DesktopTrustedStore? = nil, defaults: UserDefaults? = nil,
         trustedPort: NWEndpoint.Port = DesktopTailscaleAddress.port,
         findTailscaleAddress: @escaping () async -> NWEndpoint.Host? = { await DesktopTailscaleAddress.current() }) {
        self.center = center
        self.port = port
        self.showWindow = showWindow
        self.loopbackOnly = loopbackOnly
        self.store = store
        self.defaults = defaults
        self.trustedPort = trustedPort
        self.findTailscaleAddress = findTailscaleAddress
        center.alternateHost = alternateHost
        alternateHost?.alternateHost = center
    }

    func startBrowsing() {
        guard browser == nil else { return }
        browseMessage = nil
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.browseMessage = nil
                case .failed, .waiting: self.browseMessage = "附近设备发现不可用，请检查系统的本地网络权限，或通过地址连接。"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                self.nearby = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let record) = result.metadata, record.dictionary["version"] == "1",
                          record.dictionary["id"] != self.discoveryID else { return nil }
                    return DesktopNearbyDevice(endpoint: result.endpoint, name: name)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel(); browser = nil; nearby = []
    }

    func startReceiving() {
        guard !busy, reception == nil else { return }
        do {
            let identity = try DesktopDirectIdentity()
            let parameters = DesktopDirectIdentity.parameters(identity: identity.identity)
            if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port) }
            let listener = try NWListener(using: parameters, on: port)
            if !loopbackOnly {
                listener.service = .init(name: deviceName, type: Self.serviceType,
                                         txtRecord: NWTXTRecord(["version": "1", "id": discoveryID]))
            }
            reception = .init(listener: listener, code: identity.code, expires: Date().addingTimeInterval(300))
            receiving = true; message = nil; center.message = nil
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.reception?.listener === listener else { return }
                    switch state {
                    case .ready: self.code = identity.code.text
                    case .failed(let error), .waiting(let error):
                        self.stopReceiving()
                        self.message = "无法开启直连接收：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.reception?.listener === listener else { connection.cancel(); return }
                    self.receive(connection)
                }
            }
            listener.start(queue: .main)
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.stopReceiving()
                self?.message = "连接码已过期，请重新生成。"
            }
        } catch { message = error.localizedDescription }
    }

    func stopReceiving() {
        let listener = reception?.listener
        reception = nil
        listener?.cancel()
        expiry?.cancel(); expiry = nil
        let waiting = Array(pending.values); pending.removeAll()
        for socket in waiting { socket.cancel() }
        receiving = false; code = nil
    }

    func connect(endpoint: NWEndpoint, code value: String) {
        guard !busy else { return }
        guard let code = DesktopDirectCode(value) else { message = "请粘贴被控 Mac 上完整的连接码。"; return }
        stopReceiving()
        let socket = DesktopDirectTransport(NWConnection(to: endpoint,
            using: DesktopDirectIdentity.parameters(fingerprint: code.fingerprint)))
        let id = UUID()
        transport = socket; busy = true; message = nil; center.message = nil
        let hello = Hello(id: id, name: deviceName, proof: code.proof(for: id),
                          device: makeProof(id: id, fingerprint: code.fingerprint, role: "viewer"))
        socket.onReady = { [weak socket] in try socket?.send(hello) }
        socket.onClose = { [weak self, weak socket] reason in self?.closed(socket, id: id, reason: reason) }
        socket.onFrame = { [weak self, weak socket] data in
            guard let self, let socket, self.transport === socket else { return }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard reply.version == 1, reply.id == id, let name = Self.name(reply.name) else {
                throw CloudError("对方返回的直连信息无效或版本不一致。")
            }
            if let refusal = reply.refusal { throw CloudError(refusal) }
            let peer = DesktopPeer(id: UUID(), name: name)
            let key = try reply.device?.verifiedKey(id: id, fingerprint: code.fingerprint, role: "host")
            let address: String?
            if case .hostPort(let host, _) = endpoint { address = "\(host)" } else { address = nil }
            guard self.open(socket, id: id, peer: peer, incoming: false, pairingKey: key, address: address) else {
                throw CloudError("本机当前无法建立新连接。")
            }
        }
        socket.start()
    }

    func cancelConnection() {
        connectTask?.cancel(); connectTask = nil
        if let transport { transport.cancel("已取消直连。") }
        else { busy = false }
    }

    func shutdown() {
        stopBrowsing(); stopReceiving(); stopTrustedListener(); trustedTask?.cancel(); trustedTask = nil
        center.shutdown(); cancelConnection()
    }

    private func receive(_ connection: NWConnection) {
        guard !busy, pending.count < 8, DesktopDirectEndpoint.allowsIncoming(connection.endpoint) else { connection.cancel(); return }
        let socket = DesktopDirectTransport(connection)
        let slot = UUID()
        pending[slot] = socket
        socket.onClose = { [weak self] _ in self?.pending.removeValue(forKey: slot) }
        socket.onFrame = { [weak self, weak socket] data in
            guard let self, let socket, self.pending[slot] === socket, let reception = self.reception,
                  Date() < reception.expires, !self.busy else { throw CloudError("连接码已过期或本机正忙。") }
            let hello = try JSONDecoder().decode(Hello.self, from: data)
            guard hello.version == 1, let name = Self.name(hello.name), let proof = hello.proof,
                  reception.code.verifies(proof, for: hello.id) else {
                throw CloudError("直连验证失败。")
            }
            self.pending.removeValue(forKey: slot)
            let peer = DesktopPeer(id: UUID(), name: name)
            let device = self.makeProof(id: hello.id, fingerprint: reception.code.fingerprint, role: "host")
            let key = try hello.device?.verifiedKey(id: hello.id, fingerprint: reception.code.fingerprint, role: "viewer")
            let accepted = self.open(socket, id: hello.id, peer: peer, incoming: true, pairingKey: device == nil ? nil : key)
            try socket.send(Reply(id: hello.id, name: self.deviceName,
                                 refusal: accepted ? nil : "被控 Mac 当前正忙或屏幕已锁定。", device: device))
            if !accepted { socket.finish() }
            else { self.stopReceiving() }
        }
        socket.start()
    }

    private func open(_ socket: DesktopDirectTransport, id: UUID, peer: DesktopPeer, incoming: Bool,
                      pairingKey: Data? = nil, address: String? = nil, unattendedKey: Data? = nil) -> Bool {
        let remember: (() -> Bool)? = incoming ? pairingKey.map { key in
            { [weak self] in self?.remember(key, name: peer.name, incoming: true, address: nil) == true }
        } : nil
        let authorization: (() -> DesktopTrustedGrant?)? = incoming ? unattendedKey.map { key in
            { [weak self] in self?.grant(for: key) }
        } : nil
        let opened = center.openDirectConnection(id: id, peer: peer, incoming: incoming, showWindow: showWindow,
            trusted: unattendedKey != nil, remember: remember, authorizedGrant: authorization,
            send: { [weak socket] signal in
                do { try socket?.send(signal) }
                catch { Task { @MainActor [weak socket] in socket?.cancel(error.localizedDescription) } }
            }, finish: { [weak self, weak socket] in
                guard let self, self.transport === socket else { return }
                socket?.finish(); self.transport = nil; self.busy = false
                self.trustedSessionKey = nil; self.trustedSessionIncoming = false
            })
        guard opened else { return false }
        transport = socket; busy = true
        trustedSessionKey = unattendedKey; trustedSessionIncoming = incoming && unattendedKey != nil
        socket.confirmed()
        socket.onClose = { [weak self, weak socket] reason in self?.closed(socket, id: id, reason: reason) }
        socket.onFrame = { [weak self, weak socket] data in
            guard let self, let socket, self.transport === socket else { return }
            var signal = try JSONDecoder().decode(DesktopSignal.self, from: data)
            let allowed = incoming ? ["offer", "candidate", "end"] : ["accept", "reject", "answer", "candidate", "end"]
            guard signal.id == id, allowed.contains(signal.type) else { throw CloudError("收到不属于本次连接的直连信令。") }
            signal.from = peer.id
            if !incoming, signal.type == "accept", signal.payload?.paired == true, let pairingKey {
                _ = self.remember(pairingKey, name: peer.name, incoming: false, address: address)
            }
            await self.center.receive(signal)
        }
        return true
    }

    private func closed(_ socket: DesktopDirectTransport?, id: UUID, reason: String?) {
        guard let socket, transport === socket else { return }
        transport = nil; busy = false; message = reason
        trustedSessionKey = nil; trustedSessionIncoming = false
        center.directConnectionClosed(id: id, reason: reason)
    }

    func restoreTrust() {
        guard let store else { return }
        do {
            if let data = try store.read("devices") {
                trustedDevices = try JSONDecoder().decode([DesktopTrustedDevice].self, from: data)
            }
            unattendedEnabled = defaults?.bool(forKey: "taoscreen.direct.unattended") == true
            refreshTrustedHosting()
        } catch { unattendedStatus = error.localizedDescription }
    }

    func setUnattended(_ enabled: Bool) {
        unattendedEnabled = enabled
        defaults?.set(enabled, forKey: "taoscreen.direct.unattended")
        if !enabled, trustedSessionIncoming { center.disconnect("本机已关闭免登录无人值守。") }
        refreshTrustedHosting()
    }

    func updateGrant(_ grant: DesktopTrustedGrant?, for key: Data) {
        guard let index = trustedDevices.firstIndex(where: { $0.publicKey == key && $0.canRequest }),
              trustedDevices[index].grant != grant else { return }
        if trustedSessionIncoming, trustedSessionKey == key { center.disconnect("本机已更改该设备的无人值守授权。") }
        var devices = trustedDevices
        devices[index].grant = grant
        guard persist(devices) else { setUnattended(false); return }
        refreshTrustedHosting()
    }

    func removeTrustedDevice(_ key: Data) {
        if trustedSessionKey == key { center.disconnect("本机已移除该设备的直连授权。") }
        guard persist(trustedDevices.filter { $0.publicKey != key }) else { setUnattended(false); return }
        refreshTrustedHosting()
    }

    func connectTrusted(_ key: Data, address: String) {
        guard !busy, let trusted = trustedDevices.first(where: { $0.publicKey == key && $0.canConnect }),
              let endpoint = DesktopDirectEndpoint.parse(address, defaultPort: trustedPort == .any ? DesktopTailscaleAddress.port : trustedPort) else { return }
        stopReceiving()
        busy = true; message = nil; center.message = nil
        connectTask = Task { [weak self] in
            guard let self else { return }
            let host = await self.findTailscaleAddress()
            let resolved: NWEndpoint?
            if let host { resolved = await DesktopTailscaleAddress.resolve(endpoint, from: host, loopbackOnly: self.loopbackOnly) }
            else { resolved = nil }
            guard !Task.isCancelled else { return }
            self.connectTask = nil
            guard let host, self.trustedDevices.contains(where: { $0.publicKey == key && $0.canConnect }) else {
                self.busy = false; self.message = "未找到可用的本机 Tailscale 地址或该设备已被移除。"; return
            }
            guard let resolved else {
                self.busy = false; self.message = "地址无法解析为可用的 Tailscale 地址，请使用被控 Mac 显示的接收地址。"; return
            }
            do {
                let identity = try DesktopDirectIdentity(deviceKey: self.getDeviceKey())
                let parameters = DesktopDirectIdentity.trustedParameters(identity: identity.identity) { $0 == key }
                parameters.requiredLocalEndpoint = .hostPort(host: host, port: .any)
                let socket = DesktopDirectTransport(NWConnection(to: resolved, using: parameters))
                self.transport = socket
                let id = UUID()
                socket.onClose = { [weak self, weak socket] reason in self?.closed(socket, id: id, reason: reason) }
                socket.onReady = { [weak self, weak socket] in
                    guard let self, let socket, self.isTrustedRoute(socket.remoteEndpoint) else {
                        throw CloudError("无人值守连接需要通过 Tailscale 地址。")
                    }
                    try socket.send(Hello(id: id, name: self.deviceName))
                }
                socket.onFrame = { [weak self, weak socket] data in
                    guard let self, let socket, self.transport === socket else { return }
                    let reply = try JSONDecoder().decode(Reply.self, from: data)
                    guard reply.version == 1, reply.id == id else { throw CloudError("对方返回的无人值守信息无效。") }
                    if let refusal = reply.refusal { throw CloudError(refusal) }
                    guard self.trustedDevices.contains(where: { $0.publicKey == key && $0.canConnect }),
                          self.open(socket, id: id, peer: .init(id: UUID(), name: trusted.name), incoming: false,
                                    unattendedKey: key) else { throw CloudError("本机当前无法建立无人值守连接。") }
                    _ = self.remember(key, name: trusted.name, incoming: false, address: address)
                }
                socket.start()
            } catch { self.busy = false; self.message = error.localizedDescription }
        }
    }

    private func getDeviceKey() throws -> P256.Signing.PrivateKey {
        if let deviceKey { return deviceKey }
        guard let store else { throw CloudError("本机设备身份不可用。") }
        let key: P256.Signing.PrivateKey
        if let data = try store.read("key") {
            key = try P256.Signing.PrivateKey(rawRepresentation: data)
        } else {
            key = P256.Signing.PrivateKey()
            try store.write("key", key.rawRepresentation)
        }
        deviceKey = key
        return key
    }

    private func makeProof(id: UUID, fingerprint: Data, role: String) -> DesktopDirectDeviceProof? {
        guard store != nil else { return nil }
        do { return try DesktopDirectDeviceProof(key: getDeviceKey(), id: id, fingerprint: fingerprint, role: role) }
        catch { message = error.localizedDescription; return nil }
    }

    private func persist(_ devices: [DesktopTrustedDevice]) -> Bool {
        guard let store else { return false }
        if devices == trustedDevices { return true }
        do {
            try store.write("devices", JSONEncoder().encode(devices))
            trustedDevices = devices
            return true
        } catch { message = error.localizedDescription; return false }
    }

    private func remember(_ key: Data, name: String, incoming: Bool, address: String?) -> Bool {
        guard key != deviceKey?.publicKey.x963Representation else { return false }
        var devices = trustedDevices
        let index = devices.firstIndex(where: { $0.publicKey == key }) ?? devices.endIndex
        if index == devices.endIndex { devices.append(.init(publicKey: key, name: name)) }
        devices[index].name = name
        if incoming { devices[index].canRequest = true }
        else {
            devices[index].canConnect = true
            if let address { devices[index].address = address }
        }
        return persist(devices)
    }

    private func grant(for key: Data) -> DesktopTrustedGrant? {
        guard unattendedEnabled, trustedListener != nil else { return nil }
        return trustedDevices.first(where: { $0.publicKey == key && $0.canRequest })?.grant
    }

    private func refreshTrustedHosting() {
        trustedTask?.cancel(); trustedTask = nil
        stopTrustedListener()
        guard unattendedEnabled else { unattendedStatus = "无人值守已关闭"; return }
        guard trustedDevices.contains(where: { $0.canRequest && $0.grant != nil }) else {
            unattendedStatus = "请为一台已配对设备授予无人值守权限"; return
        }
        unattendedStatus = "正在检查 Tailscale 连接…"
        trustedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let host = await self.findTailscaleAddress()
                guard !Task.isCancelled else { return }
                if self.trustedHost != host || self.trustedListener == nil {
                    if self.trustedSessionIncoming, self.trustedHost != nil, self.trustedHost != host {
                        self.center.disconnect("Tailscale 接收地址已改变，共享已停止。")
                    }
                    self.stopTrustedListener()
                    if let host { self.listenForTrustedDevices(on: host) }
                    else { self.unattendedStatus = "未检测到 Tailscale 地址，请检查 Tailscale 是否已连接及其命令行工具是否可用。" }
                }
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
    }

    private func listenForTrustedDevices(on host: NWEndpoint.Host) {
        do {
            let identity = try DesktopDirectIdentity(deviceKey: getDeviceKey())
            let keys = Set(trustedDevices.filter { $0.canRequest && $0.grant != nil }.map(\.publicKey))
            let parameters = DesktopDirectIdentity.trustedParameters(identity: identity.identity) { keys.contains($0) }
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: trustedPort)
            let listener = try NWListener(using: parameters, on: trustedPort)
            trustedListener = listener; trustedHost = host
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.trustedListener === listener else { return }
                    switch state {
                    case .ready:
                        self.unattendedStatus = "正在通过 Tailscale 接收已授权设备 · \(host):\(listener.port?.rawValue ?? self.trustedPort.rawValue)"
                        RemoteAvailability.shared.setActive(.directUnattended, true)
                    case .failed(let error), .waiting(let error):
                        if self.trustedSessionIncoming { self.center.disconnect("Tailscale 无人值守接收已中断。") }
                        self.stopTrustedListener()
                        self.unattendedStatus = "无法开启 Tailscale 接收：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.trustedListener === listener else { connection.cancel(); return }
                    self.receiveTrusted(connection)
                }
            }
            listener.start(queue: .main)
        } catch { unattendedStatus = error.localizedDescription }
    }

    private func stopTrustedListener() {
        let listener = trustedListener
        trustedListener = nil; trustedHost = nil
        listener?.cancel()
        let waiting = Array(trustedPending.values); trustedPending.removeAll()
        for socket in waiting { socket.cancel() }
        RemoteAvailability.shared.setActive(.directUnattended, false)
    }

    private func receiveTrusted(_ connection: NWConnection) {
        guard !busy, trustedPending.count < 8, isTrustedRoute(connection.endpoint) else { connection.cancel(); return }
        let socket = DesktopDirectTransport(connection)
        let slot = UUID()
        trustedPending[slot] = socket
        socket.onClose = { [weak self] _ in self?.trustedPending.removeValue(forKey: slot) }
        socket.onFrame = { [weak self, weak socket] data in
            guard let self, let socket, self.trustedPending[slot] === socket, !self.busy,
                  let key = socket.peerPublicKey, self.grant(for: key) != nil,
                  let trusted = self.trustedDevices.first(where: { $0.publicKey == key }) else {
                throw CloudError("设备的无人值守授权已失效。")
            }
            let hello = try JSONDecoder().decode(Hello.self, from: data)
            guard hello.version == 1, hello.proof == nil, hello.device == nil else { throw CloudError("无效的无人值守请求。") }
            self.trustedPending.removeValue(forKey: slot)
            let accepted = self.open(socket, id: hello.id, peer: .init(id: UUID(), name: trusted.name), incoming: true,
                                     unattendedKey: key)
            if accepted { self.stopReceiving() }
            try socket.send(Reply(id: hello.id, name: self.deviceName,
                                 refusal: accepted ? nil : "被控 Mac 当前正忙、权限不足或无活动用户会话。"))
            if !accepted { socket.finish() }
        }
        socket.start()
    }

    private func isTrustedRoute(_ endpoint: NWEndpoint) -> Bool {
        DesktopTailscaleAddress.isTailnet(endpoint) || (loopbackOnly && DesktopDirectEndpoint.allowsIncoming(endpoint))
    }

    private static func name(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(value.prefix(64))
    }
}
