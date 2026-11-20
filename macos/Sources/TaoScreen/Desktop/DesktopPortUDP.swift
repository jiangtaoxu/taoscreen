import Darwin
import Foundation
import Network

/// 使用独立 UDP 描述符管理对端映射，空闲回收后相同源端口可以建立新会话。
/// 发送缓冲区按每个 socket 配置，不修改系统 UDP 参数。
private final class DesktopPortUDPDescriptor {
    private(set) var value: Int32
    init(family: Int32) throws {
        value = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard value >= 0 else { throw CloudError(Self.failure()) }
        var size: Int32 = 256 * 1024
        guard fcntl(value, F_SETFL, O_NONBLOCK) == 0,
              fcntl(value, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(value, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0,
              setsockopt(value, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0 else {
            let message = Self.failure(); close(); throw CloudError(message)
        }
    }
    static func failure() -> String { String(cString: strerror(errno)) }
    func close() { if value >= 0 { Darwin.close(value); value = -1 } }
    deinit { close() }
}

struct DesktopPortUDPAddress {
    let bytes: Data
    let family: Int32
    init(endpoint: NWEndpoint) throws {
        guard case .hostPort(let host, let port) = endpoint else { throw CloudError(L10n.text("无法确定 UDP 目标地址。")) }
        switch host {
        case .ipv4(let ip):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.rawValue.bigEndian
            _ = withUnsafeMutableBytes(of: &address.sin_addr) { ip.rawValue.copyBytes(to: $0) }
            bytes = withUnsafeBytes(of: &address) { Data($0) }; family = AF_INET
        case .ipv6(let ip):
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.rawValue.bigEndian; address.sin6_scope_id = UInt32(ip.interface?.index ?? 0)
            _ = withUnsafeMutableBytes(of: &address.sin6_addr) { ip.rawValue.copyBytes(to: $0) }
            bytes = withUnsafeBytes(of: &address) { Data($0) }; family = AF_INET6
        default: throw CloudError(L10n.text("UDP 目标尚未解析为明确的 IP 地址。"))
        }
    }
    init(bytes: Data, family: Int32) { self.bytes = bytes; self.family = family }
    func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        bytes.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(bytes.count)) }
    }
}

@MainActor
final class DesktopPortUDPSocket {
    var onError: ((String) -> Void)?
    private var descriptor: DesktopPortUDPDescriptor?
    private var source: DispatchSourceRead?
    private weak var listener: DesktopPortUDPListener?
    private var peer: DesktopPortUDPAddress?
    private var messages: [Data] = []
    private var bytes = 0
    private var receiver: ((Data?, String?) -> Void)?
    private var buffer = [UInt8](repeating: 0, count: DesktopPortLimits.datagram + 1)
    private(set) var closed = false

    init(target: DesktopPortUDPAddress) throws {
        let descriptor = try DesktopPortUDPDescriptor(family: target.family)
        guard target.withAddress({ Darwin.connect(descriptor.value, $0, $1) }) == 0 else {
            let error = DesktopPortUDPDescriptor.failure(); descriptor.close(); throw CloudError(error)
        }
        self.descriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor.value, queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        source.resume()
    }
    fileprivate init(listener: DesktopPortUDPListener, peer: DesktopPortUDPAddress) {
        self.listener = listener; self.peer = peer
    }
    func receive(_ completion: @escaping (Data?, String?) -> Void) {
        guard !closed else { return }
        precondition(receiver == nil)
        if !messages.isEmpty {
            let data = messages.removeFirst(); bytes -= data.count
            DispatchQueue.main.async { completion(data, nil) }
        } else { receiver = completion }
    }
    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        guard !closed else { completion(L10n.text("UDP 会话已关闭。")); return }
        let count: Int
        if let descriptor {
            count = data.withUnsafeBytes { Darwin.send(descriptor.value, $0.baseAddress, $0.count, 0) }
        } else if let listener, let peer { count = listener.send(data, to: peer) }
        else { completion(L10n.text("UDP 监听已停止。")); return }
        let error = count == data.count ? nil : DesktopPortUDPDescriptor.failure()
        DispatchQueue.main.async { completion(error) }
    }
    fileprivate func push(_ data: Data) {
        guard !closed else { return }
        if let receiver {
            self.receiver = nil
            DispatchQueue.main.async { receiver(data, nil) }
        } else if bytes + data.count <= 4 * DesktopPortLimits.datagram, messages.count < 64 {
            messages.append(data); bytes += data.count
        } else { fail(L10n.text("UDP 接收队列已满，此会话已停止。")) }
    }
    private func drain() {
        guard !closed, let descriptor else { return }
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor.value, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                fail(DesktopPortUDPDescriptor.failure()); return
            }
            guard count <= DesktopPortLimits.datagram else { fail(L10n.text("UDP 数据报超过 65507 字节。")); return }
            push(Data(buffer.prefix(count)))
            if closed { return }
        }
    }
    fileprivate func fail(_ reason: String) {
        guard !closed else { return }
        let receive = receiver; receiver = nil
        close(); onError?(reason)
        receive?(nil, reason)
    }
    func close() {
        guard !closed else { return }
        closed = true; source?.cancel(); source = nil; descriptor?.close(); descriptor = nil
        if let peer { listener?.remove(peer, socket: self) }
        listener = nil; peer = nil; receiver = nil; messages.removeAll(); bytes = 0
    }
    deinit { source?.cancel() }
}

