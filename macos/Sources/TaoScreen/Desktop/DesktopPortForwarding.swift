import Combine
import Foundation
import Network

/// 一个引擎只属于一条已认证会话。规则启动、停止和远端监听都必须收到对应运行 ID 的确认。
@MainActor
final class DesktopPortForwarder: ObservableObject {
    @Published private(set) var rules: [DesktopPortRuleState] = []
    @Published private(set) var incomingRules: [DesktopPortRuleState] = []
    @Published private(set) var remoteAllowed: Bool?
    @Published private(set) var channelOpen = false
    @Published private(set) var closed = false
    @Published private(set) var error: String?
    let host: Bool
    private let store: DesktopPortRuleStore?
    private let allowed: () -> Bool
    private let send: (Data) -> Bool
    private let now: () -> TimeInterval
    private let transportFailure: () -> Void
    private var storageFailed = false
    private var restoredEnabledRules = false
    private var restartAfterStop: Set<UUID> = []
    private var maintenance: Task<Void, Never>?
    private var runs: [UUID: Run] = [:]
    private var streams: [UUID: Stream] = [:]
    private var streamOrder: [UUID] = []
    private var pumpOffset = 0
    private var retiredStreams: [UUID] = []
    private var totalInFlight = 0
    private var pendingWrites = 0
    private var pendingWriteMessages = 0
    private var inFlightFrames = 0
    private var metricTime: TimeInterval = 0
    private var pumping = false
    private lazy var outgoing = DesktopReliableSender(limit: DesktopPortLimits.queue, timeout: 15,
        send: { [weak self] in self?.send($0) == true },
        failed: { [weak self] in self?.fail(L10n.text("端口转发通道持续拥塞，转发已停止，请重新连接设备。")) })

    @MainActor private final class Run {
        let id: UUID
        let rule: DesktopPortRule
        var listener: NWListener?
        var udpListener: DesktopPortUDPListener?
        var phase = DesktopPortRuleState.Phase.starting
        var deadline: TimeInterval
        var failure: String?
        var sent: Int64 = 0
        var received: Int64 = 0
        init(id: UUID, rule: DesktopPortRule, now: TimeInterval) {
            self.id = id; self.rule = rule; deadline = now + 10
        }
    }
    @MainActor private final class Stream {
        let id: UUID
        let run: Run
        var socket: NWConnection?
        var udpSocket: DesktopPortUDPSocket?
        let initiator: Bool
        let created: TimeInterval
        var ready = false
        var openSent = false
        var reading = false
        var pendingRead: Data?
        var pendingEOF = false
        var readEOF = false
        var peerEOF = false
        var finalWriteStarted = false
        var finalWriteDone = false
        var writes: [Data] = []
        var writing = false
        var pendingWriteBytes = 0
        var pendingWriteMessages = 0
        var inFlight = 0
        var outstanding: [(bytes: Int, frames: Int)] = []
        var ackDeadline: TimeInterval?
        var terminalFailure: String?
        var terminalDeadline: TimeInterval?
        var readFailure: String?
        var assembly = DesktopPortDatagramAssembly()
        var lastActivity: TimeInterval
        init(id: UUID, run: Run, socket: NWConnection?, initiator: Bool, now: TimeInterval) {
            self.id = id; self.run = run; self.socket = socket; self.initiator = initiator
            created = now; lastActivity = now
        }
    }

