import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

struct DesktopDirectDeviceProof: Codable {
    let publicKey: Data
    let signature: Data

    init(key: P256.Signing.PrivateKey, id: UUID, fingerprint: Data, role: String) throws {
        publicKey = key.publicKey.x963Representation
        signature = try key.signature(for: Self.transcript(id, fingerprint, role)).derRepresentation
    }

    func verifiedKey(id: UUID, fingerprint: Data, role: String) throws -> Data {
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(signature, for: Self.transcript(id, fingerprint, role)) else {
            throw CloudError(L10n.text("直连设备身份验证失败。"))
        }
        return key.x963Representation
    }

    private static func transcript(_ id: UUID, _ fingerprint: Data, _ role: String) -> Data {
        Data("taoscreen-direct-device-v1:\(role):\(id.uuidString):".utf8) + fingerprint
    }
}

struct DesktopTrustedGrant: Codable, Equatable {
    var control = false
    var audio = false
    var virtualDisplayPreset: DesktopVirtualDisplayPreset? = nil

    var shareDisplay: DesktopShareDisplay {
        virtualDisplayPreset.map(DesktopShareDisplay.virtual) ?? .main
    }
}

struct DesktopTrustedDevice: Identifiable, Codable, Equatable {
    var id: Data { publicKey }
    let publicKey: Data
    var name: String
    var canRequest = false
    var grant: DesktopTrustedGrant?
    var canConnect = false
    var address: String?
}

struct DesktopUnattendedPasswordSettings: Codable, Equatable {
    var enabled = false
    var grant = DesktopTrustedGrant(control: true, audio: false)
}

struct DesktopTailscalePeer: Identifiable, Equatable {
    let id: String
    let name: String
    let dnsName: String?
    let ip: String
    let os: String?

    var preferredAddress: String {
        if let dnsName, !dnsName.isEmpty { return dnsName }
        return ip
    }
}

struct DesktopLocalNetworkInfo: Equatable {
    var tailscaleIP: String?
    var tailscaleDNSName: String?
    var lanAddresses: [String] = []
    var tailscalePeers: [DesktopTailscalePeer] = []

    var primaryAddress: String? { tailscaleIP ?? lanAddresses.first }
}

struct DesktopRecentDirectPeer: Identifiable, Codable, Equatable {
    var id: String { address }
    let address: String
    var name: String
    var lastConnectedAt: Date
}

/// 在当前 macOS 用户的钥匙串中保存设备私钥和授权列表。
struct DesktopTrustedStore {
    var read: (String) throws -> Data?
    var write: (String, Data) throws -> Void

    static let keychain = Self(read: { account in
        var query = query(account)
        query[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return data
    }, write: { account, data in
        let query = query(account)
        if data.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let value = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    })

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: DesktopRuntime.keychainService("direct-trust.v1"),
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private static func failure(_ status: OSStatus) -> CloudError {
        CloudError(L10n.text("无法读取或更新本机直连授权钥匙串（\(status)）。请在本机登录状态下检查钥匙串后重试。"))
    }
}

enum DesktopTailscaleAddress {
    static let port = NWEndpoint.Port(integerLiteral: 45872)
    static let passwordPort = NWEndpoint.Port(integerLiteral: 45873)

    private struct StatusPayload: Decodable {
        struct Node: Decodable {
            let id: String?
            let hostName: String?
            let dnsName: String?
            let os: String?
            let tailscaleIPs: [String]?
            let online: Bool?

            enum CodingKeys: String, CodingKey {
                case id = "ID"
                case hostName = "HostName"
                case dnsName = "DNSName"
                case os = "OS"
                case tailscaleIPs = "TailscaleIPs"
                case online = "Online"
            }
        }
        let selfNode: Node?
        let peer: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case selfNode = "Self"
            case peer = "Peer"
        }
    }