@MainActor
final class DesktopPortUDPListener {
    var onConnection: ((DesktopPortUDPSocket) -> Void)?
    var onError: ((String) -> Void)?
    var onLimit: (() -> Void)?
    private let descriptor: DesktopPortUDPDescriptor
    private var source: DispatchSourceRead?
    private var peers: [Data: DesktopPortUDPSocket] = [:]
    private var buffer = [UInt8](repeating: 0, count: DesktopPortLimits.datagram + 1)
    private var closed = false
    let port: Int

    init(address: String, port: Int) throws {
        guard let ip = IPv4Address(address) else { throw CloudError(L10n.text("UDP 监听地址无效。")) }
        let endpoint = try DesktopPortUDPAddress(endpoint: .hostPort(host: .ipv4(ip), port: NWEndpoint.Port(rawValue: UInt16(port))!))
        let descriptor = try DesktopPortUDPDescriptor(family: AF_INET)
        self.descriptor = descriptor
        guard endpoint.withAddress({ Darwin.bind(descriptor.value, $0, $1) }) == 0 else {
            let reason = DesktopPortUDPDescriptor.failure(); descriptor.close(); throw CloudError(reason)
        }
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor.value, $0, &length) }
        }
        guard result == 0 else { let reason = DesktopPortUDPDescriptor.failure(); descriptor.close(); throw CloudError(reason) }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor.value, queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        source.resume()
    }
    private func drain() {
        guard !closed else { return }
        for _ in 0..<16 {
            var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                    buffer.withUnsafeMutableBytes { recvfrom(descriptor.value, $0.baseAddress, $0.count, 0, addr, &length) }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                let reason = DesktopPortUDPDescriptor.failure(); close(); onError?(reason); return
            }
            let bytes = withUnsafeBytes(of: &address) { Data($0.prefix(Int(length))) }
            let peer = DesktopPortUDPAddress(bytes: bytes, family: Int32(address.ss_family))
            if count > DesktopPortLimits.datagram { peers[bytes]?.fail(L10n.text("UDP 数据报超过 65507 字节。")); continue }
            let socket: DesktopPortUDPSocket
            if let existing = peers[bytes] { socket = existing }
            else {
                guard peers.count < DesktopPortLimits.connections else { onLimit?(); continue }
                socket = DesktopPortUDPSocket(listener: self, peer: peer); peers[bytes] = socket
                onConnection?(socket)
            }
            socket.push(Data(buffer.prefix(count)))
            if closed { return }
        }
    }
    fileprivate func send(_ data: Data, to peer: DesktopPortUDPAddress) -> Int {
        guard !closed else { errno = EBADF; return -1 }
        return peer.withAddress { address, length in
            data.withUnsafeBytes { Darwin.sendto(descriptor.value, $0.baseAddress, $0.count, 0, address, length) }
        }
    }
    fileprivate func remove(_ peer: DesktopPortUDPAddress, socket: DesktopPortUDPSocket) {
        if peers[peer.bytes] === socket { peers.removeValue(forKey: peer.bytes) }
    }
    func close() {
        guard !closed else { return }
        closed = true; source?.cancel(); source = nil; descriptor.close()
        let sockets = Array(peers.values); peers.removeAll()
        for socket in sockets { socket.close() }
    }
    deinit { source?.cancel() }
}
