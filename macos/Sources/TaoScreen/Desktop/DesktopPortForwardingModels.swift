import Foundation
import Network

enum DesktopPortLimits {
    static let rules = 8
    static let connections = 32
    static let chunk = 16 * 1024
    static let streamWindow = 64 * 1024
    static let totalWindow = 256 * 1024
    static let datagram = 65_507
    static let packet = 24 * 1024
    static let queue = 512 * 1024
}

enum DesktopPortProtocol: String, Codable, CaseIterable {
    case tcp = "TCP", udp = "UDP"
}

enum DesktopPortDirection: String, Codable, CaseIterable {
    case localToRemote, remoteToLocal
    var title: String { self == .localToRemote ? "本机监听 → 远端目标" : "远端监听 → 本机目标" }
    var listenerIsHost: Bool { self == .remoteToLocal }
}

struct DesktopPortRule: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var transport: DesktopPortProtocol
    var direction: DesktopPortDirection
    var listenAddress: String
    var listenPort: Int
    var destinationHost: String
    var destinationPort: Int
    /// 本机保存的启用意图；远端仍须收到已授权会话的 startRule 才能创建监听。
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String = "", transport: DesktopPortProtocol = .tcp,
         direction: DesktopPortDirection = .localToRemote, listenAddress: String = "127.0.0.1",
         listenPort: Int, destinationHost: String, destinationPort: Int, isEnabled: Bool = false) throws {
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport; self.direction = direction; self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.destinationPort = destinationPort
        self.isEnabled = isEnabled
        guard Self.validPort(listenPort), Self.validPort(destinationPort) else { throw CloudError("端口必须是 1–65535 之间的整数。") }
        guard Self.validHost(self.destinationHost) else { throw CloudError("目标地址需填写 IP 或主机名，不能包含网址、路径或端口。") }
        guard isValid else { throw CloudError("监听地址或规则名称无效；名称最多 60 个字符。") }
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, transport, direction, listenAddress, listenPort, destinationHost, destinationPort, isEnabled
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      transport: values.decode(DesktopPortProtocol.self, forKey: .transport),
                      direction: values.decode(DesktopPortDirection.self, forKey: .direction),
                      listenAddress: values.decode(String.self, forKey: .listenAddress),
                      listenPort: values.decode(Int.self, forKey: .listenPort),
                      destinationHost: values.decode(String.self, forKey: .destinationHost),
                      destinationPort: values.decode(Int.self, forKey: .destinationPort),
                      isEnabled: values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false)
    }
    var isValid: Bool {
        Self.validPort(listenPort) && Self.validPort(destinationPort) && Self.validHost(destinationHost)
            && ["127.0.0.1", "0.0.0.0"].contains(listenAddress)
            && name.count <= 60 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    var title: String { name.isEmpty ? "\(transport.rawValue) \(listenPort) → \(destinationPort)" : name }
    var listener: String { "\(listenAddress):\(listenPort)" }
    var destination: String { "\(destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost):\(destinationPort)" }
    func conflicts(with other: Self) -> Bool {
        direction == other.direction && transport == other.transport && listenPort == other.listenPort
            && (listenAddress == other.listenAddress || listenAddress == "0.0.0.0" || other.listenAddress == "0.0.0.0")
    }
    static func validPort(_ value: Int) -> Bool { (1...65535).contains(value) }
    static func validHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        if IPv4Address(value) != nil || IPv6Address(value) != nil { return true }
        let host = value.hasSuffix(".") ? String(value.dropLast()) : value
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

/// 规则及启用意图只保存在控制端，按服务地址、账号和稳定设备 ID 隔离。
struct DesktopPortRuleStore {
    let defaults: UserDefaults
    let accountID: String
    let peerID: UUID
    private var key: String { "taoscreen.desktop.port-forward.\(accountID).\(peerID.uuidString)" }
    func load() throws -> [DesktopPortRule] {
        guard let saved = defaults.object(forKey: key) else { return [] }
        guard let data = saved as? Data else { throw CloudError("已保存的端口规则格式无效，未覆盖原记录。") }
        do {
            let rules = try JSONDecoder().decode([DesktopPortRule].self, from: data)
            try validate(rules)
            return rules
        } catch { throw CloudError("已保存的端口规则无法读取，未覆盖原记录：\(error.localizedDescription)") }
    }
    func save(_ rules: [DesktopPortRule]) throws {
        try validate(rules)
        defaults.set(try JSONEncoder().encode(rules), forKey: key)
    }
    private func validate(_ rules: [DesktopPortRule]) throws {
        guard rules.count <= DesktopPortLimits.rules, rules.allSatisfy(\.isValid),
              Set(rules.map(\.id)).count == rules.count,
              !rules.indices.contains(where: { i in rules.indices.contains { j in i < j && rules[i].conflicts(with: rules[j]) } }) else {
            throw CloudError("端口规则数量、地址或端口记录无效。")
        }
    }
}

/// TCP 字节流和 UDP 完整报文复用独立可靠通道；每次启动具有独立运行 ID。
struct DesktopPortPacket: Codable, Equatable {
    enum Kind: String, Codable { case status, startRule, ruleStarted, stopRule, ruleStopped, open, opened, data, datagram, ack, eof, close }
    var version = 1
    var kind: Kind
    var id: UUID? = nil
    var runID: UUID? = nil
    var rule: DesktopPortRule? = nil
    var allowed: Bool? = nil
    var payload: Data? = nil
    var bytes: Int? = nil
    var message: String? = nil
    var datagramID: UUID? = nil
    var part: Int? = nil
    var parts: Int? = nil
    var length: Int? = nil

    var isValid: Bool {
        guard version == 1,
              (kind == .status ? id == nil && allowed != nil : id != nil && allowed == nil),
              (kind == .open ? runID != nil : runID == nil),
              (kind == .startRule ? rule?.isValid == true : rule == nil),
              [.data, .datagram].contains(kind) || payload == nil,
              kind == .ack || bytes == nil,
              [.close, .ruleStopped].contains(kind) || message == nil,
              message.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else { return false }
        if kind != .datagram, datagramID != nil || part != nil || parts != nil || length != nil { return false }
        switch kind {
        case .status, .startRule, .ruleStarted, .stopRule, .ruleStopped, .open, .opened, .eof, .close: return true
        case .data: return payload.map { !$0.isEmpty && $0.count <= DesktopPortLimits.chunk } == true
        case .ack: return bytes.map { (1...DesktopPortLimits.streamWindow).contains($0) } == true
        case .datagram:
            guard datagramID != nil, let part, let parts, let length, let payload,
                  (0...DesktopPortLimits.datagram).contains(length),
                  parts == max(1, (length + DesktopPortLimits.chunk - 1) / DesktopPortLimits.chunk),
                  (0..<parts).contains(part) else { return false }
            return payload.count == min(DesktopPortLimits.chunk, max(0, length - part * DesktopPortLimits.chunk))
        }
    }
    func encoded() throws -> Data {
        guard isValid else { throw CloudError("端口转发消息无效。") }
        let data = try JSONEncoder().encode(self)
        guard data.count <= DesktopPortLimits.packet else { throw CloudError("端口转发消息过大。") }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= DesktopPortLimits.packet else { throw CloudError("端口转发消息过大。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isValid else { throw CloudError("端口转发消息无效。") }
        return value
    }
    static func datagrams(id: UUID, data: Data) -> [Self] {
        let messageID = UUID(), count = max(1, (data.count + DesktopPortLimits.chunk - 1) / DesktopPortLimits.chunk)
        return (0..<count).map { index in
            let start = index * DesktopPortLimits.chunk, end = min(data.count, start + DesktopPortLimits.chunk)
            return Self(kind: .datagram, id: id, payload: data.subdata(in: start..<end), datagramID: messageID,
                        part: index, parts: count, length: data.count)
        }
    }
}

struct DesktopPortDatagramAssembly {
    private(set) var id: UUID?
    private var nextPart = 0
    private var length = 0
    private var parts = 0
    private var data = Data()
    private(set) var deadline: TimeInterval?
    mutating func append(_ packet: DesktopPortPacket, now: TimeInterval) throws -> Data? {
        guard packet.kind == .datagram, packet.isValid else { throw CloudError("UDP 数据报片段无效。") }
        if id == nil {
            guard packet.part == 0 else { throw CloudError("UDP 数据报缺少起始片段。") }
            id = packet.datagramID; length = packet.length!; parts = packet.parts!; deadline = now + 10
        }
        guard now <= deadline!, packet.datagramID == id, packet.part == nextPart,
              packet.length == length, packet.parts == parts else { throw CloudError("UDP 数据报片段不连续或已超时。") }
        data.append(packet.payload!); nextPart += 1
        guard nextPart == parts else { return nil }
        let result = data
        self = Self()
        return result
    }
}

struct DesktopPortRuleState: Identifiable {
    enum Phase { case stopped, starting, listening, stopping, failed }
    var rule: DesktopPortRule
    var phase = Phase.stopped
    var connections = 0
    var sent: Int64 = 0
    var received: Int64 = 0
    var error: String?
    var id: UUID { rule.id }
    var running: Bool { phase == .starting || phase == .listening || phase == .stopping }
}
