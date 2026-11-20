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
    var peerCertificateFingerprint: Data? { DesktopDirectIdentity.peerCertificateFingerprint(connection) }
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
        let service = DesktopDirectService(center: DesktopCenter(permissions: .shared, isDirect: true),
                                           alternateHost: .shared,
                                           store: .keychain, defaults: DesktopRuntime.defaults)
        service.center.observeLocalSession()
        service.restoreTrust()
        return service
    }()
    static let serviceType = "_taoscreen._tcp"
    private static let autoReceiveKey = "taoscreen.direct.autoReceive"
    private static let recentPeersKey = "taoscreen.direct.recentPeers"
    private static let unattendedPasswordSettingsKey = "taoscreen.direct.unattendedPassword"
    private static let unattendedPasswordVerifierAccount = "unattended-password-verifier"

    let center: DesktopCenter
    @Published private(set) var nearby: [DesktopNearbyDevice] = []
    @Published private(set) var browseMessage: String?
    @Published private(set) var code: String?
    @Published private(set) var temporaryPassword: String?
    var formattedTemporaryPassword: String? { temporaryPassword.map(DesktopTemporaryPassword.format) }
    @Published private(set) var receiving = false
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var trustedDevices: [DesktopTrustedDevice] = []
    @Published private(set) var unattendedEnabled = false
    @Published private(set) var unattendedStatus = "无人值守已关闭"
    @Published private(set) var networkInfo = DesktopLocalNetworkInfo()
    @Published private(set) var recentPeers: [DesktopRecentDirectPeer] = []
    @Published private(set) var unattendedPasswordSettings = DesktopUnattendedPasswordSettings()
    @Published private(set) var hasUnattendedPassword = false
    @Published private(set) var unattendedPasswordStatus = "固定密码无人值守已关闭"
    @Published var autoReceiveEnabled: Bool {
        didSet { defaults?.set(autoReceiveEnabled, forKey: Self.autoReceiveKey) }
    }
    var listeningPort: UInt16? {
        guard code != nil, let value = reception?.listener.port?.rawValue, value != 0 else { return nil }
        return value
    }
    var unattendedListeningPort: UInt16? {
        guard trustedListenerReady, let value = trustedListener?.port?.rawValue, value != 0 else { return nil }
        return value
    }
    var unattendedPasswordListeningPort: UInt16? {
        guard passwordListenerReady, let value = passwordListener?.port?.rawValue, value != 0 else { return nil }
        return value
    }
    var directShareURI: String? {
        guard let code, let address = networkInfo.primaryAddress else { return nil }
        let hostPart = address.contains(":") ? "[\(address)]" : address
        let portPart = listeningPort.map { ":\($0)" } ?? ""
        return "taoscreen-direct://\(hostPart)\(portPart)#\(code)"
    }

    private struct Reception {
        let listener: NWListener
        let identity: DesktopDirectIdentity
        let code: DesktopDirectCode
        var temporaryPassword: String
        let expires: Date
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Hello: Codable {
        var version = 1
        let id: UUID
        let name: String
        var proof: Data? = nil
        var device: DesktopDirectDeviceProof? = nil
    }

    private struct PAKEInit: Codable {
        var version = 2
        var auth = "pake"
        let mode: DesktopDirectPAKE.AuthMode
        let id: UUID
    }

    private struct PAKEChallenge: Codable {
        var version = 2
        let id: UUID
        let nonce: Data
        let salt: Data
        let rounds: Int
        let hostShare: Data
    }

    private struct PAKEAuth: Codable {
        var version = 2
        let id: UUID
        let name: String
        let clientShare: Data
        let clientConfirm: Data
        var device: DesktopDirectDeviceProof? = nil
    }

    private struct Reply: Codable {
        var version = 1
        let id: UUID
        let name: String
        var refusal: String? = nil
        var device: DesktopDirectDeviceProof? = nil
        var hostConfirm: Data? = nil
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
    private let inspectNetwork: () async -> DesktopLocalNetworkInfo
    private var deviceKey: P256.Signing.PrivateKey?
    private var trustedTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var trustedListener: NWListener?
    private var trustedListenerReady = false
    private var trustedHost: NWEndpoint.Host?
    private var trustedPending: [UUID: DesktopDirectTransport] = [:]
    private var trustedSessionKey: Data?
    private var trustedSessionIncoming = false
    private let trustedPort: NWEndpoint.Port
    private let passwordPort: NWEndpoint.Port
    private var unattendedPasswordVerifier: DesktopFixedPasswordVerifier?
    private var passwordTask: Task<Void, Never>?
    private var passwordListener: NWListener?
    private var passwordListenerReady = false
    private var passwordIdentity: DesktopDirectIdentity?
    private var passwordHost: NWEndpoint.Host?
    private var passwordPending: [UUID: DesktopDirectTransport] = [:]
    private var fixedPasswordSessionIncoming = false
    private var temporaryLimiter = DesktopDirectRateLimiter()
    private var fixedPasswordLimiter = DesktopDirectRateLimiter()
    private var networkTask: Task<Void, Never>?

    init(center: DesktopCenter, alternateHost: DesktopCenter? = nil, port: NWEndpoint.Port = DesktopDirectEndpoint.port,
         showWindow: Bool = true, loopbackOnly: Bool = false, store: DesktopTrustedStore? = nil, defaults: UserDefaults? = nil,
         trustedPort: NWEndpoint.Port = DesktopTailscaleAddress.port,
         passwordPort: NWEndpoint.Port = DesktopTailscaleAddress.passwordPort,
         findTailscaleAddress: @escaping () async -> NWEndpoint.Host? = { await DesktopTailscaleAddress.current() },
         inspectNetwork: @escaping () async -> DesktopLocalNetworkInfo = { await DesktopTailscaleAddress.inspect() }) {
        self.center = center
        self.port = port
        self.showWindow = showWindow
        self.loopbackOnly = loopbackOnly
        self.store = store
        self.defaults = defaults
        self.trustedPort = trustedPort
        self.passwordPort = passwordPort
        self.findTailscaleAddress = findTailscaleAddress
        self.inspectNetwork = inspectNetwork
        if let defaults {
            if defaults.object(forKey: Self.autoReceiveKey) == nil {
                self.autoReceiveEnabled = true
            } else {
                self.autoReceiveEnabled = defaults.bool(forKey: Self.autoReceiveKey)
            }
        } else {
            self.autoReceiveEnabled = false
        }
        center.alternateHost = alternateHost
        alternateHost?.alternateHost = center
    }

    func startBrowsing() {
        if networkTask == nil {
            networkTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let info = await self.inspectNetwork()
                    guard !Task.isCancelled else { return }
                    self.networkInfo = info
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
        }
        guard browser == nil else { return }
        browseMessage = nil
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.browseMessage = nil
                case .failed, .waiting: self.browseMessage = "附近设备发现不可用，请检查系统的本地网络权限，或直接输入地址连接。"
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
        networkTask?.cancel(); networkTask = nil
    }

    func refreshNetworkInfo() {
        Task { [weak self] in
            guard let self else { return }
            let info = await self.inspectNetwork()
            guard !Task.isCancelled else { return }
            self.networkInfo = info
        }
    }

    func ensureReceivingIfPreferred() {
        guard autoReceiveEnabled, !receiving, !busy, !center.isHost, center.invitation == nil else { return }
        startReceiving()
    }

    func setAutoReceive(_ enabled: Bool) {
        autoReceiveEnabled = enabled
        if enabled { startReceiving() }
        else { stopReceiving() }
    }

    func refreshTemporaryPassword() {
        guard reception != nil else {
            if !busy { startReceiving() }
            return
        }
        let next = DesktopTemporaryPassword.generate()
        reception?.temporaryPassword = next
        temporaryPassword = next
        temporaryLimiter.recordSuccess()
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
            let tempPassword = DesktopTemporaryPassword.generate()
            temporaryLimiter.recordSuccess()
            let expires = defaults == nil ? Date().addingTimeInterval(300) : Date.distantFuture
            reception = .init(listener: listener, identity: identity, code: identity.code,
                              temporaryPassword: tempPassword, expires: expires)
            receiving = true; message = nil; center.message = nil
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.reception?.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.code = identity.code.text
                        self.temporaryPassword = self.reception?.temporaryPassword
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
            if defaults == nil {
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.stopReceiving()
                    self?.message = "连接码已过期，请重新生成。"
                }
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
        receiving = false; code = nil; temporaryPassword = nil
    }

    func connect(address: String, credential: String) {
        switch DesktopDirectCredential.parse(credential) {
        case .directURI(let uriEndpoint, let code):
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = trimmed.isEmpty ? uriEndpoint : (DesktopDirectEndpoint.parse(trimmed) ?? uriEndpoint)
            let display: String? = if case .hostPort(let host, _) = target { "\(host)" } else { nil }
            connectLegacy(endpoint: target, code: code.text, displayAddress: display)
        case .legacyCode(let code):
            guard let endpoint = DesktopDirectEndpoint.parse(address) else {
                message = "请输入被控 Mac 的 Tailscale 地址或局域网 IP。"
                return
            }
            connectLegacy(endpoint: endpoint, code: code.text, displayAddress: address.trimmingCharacters(in: .whitespacesAndNewlines))
        case .temporaryPassword(let password):
            guard let endpoint = DesktopDirectEndpoint.parse(address) else {
                message = "请输入被控 Mac 的 Tailscale 地址或局域网 IP。"
                return
            }
            connectWithPassword(endpoint: endpoint, password: password, unattended: false,
                                displayAddress: address.trimmingCharacters(in: .whitespacesAndNewlines))
        case .fixedPassword(let password):
            let defaultPort = passwordPort == .any ? DesktopTailscaleAddress.passwordPort : passwordPort
            guard let endpoint = DesktopDirectEndpoint.parse(address, defaultPort: defaultPort) else {
                message = "请输入被控 Mac 的 Tailscale IP 或 MagicDNS 名称。"
                return
            }
            connectWithPassword(endpoint: endpoint, password: password, unattended: true,
                                displayAddress: address.trimmingCharacters(in: .whitespacesAndNewlines))
        case .invalid:
            message = "请输入 6 位临时密码、8 位以上固定密码或完整连接码。"
        }
    }

    func connect(endpoint: NWEndpoint, code value: String) {
        let display: String? = if case .hostPort(let host, _) = endpoint { "\(host)" } else { nil }
        connectLegacy(endpoint: endpoint, code: value, displayAddress: display)
    }

    func connect(endpoint: NWEndpoint, credential: String) {
        let display: String? = if case .hostPort(let host, _) = endpoint { "\(host)" } else { nil }
        switch DesktopDirectCredential.parse(credential) {
        case .legacyCode(let code):
            connectLegacy(endpoint: endpoint, code: code.text, displayAddress: display)
        case .temporaryPassword(let temp):
            connectWithPassword(endpoint: endpoint, password: temp, unattended: false, displayAddress: display)
        default:
            message = "请输入被控 Mac 上的 6 位临时密码或完整连接码。"
        }
    }

    private func connectLegacy(endpoint: NWEndpoint, code value: String, displayAddress: String?) {
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
            let address: String? = displayAddress ?? {
                if case .hostPort(let host, _) = endpoint { return "\(host)" }
                return nil
            }()
            guard self.open(socket, id: id, peer: peer, incoming: false, pairingKey: key, address: address) else {
                throw CloudError("本机当前无法建立新连接。")
            }
            self.recordRecentPeer(address: address, name: name)
        }
        socket.start()
    }

    func connectWithPassword(endpoint: NWEndpoint, password: String, unattended: Bool, displayAddress: String? = nil) {
        guard !busy else { return }
        let normalizedPassword: String
        if unattended {
            if let error = DesktopDirectPassword.validateFixed(password) {
                message = error
                return
            }
            normalizedPassword = password
        } else {
            guard let normalized = DesktopTemporaryPassword.normalize(password) else {
                message = "请输入被控 Mac 上的 6 位连接密码。"
                return
            }
            normalizedPassword = normalized
        }
        stopReceiving()
        busy = true; message = nil; center.message = nil

        connectTask = Task { [weak self] in
            guard let self else { return }
            let targetEndpoint: NWEndpoint
            let localTailscaleHost: NWEndpoint.Host?
            if unattended {
                let host = await self.findTailscaleAddress()
                let resolved: NWEndpoint?
                if let host { resolved = await DesktopTailscaleAddress.resolve(endpoint, from: host, loopbackOnly: self.loopbackOnly) }
                else { resolved = nil }
                guard !Task.isCancelled else { return }
                self.connectTask = nil
                guard let host else {
                    self.busy = false; self.message = "未找到可用的本机 Tailscale 地址，请确认 Tailscale 已连接。"; return
                }
                guard let resolved else {
                    self.busy = false; self.message = "地址无法解析为可用的 Tailscale 地址，请使用被控 Mac 显示的 Tailscale 地址。"; return
                }
                targetEndpoint = resolved
                localTailscaleHost = host
            } else {
                self.connectTask = nil
                targetEndpoint = endpoint
                localTailscaleHost = nil
            }

            let parameters = DesktopDirectIdentity.unpinnedParameters()
            if let localTailscaleHost {
                parameters.requiredLocalEndpoint = .hostPort(host: localTailscaleHost, port: .any)
            }
            let socket = DesktopDirectTransport(NWConnection(to: targetEndpoint, using: parameters))
            self.transport = socket
            let id = UUID()
            let mode: DesktopDirectPAKE.AuthMode = unattended ? .unattendedPassword : .temporary
            var certFingerprint: Data?

            socket.onClose = { [weak self, weak socket] reason in self?.closed(socket, id: id, reason: reason) }
            socket.onReady = { [weak self, weak socket] in
                guard let self, let socket, self.transport === socket else { return }
                if unattended, !self.isTrustedRoute(socket.remoteEndpoint) {
                    throw CloudError("固定密码无人值守连接需要通过 Tailscale 地址。")
                }
                guard let fingerprint = socket.peerCertificateFingerprint, fingerprint.count == 32 else {
                    throw CloudError("无法验证对方的加密证书指纹。")
                }
                certFingerprint = fingerprint
                try socket.send(PAKEInit(mode: mode, id: id))
            }
            socket.onFrame = { [weak self, weak socket] data in
                guard let self, let socket, self.transport === socket else { return }
                if let earlyReply = try? JSONDecoder().decode(Reply.self, from: data), earlyReply.id == id,
                   let refusal = earlyReply.refusal {
                    throw CloudError(refusal)
                }
                let challenge = try JSONDecoder().decode(PAKEChallenge.self, from: data)
                guard challenge.version == 2, challenge.id == id,
                      challenge.nonce.count == 16, challenge.salt.count == 16, challenge.hostShare.count == 32,
                      DesktopDirectPassword.kdfBounds(for: mode).contains(challenge.rounds),
                      let fingerprint = certFingerprint else {
                    throw CloudError("对方返回的密钥交换信息无效。")
                }
                let prs: Data
                if unattended {
                    prs = try await Task.detached(priority: .userInitiated) {
                        try DesktopFixedPasswordVerifier.deriveKey(password: normalizedPassword,
                                                                   salt: challenge.salt,
                                                                   rounds: challenge.rounds)
                    }.value
                } else {
                    prs = DesktopTemporaryPassword.derivePRS(normalizedPassword, salt: challenge.salt)
                }
                guard !Task.isCancelled, self.transport === socket else { return }

                let pake = try DesktopDirectPAKE(prs: prs, mode: mode, sessionID: id,
                                                 certFingerprint: fingerprint, nonce: challenge.nonce)
                let (clientConfirm, expectedHostConfirm) = try pake.clientConfirm(hostShare: challenge.hostShare)
                let deviceProof = unattended ? nil : self.makeProof(id: id, fingerprint: fingerprint, role: "viewer")

                socket.onFrame = { [weak self, weak socket] replyData in
                    guard let self, let socket, self.transport === socket else { return }
                    let reply = try JSONDecoder().decode(Reply.self, from: replyData)
                    guard reply.version == 2, reply.id == id, let name = Self.name(reply.name) else {
                        throw CloudError("对方返回的直连确认信息无效。")
                    }
                    if let refusal = reply.refusal { throw CloudError(refusal) }
                    guard let hostConfirm = reply.hostConfirm,
                          DesktopDirectPAKE.constantTimeEqual(hostConfirm, expectedHostConfirm) else {
                        throw CloudError("连接密码校验未通过，无法确认对方身份。")
                    }
                    let peer = DesktopPeer(id: UUID(), name: name)
                    let key = try reply.device?.verifiedKey(id: id, fingerprint: fingerprint, role: "host")
                    let recordedAddress: String? = displayAddress ?? {
                        if case .hostPort(let host, _) = endpoint { return "\(host)" }
                        return nil
                    }()
                    guard self.open(socket, id: id, peer: peer, incoming: false, pairingKey: key,
                                    address: recordedAddress, unattended: unattended) else {
                        throw CloudError("本机当前无法建立新连接。")
                    }
                    self.recordRecentPeer(address: recordedAddress, name: name)
                }
                try socket.send(PAKEAuth(id: id, name: self.deviceName, clientShare: pake.localShare,
                                         clientConfirm: clientConfirm, device: deviceProof))
            }
            socket.start()
        }
    }

    func cancelConnection() {
        connectTask?.cancel(); connectTask = nil
        if let transport { transport.cancel("已取消直连。") }
        else { busy = false }
    }

    func shutdown() {
        stopBrowsing(); stopReceiving(); stopTrustedListener(); trustedTask?.cancel(); trustedTask = nil
        stopPasswordListener(); passwordTask?.cancel(); passwordTask = nil
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
            let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
            if probe.version == 1 {
                let hello = try JSONDecoder().decode(Hello.self, from: data)
                guard let name = Self.name(hello.name), let proof = hello.proof,
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
                return
            }

            guard probe.version == 2 else { throw CloudError("直连验证失败。") }
            let initMsg = try JSONDecoder().decode(PAKEInit.self, from: data)
            guard initMsg.auth == "pake", initMsg.mode == .temporary else { throw CloudError("直连验证失败。") }
            if let remaining = self.temporaryLimiter.remainingLockout() {
                self.pending.removeValue(forKey: slot)
                try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                      refusal: "临时密码错误次数过多，请 \(remaining) 秒后重试。"))
                socket.finish()
                return
            }
            let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            let salt = nonce
            let prs = DesktopTemporaryPassword.derivePRS(reception.temporaryPassword, salt: salt)
            let certFingerprint = reception.identity.certificateFingerprint
            let pake = try DesktopDirectPAKE(prs: prs, mode: .temporary, sessionID: initMsg.id,
                                             certFingerprint: certFingerprint, nonce: nonce)

            socket.onFrame = { [weak self, weak socket] authData in
                guard let self, let socket, self.pending[slot] === socket, let reception = self.reception,
                      Date() < reception.expires, !self.busy else { throw CloudError("连接已过期或本机正忙。") }
                let auth = try JSONDecoder().decode(PAKEAuth.self, from: authData)
                guard auth.version == 2, auth.id == initMsg.id, let name = Self.name(auth.name) else {
                    throw CloudError("直连验证数据无效。")
                }
                if let remaining = self.temporaryLimiter.remainingLockout() {
                    self.pending.removeValue(forKey: slot)
                    try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                          refusal: "临时密码错误次数过多，请 \(remaining) 秒后重试。"))
                    socket.finish()
                    return
                }
                guard let hostConfirm = pake.hostConfirm(clientShare: auth.clientShare, clientConfirm: auth.clientConfirm) else {
                    self.pending.removeValue(forKey: slot)
                    let result = self.temporaryLimiter.recordFailure()
                    let refusal: String
                    if result.lockedOut {
                        let nextPassword = DesktopTemporaryPassword.generate()
                        self.reception?.temporaryPassword = nextPassword
                        self.temporaryPassword = nextPassword
                        refusal = "连接密码错误次数过多，本机临时密码已自动更换，请 60 秒后重试。"
                    } else {
                        refusal = "连接密码错误（剩余 \(result.remainingAttempts) 次机会）。"
                    }
                    try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName, refusal: refusal))
                    socket.finish()
                    return
                }
                self.temporaryLimiter.recordSuccess()
                self.pending.removeValue(forKey: slot)
                let peer = DesktopPeer(id: UUID(), name: name)
                let device = self.makeProof(id: initMsg.id, fingerprint: certFingerprint, role: "host")
                let key = try auth.device?.verifiedKey(id: initMsg.id, fingerprint: certFingerprint, role: "viewer")
                let accepted = self.open(socket, id: initMsg.id, peer: peer, incoming: true,
                                         pairingKey: device == nil ? nil : key, unattended: false)
                try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                      refusal: accepted ? nil : "被控 Mac 当前正忙或屏幕已锁定。",
                                      device: device, hostConfirm: hostConfirm))
                if !accepted { socket.finish() }
                else { self.stopReceiving() }
            }
            try socket.send(PAKEChallenge(id: initMsg.id, nonce: nonce, salt: salt, rounds: 1, hostShare: pake.localShare))
        }
        socket.start()
    }

    private func open(_ socket: DesktopDirectTransport, id: UUID, peer: DesktopPeer, incoming: Bool,
                      pairingKey: Data? = nil, address: String? = nil, unattendedKey: Data? = nil,
                      unattended: Bool = false, isFixedPasswordSession: Bool = false,
                      authorizedGrant: (() -> DesktopTrustedGrant?)? = nil) -> Bool {
        let remember: (() -> Bool)? = incoming ? pairingKey.map { key in
            { [weak self] in self?.remember(key, name: peer.name, incoming: true, address: nil) == true }
        } : nil
        let authorization: (() -> DesktopTrustedGrant?)? = incoming && unattended ? (authorizedGrant ?? unattendedKey.map { key in
            { [weak self] in self?.grant(for: key) }
        }) : nil
        let opened = center.openDirectConnection(id: id, peer: peer, incoming: incoming, showWindow: showWindow,
            trusted: unattended, remember: remember, authorizedGrant: authorization,
            send: { [weak socket] signal in
                do { try socket?.send(signal) }
                catch { Task { @MainActor [weak socket] in socket?.cancel(error.localizedDescription) } }
            }, finish: { [weak self, weak socket] in
                guard let self, self.transport === socket else { return }
                socket?.finish(); self.transport = nil; self.busy = false
                self.trustedSessionKey = nil; self.trustedSessionIncoming = false
                self.fixedPasswordSessionIncoming = false
            })
        guard opened else { return false }
        transport = socket; busy = true
        trustedSessionKey = unattendedKey; trustedSessionIncoming = incoming && unattendedKey != nil
        fixedPasswordSessionIncoming = incoming && isFixedPasswordSession
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
        fixedPasswordSessionIncoming = false
        center.directConnectionClosed(id: id, reason: reason)
    }

    func restoreTrust() {
        if let data = defaults?.data(forKey: Self.recentPeersKey),
           let peers = try? JSONDecoder().decode([DesktopRecentDirectPeer].self, from: data) {
            recentPeers = peers
        }
        if let data = defaults?.data(forKey: Self.unattendedPasswordSettingsKey),
           let settings = try? JSONDecoder().decode(DesktopUnattendedPasswordSettings.self, from: data) {
            unattendedPasswordSettings = settings
        }
        guard let store else { return }
        do {
            if let data = try store.read("devices") {
                trustedDevices = try JSONDecoder().decode([DesktopTrustedDevice].self, from: data)
            }
            if let data = try store.read(Self.unattendedPasswordVerifierAccount), !data.isEmpty {
                unattendedPasswordVerifier = try JSONDecoder().decode(DesktopFixedPasswordVerifier.self, from: data)
                hasUnattendedPassword = true
            } else {
                unattendedPasswordVerifier = nil
                hasUnattendedPassword = false
            }
            unattendedEnabled = defaults?.bool(forKey: "taoscreen.direct.unattended") == true
            refreshTrustedHosting()
            refreshUnattendedPasswordHosting()
        } catch {
            unattendedStatus = error.localizedDescription
            unattendedPasswordStatus = error.localizedDescription
        }
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
                                    unattendedKey: key, unattended: true) else { throw CloudError("本机当前无法建立无人值守连接。") }
                    _ = self.remember(key, name: trusted.name, incoming: false, address: address)
                    self.recordRecentPeer(address: address, name: trusted.name)
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
            let listener = try NWListener(using: parameters)
            trustedListener = listener; trustedListenerReady = false; trustedHost = host
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.trustedListener === listener else { return }
                    switch state {
                    case .ready:
                        self.trustedListenerReady = true
                        self.unattendedStatus = "正在通过 Tailscale 接收已授权设备 · \(host):\(listener.port?.rawValue ?? self.trustedPort.rawValue)"
                        self.updateUnattendedAvailability()
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
        trustedListener = nil; trustedListenerReady = false; trustedHost = nil
        listener?.cancel()
        let waiting = Array(trustedPending.values); trustedPending.removeAll()
        for socket in waiting { socket.cancel() }
        updateUnattendedAvailability()
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
                                     unattendedKey: key, unattended: true)
            if accepted { self.stopReceiving() }
            try socket.send(Reply(id: hello.id, name: self.deviceName,
                                 refusal: accepted ? nil : "被控 Mac 当前正忙、权限不足或无活动用户会话。"))
            if !accepted { socket.finish() }
        }
        socket.start()
    }

    @discardableResult
    func saveUnattendedPassword(_ password: String) async -> Bool {
        if let validationError = DesktopDirectPassword.validateFixed(password) {
            message = validationError
            return false
        }
        guard let store else {
            message = "本机钥匙串不可用，无法保存固定访问密码。"
            return false
        }
        do {
            let verifier = try await Task.detached(priority: .userInitiated) {
                try DesktopFixedPasswordVerifier.create(password: password)
            }.value
            let encoded = try JSONEncoder().encode(verifier)
            try store.write(Self.unattendedPasswordVerifierAccount, encoded)
            unattendedPasswordVerifier = verifier
            hasUnattendedPassword = true
            fixedPasswordLimiter.recordSuccess()
            if fixedPasswordSessionIncoming {
                center.disconnect("固定访问密码已更改，共享已停止。")
            }
            if !unattendedPasswordSettings.enabled {
                var next = unattendedPasswordSettings
                next.enabled = true
                updateUnattendedPasswordSettings(next)
            } else {
                refreshUnattendedPasswordHosting()
            }
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func clearUnattendedPassword() {
        do {
            try store?.write(Self.unattendedPasswordVerifierAccount, Data())
        } catch {
            message = error.localizedDescription
            return
        }
        unattendedPasswordVerifier = nil
        hasUnattendedPassword = false
        fixedPasswordLimiter.recordSuccess()
        if fixedPasswordSessionIncoming {
            center.disconnect("固定访问密码已清除，共享已停止。")
        }
        var next = unattendedPasswordSettings
        next.enabled = false
        updateUnattendedPasswordSettings(next)
    }

    func updateUnattendedPasswordSettings(_ settings: DesktopUnattendedPasswordSettings) {
        let previous = unattendedPasswordSettings
        unattendedPasswordSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            defaults?.set(data, forKey: Self.unattendedPasswordSettingsKey)
        }
        if fixedPasswordSessionIncoming && (!settings.enabled || settings.grant != previous.grant) {
            center.disconnect("Tailscale 固定密码无人值守设置已更改，共享已停止。")
        }
        refreshUnattendedPasswordHosting()
    }

    func setUnattendedPasswordEnabled(_ enabled: Bool) {
        var next = unattendedPasswordSettings
        next.enabled = enabled
        updateUnattendedPasswordSettings(next)
    }

    private func currentUnattendedPasswordGrant() -> DesktopTrustedGrant? {
        guard unattendedPasswordSettings.enabled, passwordListener != nil, unattendedPasswordVerifier != nil else { return nil }
        return unattendedPasswordSettings.grant
    }

    private func refreshUnattendedPasswordHosting() {
        passwordTask?.cancel(); passwordTask = nil
        stopPasswordListener()
        guard unattendedPasswordSettings.enabled else {
            unattendedPasswordStatus = "固定密码无人值守已关闭"
            return
        }
        guard unattendedPasswordVerifier != nil else {
            unattendedPasswordStatus = "请先设置固定访问密码"
            return
        }
        unattendedPasswordStatus = "正在检查 Tailscale 连接…"
        passwordTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let host = await self.findTailscaleAddress()
                guard !Task.isCancelled else { return }
                if self.passwordHost != host || self.passwordListener == nil {
                    if self.fixedPasswordSessionIncoming, self.passwordHost != nil, self.passwordHost != host {
                        self.center.disconnect("Tailscale 接收地址已改变，共享已停止。")
                    }
                    self.stopPasswordListener()
                    if let host { self.listenForPasswordUnattended(on: host) }
                    else { self.unattendedPasswordStatus = "未检测到 Tailscale 地址，请确认 Tailscale 已连接。" }
                }
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
    }

    private func listenForPasswordUnattended(on host: NWEndpoint.Host) {
        do {
            let identity = try DesktopDirectIdentity()
            let parameters = DesktopDirectIdentity.parameters(identity: identity.identity)
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: passwordPort)
            let listener = try NWListener(using: parameters)
            passwordListener = listener; passwordListenerReady = false; passwordIdentity = identity; passwordHost = host
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.passwordListener === listener else { return }
                    switch state {
                    case .ready:
                        self.passwordListenerReady = true
                        self.unattendedPasswordStatus = "正在通过 Tailscale 接收固定密码连接 · \(host):\(listener.port?.rawValue ?? self.passwordPort.rawValue)"
                        self.updateUnattendedAvailability()
                    case .failed(let error), .waiting(let error):
                        if self.fixedPasswordSessionIncoming { self.center.disconnect("Tailscale 固定密码接收已中断。") }
                        self.stopPasswordListener()
                        self.unattendedPasswordStatus = "无法开启 Tailscale 固定密码接收：\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.passwordListener === listener else { connection.cancel(); return }
                    self.receivePasswordUnattended(connection)
                }
            }
            listener.start(queue: .main)
        } catch { unattendedPasswordStatus = error.localizedDescription }
    }

    private func stopPasswordListener() {
        let listener = passwordListener
        passwordListener = nil; passwordListenerReady = false; passwordIdentity = nil; passwordHost = nil
        listener?.cancel()
        let waiting = Array(passwordPending.values); passwordPending.removeAll()
        for socket in waiting { socket.cancel() }
        updateUnattendedAvailability()
    }

    private func updateUnattendedAvailability() {
        RemoteAvailability.shared.setActive(.directUnattended, trustedListener != nil || passwordListener != nil)
    }

    private func receivePasswordUnattended(_ connection: NWConnection) {
        guard !busy, passwordPending.count < 8, isTrustedRoute(connection.endpoint) else { connection.cancel(); return }
        let socket = DesktopDirectTransport(connection)
        let slot = UUID()
        passwordPending[slot] = socket
        socket.onClose = { [weak self] _ in self?.passwordPending.removeValue(forKey: slot) }
        socket.onFrame = { [weak self, weak socket] data in
            guard let self, let socket, self.passwordPending[slot] === socket, !self.busy,
                  self.unattendedPasswordSettings.enabled,
                  let verifier = self.unattendedPasswordVerifier,
                  let identity = self.passwordIdentity else {
                throw CloudError("本机尚未启用 Tailscale 固定密码无人值守。")
            }
            let initMsg = try JSONDecoder().decode(PAKEInit.self, from: data)
            guard initMsg.version == 2, initMsg.auth == "pake", initMsg.mode == .unattendedPassword else {
                throw CloudError("无效的固定密码无人值守请求。")
            }
            if let remaining = self.fixedPasswordLimiter.remainingLockout() {
                self.passwordPending.removeValue(forKey: slot)
                try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                      refusal: "固定密码错误次数过多，请 \(remaining) 秒后重试。"))
                socket.finish()
                return
            }
            let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            let pake = try DesktopDirectPAKE(prs: verifier.derivedKey, mode: .unattendedPassword,
                                             sessionID: initMsg.id,
                                             certFingerprint: identity.certificateFingerprint,
                                             nonce: nonce)

            socket.onFrame = { [weak self, weak socket] authData in
                guard let self, let socket, self.passwordPending[slot] === socket, !self.busy,
                      self.unattendedPasswordSettings.enabled, self.unattendedPasswordVerifier != nil else {
                    throw CloudError("固定密码无人值守状态已变更。")
                }
                let auth = try JSONDecoder().decode(PAKEAuth.self, from: authData)
                guard auth.version == 2, auth.id == initMsg.id, let name = Self.name(auth.name) else {
                    throw CloudError("无效的无人值守验证信息。")
                }
                if let remaining = self.fixedPasswordLimiter.remainingLockout() {
                    self.passwordPending.removeValue(forKey: slot)
                    try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                          refusal: "固定密码错误次数过多，请 \(remaining) 秒后重试。"))
                    socket.finish()
                    return
                }
                guard let hostConfirm = pake.hostConfirm(clientShare: auth.clientShare, clientConfirm: auth.clientConfirm) else {
                    self.passwordPending.removeValue(forKey: slot)
                    let result = self.fixedPasswordLimiter.recordFailure()
                    let refusal = result.lockedOut
                        ? "固定访问密码错误次数过多，已锁定 60 秒后重试。"
                        : "固定访问密码错误（剩余 \(result.remainingAttempts) 次机会）。"
                    try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName, refusal: refusal))
                    socket.finish()
                    return
                }
                self.fixedPasswordLimiter.recordSuccess()
                self.passwordPending.removeValue(forKey: slot)
                let accepted = self.open(socket, id: initMsg.id, peer: .init(id: UUID(), name: name), incoming: true,
                                         unattended: true, isFixedPasswordSession: true,
                                         authorizedGrant: { [weak self] in self?.currentUnattendedPasswordGrant() })
                if accepted { self.stopReceiving() }
                try socket.send(Reply(version: 2, id: initMsg.id, name: self.deviceName,
                                      refusal: accepted ? nil : "被控 Mac 当前正忙、权限不足或无活动用户会话。",
                                      hostConfirm: hostConfirm))
                if !accepted { socket.finish() }
            }
            try socket.send(PAKEChallenge(id: initMsg.id, nonce: nonce, salt: verifier.salt,
                                          rounds: verifier.rounds, hostShare: pake.localShare))
        }
        socket.start()
    }

    private func recordRecentPeer(address: String?, name: String) {
        guard let raw = address?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        var updated = recentPeers.filter { $0.address != raw }
        updated.insert(DesktopRecentDirectPeer(address: raw, name: name, lastConnectedAt: .now), at: 0)
        if updated.count > 8 { updated = Array(updated.prefix(8)) }
        recentPeers = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults?.set(data, forKey: Self.recentPeersKey)
        }
    }

    func removeRecentPeer(address: String) {
        recentPeers.removeAll { $0.address == address }
        if let data = try? JSONEncoder().encode(recentPeers) {
            defaults?.set(data, forKey: Self.recentPeersKey)
        }
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
