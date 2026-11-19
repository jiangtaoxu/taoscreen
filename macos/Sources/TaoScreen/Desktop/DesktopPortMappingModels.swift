import Foundation

/// 表单草稿不落盘；创建副本必须补充新的监听端口，避免替用户抢占端口。
struct DesktopPortRuleDraft: Identifiable {
    enum Field: CaseIterable { case name, listenPort, destinationHost, destinationPort }
    let id: UUID
    let editing: Bool
    var name: String
    var listenPort: String
    var destinationHost: String
    var destinationPort: String
    var transport: DesktopPortProtocol
    var direction: DesktopPortDirection
    var listenAddress: String
    var isEnabled: Bool

    init(rule: DesktopPortRule? = nil, duplicate: Bool = false) {
        id = duplicate ? UUID() : rule?.id ?? UUID()
        editing = rule != nil && !duplicate
        name = rule.map { duplicate ? String(($0.title + " 副本").prefix(60)) : $0.name } ?? ""
        listenPort = duplicate ? "" : rule.map { String($0.listenPort) } ?? ""
        destinationHost = rule?.destinationHost ?? "127.0.0.1"
        destinationPort = rule.map { String($0.destinationPort) } ?? ""
        transport = rule?.transport ?? .tcp
        direction = rule?.direction ?? .localToRemote
        listenAddress = rule?.listenAddress ?? "127.0.0.1"
        isEnabled = duplicate ? true : rule?.isEnabled ?? true
    }
    var errors: [Field: String] {
        var result: [Field: String] = [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 60 || trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            result[.name] = "名称最多 60 个字符，不能包含控制字符"
        }
        for (field, text) in [(Field.listenPort, listenPort), (.destinationPort, destinationPort)] {
            if Self.port(text) == nil { result[field] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "必填" : "端口范围 1–65535" }
        }
        if !DesktopPortRule.validHost(destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result[.destinationHost] = "请输入 IP 或主机名，不包含网址、路径或端口"
        }
        return result
    }
    func makeRule() throws -> DesktopPortRule {
        guard errors.isEmpty, let local = Self.port(listenPort), let remote = Self.port(destinationPort) else {
            throw CloudError("请检查标红字段。")
        }
        return try DesktopPortRule(id: id, name: name, transport: transport, direction: direction,
            listenAddress: listenAddress, listenPort: local, destinationHost: destinationHost,
            destinationPort: remote, isEnabled: isEnabled)
    }
    private static func port(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(value), DesktopPortRule.validPort(port) else { return nil }
        return port
    }
}

/// 只记录用户已见过的同账号设备 ID 和名称，离线时仍能管理该设备的映射。
struct DesktopPortDeviceStore {
    let defaults: UserDefaults
    let accountID: String
    private var key: String { "taoscreen.ports.devices.\(accountID)" }
    func load() throws -> [DesktopPeer] {
        guard let saved = defaults.object(forKey: key) else { return [] }
        guard let data = saved as? Data else { throw CloudError("映射设备记录格式无效，未覆盖原记录。") }
        let peers = try JSONDecoder().decode([DesktopPeer].self, from: data)
        try validate(peers)
        return peers
    }
    func save(_ peers: [DesktopPeer]) throws {
        try validate(peers)
        defaults.set(try JSONEncoder().encode(peers), forKey: key)
    }
    private func validate(_ peers: [DesktopPeer]) throws {
        guard peers.count <= 512, Set(peers.map(\.id)).count == peers.count,
              peers.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw CloudError("映射设备记录无效，未覆盖原记录。")
        }
    }
}