    init(host: Bool, store: DesktopPortRuleStore? = nil, allowed: @escaping () -> Bool,
         send: @escaping (Data) -> Bool, transportFailure: @escaping () -> Void = {},
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.host = host; self.store = store; self.allowed = allowed; self.send = send
        self.transportFailure = transportFailure; self.now = now
        if !host, let store {
            do { rules = try store.load().map { DesktopPortRuleState(rule: $0) } }
            catch { self.error = error.localizedDescription; storageFailed = true }
        }
    }
    var canStart: Bool { !host && !closed && channelOpen && remoteAllowed == true && allowed() && !storageFailed }
    var canEdit: Bool { !host && !storageFailed && !closed }
    var connectionCount: Int { streams.count }
    var bufferedByteCount: Int { outgoing.bufferedBytes + pendingWrites + streams.values.reduce(0) { $0 + ($1.pendingRead?.count ?? 0) } }
    var runningCount: Int { rules.filter(\.running).count }
    var statusText: String {
        if let error { return error }
        if closed { return L10n.text("端口转发通道已关闭，请重新连接设备。") }
        if !channelOpen { return L10n.text("等待端口转发通道；对方需升级到支持本功能的版本。") }
        if host { return allowed() ? L10n.text("已允许当前连接使用双向 TCP / UDP 转发。") : L10n.text("当前连接未获端口转发授权。") }
        if remoteAllowed == nil { return L10n.text("正在确认对方的端口转发能力…") }
        if remoteAllowed == false { return L10n.text("对方未允许端口转发，请在被控端开启本次授权，或重新连接时授权。") }
        if !allowed() { return L10n.text("映射连接尚未就绪，连接后自动启动已启用规则。") }
        return L10n.text("已启用规则正在监听；连接加密传输，不依赖远程桌面。")
    }