    static func isTailnet(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            let bytes = Array(address.rawValue)
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        case .ipv6(let address):
            return address.rawValue.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        default: return false
        }
    }

    static func isTailnet(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return isTailnet(host)
    }

    static func current() async -> NWEndpoint.Host? {
        await Task.detached(priority: .utility) {
            let tunnels = localTunnelInterfaceAddresses()
            let allTunnelHosts = Set(tunnels.values.flatMap { $0 })
            if let response = runTailscaleCLI(arguments: ["ip"]),
               let matched = response.split(whereSeparator: \.isWhitespace).map({ NWEndpoint.Host(String($0)) })
                .first(where: { isTailnet($0) && allTunnelHosts.contains($0) }) {
                return matched
            }
            // Mac App Store 版 Tailscale 可能无命令行工具；回落到同时具备 Tailnet IPv6 与 CGNAT IPv4 的 utun 接口。
            for (_, hosts) in tunnels.sorted(by: { $0.key < $1.key }) {
                let tailV4 = hosts.first { if case .ipv4 = $0 { return isTailnet($0) }; return false }
                let tailV6 = hosts.first { if case .ipv6 = $0 { return isTailnet($0) }; return false }
                if let tailV4, tailV6 != nil { return tailV4 }
            }
            for (_, hosts) in tunnels.sorted(by: { $0.key < $1.key }) {
                if let tailV6 = hosts.first(where: { if case .ipv6 = $0 { return isTailnet($0) }; return false }) {
                    return tailV6
                }
            }
            return nil
        }.value
    }

    static func inspect() async -> DesktopLocalNetworkInfo {
        await Task.detached(priority: .utility) {
            let tunnels = localTunnelInterfaceAddresses()
            let allTunnelHosts = Set(tunnels.values.flatMap { $0 })
            let lanAddresses = localLANIPv4Addresses()

            var tailscaleIP: String?
            var tailscaleDNSName: String?
            var tailscalePeers: [DesktopTailscalePeer] = []

            if let json = runTailscaleCLI(arguments: ["status", "--json"]),
               let data = json.data(using: .utf8),
               let status = try? JSONDecoder().decode(StatusPayload.self, from: data) {
                if let selfNode = status.selfNode {
                    tailscaleDNSName = cleanDNSName(selfNode.dnsName)
                    if let ips = selfNode.tailscaleIPs {
                        tailscaleIP = ips.first {
                            let host = NWEndpoint.Host($0)
                            return isTailnet(host) && allTunnelHosts.contains(host)
                        }
                    }
                }
                if let peers = status.peer {
                    tailscalePeers = peers.compactMap { key, node in
                        guard node.online == true else { return nil }
                        if let os = node.os?.lowercased(), !os.isEmpty, os != "macos" { return nil }
                        guard let ips = node.tailscaleIPs,
                              let ip = ips.first(where: { if case .ipv4 = NWEndpoint.Host($0) { return isTailnet(NWEndpoint.Host($0)) }; return false })
                                ?? ips.first(where: { isTailnet(NWEndpoint.Host($0)) }) else { return nil }
                        let dns = cleanDNSName(node.dnsName)
                        let rawName = node.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayName = (rawName?.isEmpty == false ? rawName : nil)
                            ?? dns?.split(separator: ".").first.map(String.init)
                            ?? ip
                        return DesktopTailscalePeer(id: node.id ?? key, name: displayName, dnsName: dns, ip: ip, os: node.os)
                    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }

            if tailscaleIP == nil {
                for (_, hosts) in tunnels.sorted(by: { $0.key < $1.key }) {
                    let tailV4 = hosts.first { if case .ipv4 = $0 { return isTailnet($0) }; return false }
                    let tailV6 = hosts.first { if case .ipv6 = $0 { return isTailnet($0) }; return false }
                    if let tailV4, tailV6 != nil {
                        tailscaleIP = "\(tailV4)"
                        break
                    }
                }
                if tailscaleIP == nil {
                    for (_, hosts) in tunnels.sorted(by: { $0.key < $1.key }) {
                        if let tailV6 = hosts.first(where: { if case .ipv6 = $0 { return isTailnet($0) }; return false }) {
                            tailscaleIP = "\(tailV6)"
                            break
                        }
                    }
                }
            }

            return DesktopLocalNetworkInfo(tailscaleIP: tailscaleIP, tailscaleDNSName: tailscaleDNSName,
                                           lanAddresses: lanAddresses, tailscalePeers: tailscalePeers)
        }.value
    }

    private static func cleanDNSName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runTailscaleCLI(arguments: [String]) -> String? {
        let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, new in new }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func resolve(_ endpoint: NWEndpoint, from local: NWEndpoint.Host, loopbackOnly: Bool) async -> NWEndpoint? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        if loopbackOnly { return DesktopDirectEndpoint.allowsIncoming(endpoint) ? endpoint : nil }
        let family: Int32
        if case .ipv4 = local { family = AF_INET } else { family = AF_INET6 }
        switch host {
        case .ipv4: return family == AF_INET && isTailnet(host) ? endpoint : nil
        case .ipv6: return family == AF_INET6 && isTailnet(host) ? endpoint : nil
        case .name(let name, _):
            return await Task.detached(priority: .utility) {
                var hints = addrinfo()
                hints.ai_family = family
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(name, nil, &hints, &result) == 0, let result else { return nil }
                defer { freeaddrinfo(result) }
                var current: UnsafeMutablePointer<addrinfo>? = result
                while let item = current?.pointee {
                    current = item.ai_next
                    if let address = item.ai_addr, let resolved = numericHost(address), isTailnet(resolved) {
                        return .hostPort(host: resolved, port: port)
                    }
                }
                return nil
            }.value
        @unknown default: return nil
        }
    }

    /// 用系统接口地址交叉确认 CLI 报告的地址实际属于本机隧道。
    private static func localTunnelInterfaceAddresses() -> [String: [NWEndpoint.Host]] {
        var start: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&start) == 0, let start else { return [:] }
        defer { freeifaddrs(start) }
        var addresses: [String: [NWEndpoint.Host]] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = start
        while let item = current?.pointee {
            current = item.ifa_next
            let name = String(cString: item.ifa_name)
            guard (Int32(item.ifa_flags) & IFF_UP) != 0, name.hasPrefix("utun"), let address = item.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            if let host = numericHost(address) {
                addresses[name, default: []].append(host)
            }
        }
        return addresses
    }

    private static func localLANIPv4Addresses() -> [String] {
        var start: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&start) == 0, let start else { return [] }
        defer { freeifaddrs(start) }
        var result: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = start
        while let item = current?.pointee {
            current = item.ifa_next
            let name = String(cString: item.ifa_name)
            let flags = Int32(item.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, name.hasPrefix("en"),
                  let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  let host = numericHost(address), case .ipv4(let ipv4) = host else { continue }
            let bytes = Array(ipv4.rawValue)
            let isLAN = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
            if isLAN { result.append((name, "\(ipv4)")) }
        }
        var seen = Set<String>()
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map(\.1)
            .filter { seen.insert($0).inserted }
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> NWEndpoint.Host? {
        var result = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &result, socklen_t(result.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return NWEndpoint.Host(String(decoding: result.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
    }
}
