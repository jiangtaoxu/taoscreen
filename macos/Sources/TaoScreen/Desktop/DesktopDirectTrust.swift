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
            throw CloudError("直连设备身份验证失败。")
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
        CloudError("无法读取或更新本机直连授权钥匙串（\(status)）。请在本机登录状态下检查钥匙串后重试。")
    }
}

enum DesktopTailscaleAddress {
    static let port = NWEndpoint.Port(integerLiteral: 45872)

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
            let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["ip"]
            process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1"]) { _, new in new }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let response = String(data: data, encoding: .utf8) else { return nil }
            let addresses = localTunnelAddresses()
            return response.split(whereSeparator: \.isWhitespace).map { NWEndpoint.Host(String($0)) }
                .first { isTailnet($0) && addresses.contains($0) }
        }.value
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
    private static func localTunnelAddresses() -> Set<NWEndpoint.Host> {
        var start: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&start) == 0, let start else { return [] }
        defer { freeifaddrs(start) }
        var addresses = Set<NWEndpoint.Host>()
        var current: UnsafeMutablePointer<ifaddrs>? = start
        while let item = current?.pointee {
            current = item.ifa_next
            guard String(cString: item.ifa_name).hasPrefix("utun"), let address = item.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            if let host = numericHost(address) { addresses.insert(host) }
        }
        return addresses
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> NWEndpoint.Host? {
        var result = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &result, socklen_t(result.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return NWEndpoint.Host(String(decoding: result.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
    }
}