    func channelChanged(open: Bool) {
        guard !closed else { return }
        if !open { fail(L10n.text("端口转发通道已关闭或对方版本不支持，请重新连接已升级的设备。")); return }
        guard !channelOpen else { return }
        channelOpen = true
        refreshPermission()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.tick()
            }
        }
    }

    func refreshPermission() {
        guard !closed else { return }
        if !allowed() { stopAll(reason: L10n.text("当前连接的端口转发授权已撤销或连接已中断。")) }
        if host, channelOpen { enqueue(.init(kind: .status, allowed: allowed())) }
        restoreEnabledRulesIfReady()
    }
    func sessionInterrupted() {
        restoredEnabledRules = false
        stopAll(reason: L10n.text("映射连接已中断，正在停止监听。"))
    }
    private func restoreEnabledRulesIfReady() {
        guard canStart else { restoredEnabledRules = false; return }
        guard !restoredEnabledRules else { return }
        restoredEnabledRules = true
        for state in rules where state.rule.isEnabled {
            if state.phase == .stopping { restartAfterStop.insert(state.id); continue }
            guard !state.running else { continue }
            do { try start(state.id) }
            catch { updateRule(state.id) { $0.phase = .failed; $0.error = error.localizedDescription } }
        }
    }
    func save(_ rule: DesktopPortRule) throws {
        guard canEdit, rule.isValid else { throw CloudError(L10n.text("规则无法保存，请检查地址、端口及存储状态。")) }
        guard !rules.contains(where: { $0.id == rule.id && $0.running }) else { throw CloudError(L10n.text("请先停止这条规则，再修改配置。")) }
        var next = rules.map(\.rule)
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        guard next.count <= DesktopPortLimits.rules else { throw CloudError(L10n.text("每台设备最多保存 8 条端口规则。")) }
        guard !next.contains(where: { $0.id != rule.id && $0.conflicts(with: rule) }) else {
            throw CloudError(L10n.text("同一监听端的地址、协议和端口与已有规则冲突。"))
        }
        try store?.save(next)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = .init(rule: rule) }
        else { rules.append(.init(rule: rule)) }
        if rule.isEnabled, canStart { try start(rule.id) }
    }
    func setEnabled(_ ruleID: UUID, _ enabled: Bool) throws {
        guard canEdit, let index = rules.firstIndex(where: { $0.id == ruleID }) else { throw CloudError(L10n.text("映射规则无法修改。")) }
        guard rules[index].phase != .stopping else { throw CloudError(L10n.text("正在等待停止确认，请稍后重试。")) }
        var next = rules.map(\.rule)
        next[index].isEnabled = enabled
        try store?.save(next)
        rules[index].rule.isEnabled = enabled
        if !enabled { restartAfterStop.remove(ruleID); stop(ruleID) }
        else if canStart, !rules[index].running { try start(ruleID) }
    }
    func remove(_ ruleID: UUID) throws {
        guard canEdit, let state = rules.first(where: { $0.id == ruleID }), !state.running else {
            throw CloudError(L10n.text("请先停止这条规则，再删除。"))
        }
        try store?.save(rules.filter { $0.id != ruleID }.map(\.rule))
        rules.removeAll { $0.id == ruleID }
    }
    func start(_ ruleID: UUID) throws {
        guard canStart else { throw CloudError(statusText) }
        guard let state = rules.first(where: { $0.id == ruleID }), !state.running, state.rule.isValid else {
            throw CloudError(L10n.text("规则不存在或尚未停止。"))
        }
        let run = Run(id: UUID(), rule: state.rule, now: now())
        runs[run.id] = run
        updateRule(ruleID) { $0.phase = .starting; $0.error = nil; $0.sent = 0; $0.received = 0 }
        enqueue(.init(kind: .startRule, id: run.id, rule: run.rule))
    }
    func stop(_ ruleID: UUID) {
        guard let run = runs.values.first(where: { $0.rule.id == ruleID }) else { return }
        if host { endHostRun(run, reason: L10n.text("被控电脑已停止此规则。")) }
        else { requestStop(run) }
    }
    private func requestStop(_ run: Run, failure: String? = nil) {
        guard runs[run.id] === run, run.phase != .stopping else { return }
        cancelListener(run)
        closeStreams(run: run)
        run.phase = .stopping; run.failure = failure; run.deadline = now() + 10
        syncSnapshots()
        enqueue(.init(kind: .stopRule, id: run.id))
    }
    private func endHostRun(_ run: Run, reason: String? = nil) {
        cancelListener(run); closeStreams(run: run)
        runs.removeValue(forKey: run.id)
        syncSnapshots()
        enqueue(.init(kind: .ruleStopped, id: run.id, message: safeMessage(reason)))
    }

    func receive(_ data: Data) {
        guard !closed else { return }
        do { try receive(DesktopPortPacket.decode(data)) }
        catch { fail(L10n.text("端口转发协议错误：\(error.localizedDescription)")) }
    }
    private func receive(_ packet: DesktopPortPacket) throws {
        switch packet.kind {
        case .status:
            guard !host else { throw CloudError(L10n.text("对方不能修改本机授权。")) }
            remoteAllowed = packet.allowed
            if remoteAllowed == false { stopAll(reason: L10n.text("对方未允许端口转发或已撤销授权。")) }
            restoreEnabledRulesIfReady()
        case .startRule:
            guard host, let id = packet.id, let rule = packet.rule else { throw CloudError(L10n.text("规则发起方向无效。")) }
            guard allowed(), channelOpen else {
                enqueue(.init(kind: .ruleStopped, id: id, message: L10n.text("被控电脑未允许端口转发。"))); return
            }
            guard runs.count < DesktopPortLimits.rules, runs[id] == nil,
                  !runs.values.contains(where: { $0.rule.id == rule.id || $0.rule.conflicts(with: rule) }) else {
                enqueue(.init(kind: .ruleStopped, id: id, message: L10n.text("规则数量已达上限或监听配置冲突。"))); return
            }
            let run = Run(id: id, rule: rule, now: now()); runs[id] = run
            if rule.direction.listenerIsHost { listen(run) }
            else { run.phase = .listening; enqueue(.init(kind: .ruleStarted, id: id)); syncSnapshots() }
        case .ruleStarted:
            guard !host else { throw CloudError(L10n.text("规则确认方向无效。")) }
            guard let id = packet.id, let run = runs[id], run.phase == .starting else { return }
            if run.rule.direction.listenerIsHost { run.phase = .listening; syncSnapshots() }
            else { listen(run) }
        case .stopRule:
            guard host, let id = packet.id else { throw CloudError(L10n.text("停止请求方向无效。")) }
            if let run = runs[id] { endHostRun(run) }
            else { enqueue(.init(kind: .ruleStopped, id: id)) }
        case .ruleStopped:
            guard !host else { throw CloudError(L10n.text("停止确认方向无效。")) }
            guard let id = packet.id, let run = runs[id] else { return }
            cancelListener(run); closeStreams(run: run)
            let failed = run.phase == .starting || run.failure != nil
            updateRule(run.rule.id) {
                $0.phase = failed ? .failed : .stopped; $0.error = run.failure ?? packet.message
            }
            runs.removeValue(forKey: id); syncSnapshots()
            // 恢复时若上一轮仍在等待停止确认，确认到达后再启动已启用规则。
            if restartAfterStop.remove(run.rule.id) != nil, let state = rules.first(where: { $0.id == run.rule.id }), state.rule.isEnabled, canStart {
                try start(state.id)
            }
        case .open:
            try acceptStream(packet)
        default:
            guard let id = packet.id, let stream = streams[id] else { return }
            try receive(packet, stream: stream)
        }
    }

    private func listen(_ run: Run) {
        guard runs[run.id] === run, allowed() else { return }
        do {
            if run.rule.transport == .udp {
                let listener = try DesktopPortUDPListener(address: run.rule.listenAddress, port: run.rule.listenPort)
                guard listener.port == run.rule.listenPort else { listener.close(); throw CloudError(L10n.text("实际 UDP 监听端口与配置不一致。")) }
                run.udpListener = listener
                listener.onConnection = { [weak self, weak run] socket in
                    guard let self, let run, self.runs[run.id] === run, run.phase == .listening,
                          self.allowed() else { socket.close(); return }
                    guard self.streams.count < DesktopPortLimits.connections else {
                        socket.close(); self.connectionLimit(run); return
                    }
                    let stream = Stream(id: UUID(), run: run, socket: nil, initiator: true, now: self.now())
                    stream.openSent = true
                    stream.udpSocket = socket; self.streams[stream.id] = stream; self.streamOrder.append(stream.id)
                    socket.onError = { [weak self, weak stream] in if let stream { self?.closeStream(stream, reason: $0) } }
                    self.enqueue(.init(kind: .open, id: stream.id, runID: run.id))
                }
                listener.onError = { [weak self, weak run] reason in if let run { self?.listenerFailed(run, reason: reason) } }
                listener.onLimit = { [weak self, weak run] in if let run { self?.connectionLimit(run) } }
                run.phase = .listening
                if host { enqueue(.init(kind: .ruleStarted, id: run.id)) }
                syncSnapshots()
                return
            }
            let port = NWEndpoint.Port(rawValue: UInt16(run.rule.listenPort))!
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(run.rule.listenAddress), port: port)
            parameters.allowLocalEndpointReuse = false
            // 地址和端口已在 requiredLocalEndpoint 精确指定，不能在 on: 再次指定端口。
            let listener = try NWListener(using: parameters)
            run.listener = listener
            listener.stateUpdateHandler = { [weak self, weak run] state in
                MainActor.assumeIsolated {
                    guard let self, let run, self.runs[run.id] === run, run.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard listener.port == port else { self.listenerFailed(run, reason: L10n.text("实际监听端口与配置不一致。")); return }
                        run.phase = .listening
                        if self.host { self.enqueue(.init(kind: .ruleStarted, id: run.id)) }
                        self.syncSnapshots()
                    case .failed(let error): self.listenerFailed(run, reason: L10n.text("监听 \(run.rule.listener) 失败：\(error.localizedDescription)"))
                    case .waiting(let error): self.listenerFailed(run, reason: L10n.text("监听 \(run.rule.listener) 不可用：\(error.localizedDescription)"))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak run] socket in
                MainActor.assumeIsolated {
                    guard let self, let run, self.runs[run.id] === run, run.phase == .listening,
                          self.allowed() else { socket.cancel(); return }
                    guard self.streams.count < DesktopPortLimits.connections else {
                        socket.cancel(); self.connectionLimit(run); return
                    }
                    self.makeStream(id: UUID(), run: run, socket: socket, initiator: true)
                }
            }
            listener.start(queue: .main)
        } catch { listenerFailed(run, reason: L10n.text("监听 \(run.rule.listener) 失败：\(error.localizedDescription)")) }
    }
    private func listenerFailed(_ run: Run, reason: String) {
        if host { endHostRun(run, reason: reason) }
        else { requestStop(run, failure: reason) }
    }
    private func connectionLimit(_ run: Run) {
        let message = L10n.text("活动转发会话已达 32 个上限，已拒绝新会话。")
        if run.failure != message { run.failure = message; syncSnapshots() }
    }
    private func cancelListener(_ run: Run) {
        run.listener?.stateUpdateHandler = nil; run.listener?.newConnectionHandler = nil
        run.listener?.cancel(); run.listener = nil
        run.udpListener?.onConnection = nil; run.udpListener?.onError = nil
        run.udpListener?.onLimit = nil
        run.udpListener?.close(); run.udpListener = nil
    }

    private func acceptStream(_ packet: DesktopPortPacket) throws {
        guard let id = packet.id, let runID = packet.runID else { throw CloudError(L10n.text("连接标识无效。")) }
        guard let run = runs[runID], run.phase == .listening,
              run.rule.direction.listenerIsHost != host, allowed(), host || remoteAllowed == true,
              streams[id] == nil, !retiredStreams.contains(id), streams.count < DesktopPortLimits.connections else {
            enqueue(.init(kind: .close, id: id, message: L10n.text("规则未启动、未获授权或连接数已达上限。"))); return
        }
        let parameters: NWParameters = run.rule.transport == .tcp ? .tcp : .udp
        let socket = NWConnection(host: NWEndpoint.Host(run.rule.destinationHost),
                                  port: NWEndpoint.Port(rawValue: UInt16(run.rule.destinationPort))!, using: parameters)
        makeStream(id: id, run: run, socket: socket, initiator: false)
    }
    private func makeStream(id: UUID, run: Run, socket: NWConnection, initiator: Bool) {
        let stream = Stream(id: id, run: run, socket: socket, initiator: initiator, now: now())
        streams[id] = stream
        streamOrder.append(id)
        socket.stateUpdateHandler = { [weak self, weak stream] state in
            MainActor.assumeIsolated {
                guard let self, let stream, self.streams[id] === stream else { return }
                switch state {
                case .ready:
                    guard self.allowed() else { self.closeStream(stream, reason: L10n.text("端口转发授权已失效。")); return }
                    if stream.ready {
                        stream.terminalFailure = nil; stream.terminalDeadline = nil; self.pump(); return
                    }
                    if run.rule.transport == .udp {
                        do {
                            guard let endpoint = socket.currentPath?.remoteEndpoint else { throw CloudError(L10n.text("UDP 目标尚未解析为明确地址。")) }
                            let udp = try DesktopPortUDPSocket(target: DesktopPortUDPAddress(endpoint: endpoint))
                            stream.udpSocket = udp
                            udp.onError = { [weak self, weak stream] in if let stream { self?.closeStream(stream, reason: $0) } }
                            socket.stateUpdateHandler = nil; socket.cancel(); stream.socket = nil
                        } catch { self.closeStream(stream, reason: error.localizedDescription); return }
                    }
                    if initiator {
                        if !stream.openSent { stream.openSent = true; self.enqueue(.init(kind: .open, id: id, runID: run.id)) }
                    }
                    else {
                        stream.ready = true
                        self.enqueue(.init(kind: .opened, id: id)); self.syncSnapshots(); self.pump()
                    }
                case .failed(let error), .waiting(let error):
                    if stream.ready {
                        // TCP 两端发送 FIN 后，终态通知可能先于剩余缓冲区的 receive 回调到达。
                        // 由 receive 的 EOF / 错误确定读取结果，避免提前取消尚未交付的尾部字节。
                        stream.terminalFailure = error.localizedDescription; stream.terminalDeadline = self.now() + 10
                        self.pump()
                    } else { self.closeStream(stream, reason: L10n.text("目标连接状态异常：\(error.localizedDescription)")) }
                default: break
                }
            }
        }
        socket.start(queue: .main)
    }

    private func receive(_ packet: DesktopPortPacket, stream: Stream) throws {
        switch packet.kind {
        case .opened:
            guard stream.initiator, !stream.ready else { throw CloudError(L10n.text("连接重复确认或方向无效。")) }
            stream.ready = true; syncSnapshots(); pump()
        case .data:
            guard stream.ready, stream.run.rule.transport == .tcp, !stream.peerEOF else { throw CloudError(L10n.text("TCP 数据不属于有效连接。")) }
            let data = packet.payload!
            try reserveWrite(data.count, stream: stream)
            stream.writes.append(data); write(stream)
        case .datagram:
            guard stream.ready, stream.run.rule.transport == .udp else { throw CloudError(L10n.text("UDP 数据不属于有效连接。")) }
            if stream.assembly.id == nil { try reserveWrite(max(1, packet.length!), stream: stream) }
            if let data = try stream.assembly.append(packet, now: now()) { stream.writes.append(data); write(stream) }
        case .ack:
            let bytes = packet.bytes!
            guard let first = stream.outstanding.first, bytes == first.bytes else { throw CloudError(L10n.text("收到不匹配的转发确认。")) }
            stream.outstanding.removeFirst(); inFlightFrames -= first.frames
            stream.inFlight -= bytes; totalInFlight -= bytes
            stream.ackDeadline = stream.inFlight == 0 ? nil : now() + 30
            finishIfPossible(stream); pump()
        case .eof:
            guard stream.run.rule.transport == .tcp, stream.ready, !stream.peerEOF else { throw CloudError(L10n.text("TCP 半关闭状态无效。")) }
            stream.peerEOF = true; write(stream)
        case .close:
            // 对端已发送 EOF 时，正常 close 不能抢在本机最后一次写入 / FIN 之前取消 TCP。
            if packet.message == nil, stream.run.rule.transport == .tcp, stream.readEOF, stream.peerEOF {
                finishIfPossible(stream)
            } else { closeStream(stream, reason: packet.message, notify: false) }
        default: throw CloudError(L10n.text("连接消息类型无效。"))
        }
    }
    private func reserveWrite(_ bytes: Int, stream: Stream) throws {
        guard stream.pendingWriteBytes + bytes <= DesktopPortLimits.streamWindow,
              pendingWrites + bytes <= DesktopPortLimits.totalWindow,
              stream.pendingWriteMessages < 16, pendingWriteMessages < 64 else { throw CloudError(L10n.text("端口转发接收窗口已超限。")) }
        stream.pendingWriteBytes += bytes; pendingWrites += bytes; stream.lastActivity = now()
        stream.pendingWriteMessages += 1; pendingWriteMessages += 1
    }
    private func write(_ stream: Stream) {
        guard streams[stream.id] === stream, !stream.writing else { return }
        if let data = stream.writes.first {
            stream.writing = true
            let complete: (String?) -> Void = { [weak self, weak stream] error in
                    guard let self, let stream, self.streams[stream.id] === stream else { return }
                    if let error { self.closeStream(stream, reason: L10n.text("写入目标失败：\(error)")); return }
                    stream.writes.removeFirst(); stream.writing = false
                    let credit = stream.run.rule.transport == .udp ? max(1, data.count) : data.count
                    stream.pendingWriteBytes -= credit; self.pendingWrites -= credit
                    stream.pendingWriteMessages -= 1; self.pendingWriteMessages -= 1
                    stream.run.received += Int64(data.count); stream.lastActivity = self.now()
                    self.enqueue(.init(kind: .ack, id: stream.id, bytes: credit))
                    self.write(stream); self.finishIfPossible(stream)
            }
            if let udp = stream.udpSocket { udp.send(data, completion: complete) }
            else if let socket = stream.socket {
                socket.send(content: data, completion: .contentProcessed { error in
                    MainActor.assumeIsolated { complete(error?.localizedDescription) }
                })
            } else { closeStream(stream, reason: L10n.text("目标连接已关闭。")) }
        } else if stream.peerEOF, !stream.finalWriteStarted {
            stream.finalWriteStarted = true
            stream.socket?.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self, weak stream] error in
                    MainActor.assumeIsolated {
                        guard let self, let stream, self.streams[stream.id] === stream else { return }
                        if let error { self.closeStream(stream, reason: L10n.text("结束 TCP 写入失败：\(error.localizedDescription)")); return }
                        stream.finalWriteDone = true; self.finishIfPossible(stream)
                    }
                })
        }
    }

    /// 每条连接至多保留一块待读数据。全局字节窗口和独立发送队列限制内存，并给键鼠通道留出调度机会。
    private func pump() {
        guard !closed, channelOpen, !pumping, allowed() else { return }
        pumping = true; defer { pumping = false }
        let order = streamOrder
        guard !order.isEmpty else { return }
        let start = pumpOffset % order.count
        pumpOffset = (start + 1) % order.count
        for offset in order.indices {
            guard !closed, let stream = streams[order[(start + offset) % order.count]], stream.ready else { continue }
            if let data = stream.pendingRead {
                let credit = stream.run.rule.transport == .udp ? max(1, data.count) : data.count
                guard stream.inFlight + credit <= DesktopPortLimits.streamWindow,
                      totalInFlight + credit <= DesktopPortLimits.totalWindow else { continue }
                let packets = stream.run.rule.transport == .tcp ? [DesktopPortPacket(kind: .data, id: stream.id, payload: data)]
                    : DesktopPortPacket.datagrams(id: stream.id, data: data)
                do {
                    let encoded = try packets.map { try $0.encoded() }
                    guard inFlightFrames + encoded.count <= 64, stream.outstanding.count < 16,
                          outgoing.bufferedBytes + encoded.reduce(0, { $0 + $1.count }) <= DesktopPortLimits.queue - 64 * 1024 else { continue }
                    stream.pendingRead = nil; stream.inFlight += credit; totalInFlight += credit
                    stream.outstanding.append((credit, encoded.count)); inFlightFrames += encoded.count
                    stream.ackDeadline = stream.ackDeadline ?? now() + 30
                    stream.run.sent += Int64(data.count); stream.lastActivity = now()
                    for packet in encoded { outgoing.send(packet) }
                } catch { fail(error.localizedDescription); return }
            }
            guard streams[stream.id] === stream else { continue }
            if let failure = stream.readFailure, stream.pendingRead == nil, stream.inFlight == 0 {
                closeStream(stream, reason: failure); continue
            }
            if stream.pendingRead == nil, stream.pendingEOF, !stream.readEOF {
                stream.readEOF = true; enqueue(.init(kind: .eof, id: stream.id)); finishIfPossible(stream)
            }
            read(stream)
        }
    }
    private func read(_ stream: Stream) {
        guard streams[stream.id] === stream, stream.ready, !stream.reading, stream.pendingRead == nil,
              !stream.readEOF, stream.readFailure == nil, stream.inFlight < DesktopPortLimits.streamWindow else { return }
        stream.reading = true
        if let udp = stream.udpSocket {
            udp.receive { [weak self, weak stream] data, error in
                guard let self, let stream, self.streams[stream.id] === stream else { return }
                stream.reading = false
                if let error { self.closeStream(stream, reason: error); return }
                guard let data else { self.closeStream(stream, reason: L10n.text("UDP 消息读取失败。")); return }
                stream.pendingRead = data; self.pump()
            }
            return
        }
        let completion: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self, weak stream] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let stream, self.streams[stream.id] === stream else { return }
                stream.reading = false
                if stream.run.rule.transport == .udp {
                    self.closeStream(stream, reason: L10n.text("UDP 会话缺少数据报套接字。")); return
                } else {
                    if let data, !data.isEmpty { stream.pendingRead = data }
                    if let error { stream.readFailure = L10n.text("读取目标失败：\(error.localizedDescription)") }
                    else {
                        stream.pendingEOF = complete
                        if complete { stream.terminalFailure = nil; stream.terminalDeadline = nil }
                    }
                }
                self.pump()
            }
        }
        stream.socket?.receive(minimumIncompleteLength: 1, maximumLength: DesktopPortLimits.chunk, completion: completion)
    }
    private func finishIfPossible(_ stream: Stream) {
        if stream.readEOF && stream.finalWriteDone && stream.inFlight == 0 && stream.pendingWriteBytes == 0 {
            closeStream(stream)
        }
    }
    private func closeStreams(run: Run) {
        for stream in Array(streams.values) where stream.run === run { closeStream(stream) }
    }
    private func closeStream(_ stream: Stream, reason: String? = nil, notify: Bool = true) {
        guard streams.removeValue(forKey: stream.id) != nil else { return }
        streamOrder.removeAll { $0 == stream.id }
        stream.socket?.stateUpdateHandler = nil; stream.socket?.cancel(); stream.socket = nil
        stream.udpSocket?.onError = nil; stream.udpSocket?.close(); stream.udpSocket = nil
        totalInFlight -= stream.inFlight; pendingWrites -= stream.pendingWriteBytes
        pendingWriteMessages -= stream.pendingWriteMessages
        inFlightFrames -= stream.outstanding.reduce(0) { $0 + $1.frames }
        retiredStreams.append(stream.id)
        if retiredStreams.count > 256 { retiredStreams.removeFirst(retiredStreams.count - 256) }
        if let reason { stream.run.failure = reason }
        if notify { enqueue(.init(kind: .close, id: stream.id, message: safeMessage(reason))) }
        syncSnapshots()
    }

    func tick() {
        guard !closed else { return }
        if !allowed(), !runs.isEmpty { stopAll(reason: L10n.text("端口转发授权已失效或独立端口连接已中断。")) }
        let time = now()
        for run in Array(runs.values) where run.phase == .starting || run.phase == .stopping {
            if time > run.deadline {
                fail(run.phase == .stopping ? L10n.text("未收到停止确认，转发通道已关闭，请检查远端状态。") : L10n.text("端口转发启动确认超时，通道已关闭，请重新连接设备。"))
                return
            }
        }
        for stream in Array(streams.values) {
            if !stream.ready && time - stream.created > 10 { closeStream(stream, reason: L10n.text("连接目标服务超时。")) }
            else if stream.ackDeadline.map({ time > $0 }) == true { closeStream(stream, reason: L10n.text("等待转发数据写入确认超时。")) }
            else if stream.terminalDeadline.map({ time > $0 }) == true { closeStream(stream, reason: stream.terminalFailure) }
            else if stream.assembly.deadline.map({ time > $0 }) == true { closeStream(stream, reason: L10n.text("UDP 数据报重组超时。")) }
            else if stream.run.rule.transport == .udp && time - stream.lastActivity > 60 { closeStream(stream) }
        }
        pump()
        if time - metricTime >= 1 { metricTime = time; syncSnapshots() }
    }
    private func updateRule(_ id: UUID, _ change: (inout DesktopPortRuleState) -> Void) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        change(&rules[index])
    }
    private func syncSnapshots() {
        if host {
            incomingRules = runs.values.sorted { $0.rule.listenPort < $1.rule.listenPort }.map { run in
                .init(rule: run.rule, phase: run.phase, connections: streams.values.filter { $0.run === run && $0.ready }.count,
                      sent: run.sent, received: run.received, error: run.failure)
            }
        } else {
            for run in runs.values {
                updateRule(run.rule.id) {
                    $0.phase = run.phase; $0.error = run.failure; $0.sent = run.sent; $0.received = run.received
                    $0.connections = streams.values.filter { $0.run === run && $0.ready }.count
                }
            }
            for index in rules.indices where !rules[index].running { rules[index].connections = 0 }
        }
    }
    private func enqueue(_ packet: DesktopPortPacket) {
        guard !closed, channelOpen else { return }
        do { outgoing.send(try packet.encoded()) }
        catch { fail(error.localizedDescription) }
    }
    private func safeMessage(_ value: String?) -> String? {
        value.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(500))) }
    }
    private func stopAll(reason: String) {
        for run in Array(runs.values) {
            if !host && !closed { requestStop(run, failure: reason); continue }
            cancelListener(run); closeStreams(run: run)
            run.phase = .stopped; run.failure = reason
            updateRule(run.rule.id) { $0.phase = .stopped; $0.error = reason; $0.connections = 0 }
            if host { enqueue(.init(kind: .ruleStopped, id: run.id, message: safeMessage(reason))) }
            else { enqueue(.init(kind: .stopRule, id: run.id)) }
        }
        if host || closed { runs.removeAll(); incomingRules = [] }
    }
    private func fail(_ reason: String) {
        guard !closed else { return }
        error = reason
        close()
        transportFailure()
    }
    func close() {
        guard !closed else { return }
        closed = true; channelOpen = false
        restartAfterStop.removeAll()
        maintenance?.cancel(); maintenance = nil
        stopAll(reason: error ?? L10n.text("独立端口连接已结束，转发已停止。"))
        outgoing.close()
        streams.removeAll(); streamOrder.removeAll(); totalInFlight = 0; pendingWrites = 0; pendingWriteMessages = 0; inFlightFrames = 0
    }
}
