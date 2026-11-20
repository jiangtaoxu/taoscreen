import Combine
import Foundation
import WebRTC

/// 独立端口会话只持有数据通道，不持有桌面采集、输入、声音或桌面窗口。
@MainActor
final class DesktopPortSession: ObservableObject, Identifiable {
    enum Phase { case requesting, awaitingApproval, connecting, connected, closed }
    let id: UUID
    let peer: DesktopPeer
    let host: Bool
    let forwarder: DesktopPortForwarder
    @Published private(set) var phase: Phase
    @Published private(set) var connected = false
    @Published private(set) var recovering = false
    @Published private(set) var route = L10n.text("正在协商")
    @Published private(set) var failure: String?
    private let configuration: () async throws -> DesktopConfiguration
    private let send: (DesktopSignal) -> Void
    private let ended: (DesktopPortSession, String?) -> Void
    private let gate = Gate()
    private let transport = Transport()
    private var timeout: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var recoveryTimeout: Task<Void, Never>?
    private var recovery = DesktopSignalRecovery()
    private var candidates: [DesktopSignal] = []
    private var established = false
    private var resumeSupported = false
    private var keepaliveSupported = false

    @MainActor private final class Gate { var active = true; var connected = false; var authorized = false }
    @MainActor private final class Transport { var rtc: DesktopRTC? }

    init(id: UUID = UUID(), peer: DesktopPeer, host: Bool, store: DesktopPortRuleStore? = nil,
         configuration: @escaping () async throws -> DesktopConfiguration,
         send: @escaping (DesktopSignal) -> Void, ended: @escaping (DesktopPortSession, String?) -> Void = { _, _ in }) {
        self.id = id; self.peer = peer; self.host = host
        self.configuration = configuration; self.send = send; self.ended = ended
        phase = host ? .awaitingApproval : .requesting
        let gate = self.gate, transport = self.transport
        forwarder = DesktopPortForwarder(host: host, store: store,
            allowed: { gate.active && gate.connected && gate.authorized },
            send: { [weak transport] in transport?.rtc?.sendPortData($0) == true },
            transportFailure: { [weak transport] in transport?.rtc?.closePortChannel() })
    }
    var statusText: String {
        if let failure { return failure }
        if recovering { return L10n.text("正在验证独立会话，转发暂时保留…") }
        switch phase {
        case .requesting: return L10n.text("等待对方允许端口转发…")
        case .awaitingApproval: return L10n.text("等待本机确认")
        case .connecting: return L10n.text("正在建立独立加密连接…")
        case .connected: return L10n.text("已连接 · \(route)")
        case .closed: return L10n.text("端口转发连接已结束")
        }
    }
    func request() {
        guard !host, phase == .requesting else { return }
        signal("invite")
        arm(60, message: L10n.text("对方未响应独立端口转发请求，请检查对方版本和在线状态。"))
    }
    func awaitApproval() { arm(55, message: L10n.text("端口转发请求已过期，请重新连接。")) }
    func accept() {
        guard host, phase == .awaitingApproval else { return }
        gate.authorized = true; phase = .connecting; timeout?.cancel()
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareRTC()
                guard self.gate.active, !Task.isCancelled else { return }
                self.signal("accept")
                self.arm(40, message: L10n.text("独立端口连接建立超时。"))
            } catch { if self.gate.active { self.disconnect(error.localizedDescription) } }
        }
    }
    func reject() { disconnect(L10n.text("本机拒绝了端口转发请求。")) }
    private func prepareRTC() async throws {
        let config = try await configuration()
        guard gate.active, !Task.isCancelled else { throw CancellationError() }
        let rtc = try DesktopRTC(configuration: config, host: host, purpose: .ports)
        transport.rtc = rtc
        rtc.onSignal = { [weak self] type, payload in self?.signal(type, payload: payload) }
        rtc.onPortData = { [weak self] data in self?.forwarder.receive(data) }
        rtc.onPortState = { [weak self] open in
            guard let self, self.gate.active else { return }
            self.forwarder.channelChanged(open: open)
            if !open { self.disconnect(self.forwarder.error ?? L10n.text("独立端口转发通道已关闭。")) }
        }
        rtc.onRoute = { [weak self] in self?.route = $0 }
        rtc.onState = { [weak self] state in self?.receiveRTCState(state) }
    }
    private func receiveRTCState(_ state: RTCPeerConnectionState) {
        guard gate.active else { return }
        switch state {
        case .connected:
            connected = true; gate.connected = true; established = true; phase = .connected
            timeout?.cancel(); forwarder.refreshPermission()
        case .disconnected:
            connected = false; gate.connected = false
            forwarder.sessionInterrupted()
            arm(10, message: L10n.text("独立端口连接中断，转发已停止。"))
        case .failed, .closed: disconnect(L10n.text("独立端口连接已结束。"))
        default: break
        }
    }
    func receive(_ value: DesktopSignal) async {
        guard gate.active, value.id == id, value.type == "error" || value.from == peer.id else { return }
        do {
            switch value.type {
            case "accept" where !host && phase == .requesting:
                timeout?.cancel(); gate.authorized = true; phase = .connecting
                try await prepareRTC()
                guard gate.active, let rtc = transport.rtc else { return }
                let offer = try await rtc.makeDescription(offer: true)
                guard gate.active else { return }
                signal("offer", payload: .init(sdp: offer)); arm(40, message: L10n.text("独立端口连接建立超时。"))
            case "offer" where host && gate.authorized:
                guard let sdp = value.payload?.sdp, let rtc = transport.rtc else { throw CloudError(L10n.text("独立端口连接请求无效。")) }
                try await rtc.setRemote(sdp, offer: true)
                let answer = try await rtc.makeDescription(offer: false)
                if gate.active { signal("answer", payload: .init(sdp: answer)) }
            case "answer" where !host && gate.authorized:
                guard let sdp = value.payload?.sdp, let rtc = transport.rtc else { throw CloudError(L10n.text("独立端口连接响应无效。")) }
                try await rtc.setRemote(sdp, offer: false)
            case "candidate" where gate.authorized:
                if let payload = value.payload { transport.rtc?.addCandidate(payload) }
            case "resumed":
                guard recovery.confirm(value.payload?.resumeToken, now: ProcessInfo.processInfo.systemUptime) else { return }
                recovering = false; recoveryTimeout?.cancel(); recoveryTimeout = nil
                let queued = candidates; candidates.removeAll()
                for candidate in queued { send(candidate) }
            case "reject", "end": disconnect(value.payload?.message, notify: false)
            case "error": disconnect(value.payload?.message ?? L10n.text("独立端口信令请求失败。"), notify: false)
            default: break
            }
        } catch { if gate.active { disconnect(error.localizedDescription) } }
    }
    func signalHello(resume: Bool, keepalive: Bool) {
        resumeSupported = resume; keepaliveSupported = keepalive
        if recovering {
            guard resume else { disconnect(L10n.text("服务器不支持恢复独立端口授权。"), notify: false); return }
            signal("resume", payload: .init(resumeToken: recovery.token))
        }
    }
    func heartbeat() {
        if gate.active, established, keepaliveSupported, !recovering { signal("keepalive") }
    }
    func signalInterrupted() {
        guard gate.active else { return }
        guard established, resumeSupported else { disconnect(L10n.text("独立端口信令已中断，请重新连接。"), notify: false); return }
        guard recovery.begin(now: ProcessInfo.processInfo.systemUptime) else { disconnect(L10n.text("独立端口授权恢复超时。"), notify: false); return }
        recovering = true
        guard recoveryTimeout == nil else { return }
        let token = recovery.token
        recoveryTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, self.recovery.token == token, self.recovering else { return }
            self.disconnect(L10n.text("独立端口授权在一分钟内未能恢复，转发已停止。"), notify: false)
        }
    }
    private func signal(_ type: String, payload: DesktopSignal.Payload? = nil) {
        guard gate.active else { return }
        let value = DesktopSignal(type: type, id: id, to: peer.id, payload: payload)
        if type == "candidate", recovering {
            guard candidates.count < 256 else { disconnect(L10n.text("独立端口候选队列已满。"), notify: false); return }
            candidates.append(value)
        } else { send(value) }
    }
    private func arm(_ seconds: Double, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.disconnect(message)
        }
    }
    func disconnect(_ reason: String? = nil, notify: Bool = true) {
        guard gate.active else { return }
        if notify { signal(phase == .awaitingApproval ? "reject" : "end", payload: reason.map { .init(message: $0) }) }
        gate.active = false; gate.connected = false; gate.authorized = false
        connected = false; phase = .closed; failure = reason
        preparation?.cancel(); preparation = nil; timeout?.cancel(); timeout = nil
        recoveryTimeout?.cancel(); recoveryTimeout = nil; recovering = false; candidates.removeAll()
        forwarder.close(); transport.rtc?.close(); transport.rtc = nil
        ended(self, reason)
    }
}
