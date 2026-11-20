import AppKit
import Combine
import Foundation

/// 独立在线服务：不读取桌面开关或桌面会话，不因 DesktopCenter.disconnect/shutdown 停止。
@MainActor
final class DesktopPortService: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); reconcile() } }
    @Published private(set) var online = false
    @Published private(set) var status = L10n.text("未开启独立端口转发")
    @Published private(set) var peers: [DesktopPeer] = []
    @Published private(set) var knownPeers: [DesktopPeer] = []
    @Published var selectedPeerID: UUID?
    @Published private(set) var sessions: [DesktopPortSession] = []
    @Published var selectedSessionID: UUID?
    @Published private(set) var autoAccept = false
    @Published private(set) var settingsAccountID: String?
    @Published var message: String?
    static let enabledKey = "taoscreen.ports.enabled"
    private let defaults: UserDefaults
    private weak var cloud: DesktopAccountState?
    private var observations: Set<AnyCancellable> = []
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var activeAccountID: String?
    private var suspended = false
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private let network = URLSession(configuration: .ephemeral)
    private var serviceTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var lastHeartbeat: TimeInterval = 0
    private var resumeSupported = false
    private var keepaliveSupported = false
    private var mappingDrafts: [UUID: DesktopPortForwarder] = [:]
    private var requestedMappingPeerID: UUID?
    private var catalogWritable = true
    private(set) var mappingWindowActive = false

    init(defaults: UserDefaults = DesktopRuntime.defaults) {
        self.defaults = defaults; enabled = defaults.bool(forKey: Self.enabledKey)
    }
    var pending: [DesktopPortSession] { sessions.filter { $0.host && $0.phase == .awaitingApproval } }
    var hasOutgoingMappings: Bool { sessions.contains { !$0.host } }
    func mappingSession(for peerID: UUID) -> DesktopPortSession? { sessions.first { $0.peer.id == peerID } }
    func mappingForwarder(for peer: DesktopPeer) -> DesktopPortForwarder? {
        if let session = mappingSession(for: peer.id) { return session.forwarder }
        guard let accountID = settingsAccountID else { return nil }
        if let existing = mappingDrafts[peer.id] { return existing }
        let forwarder = DesktopPortForwarder(host: false,
            store: .init(defaults: defaults, accountID: accountID, peerID: peer.id),
            allowed: { false }, send: { _ in false })
        mappingDrafts[peer.id] = forwarder
        return forwarder
    }
    func openMapping(for peer: DesktopPeer) {
        guard settingsAccountID != nil else { message = L10n.text("请先登录账号，再管理端口映射。"); return }
        remember([peer]); selectedPeerID = peer.id
        selectedSessionID = mappingSession(for: peer.id)?.id
        if !enabled { enabled = true }
        mappingWindowActive = true; requestedMappingPeerID = peer.id
        connectRequestedMapping()
    }
    func activateMappingWindow() {
        mappingWindowActive = true
        if !enabled { enabled = true }
        if let peer = knownPeers.first(where: { $0.id == selectedPeerID }) ?? knownPeers.first { openMapping(for: peer) }
    }
    func disconnectOutgoingMappings() {
        mappingWindowActive = false; requestedMappingPeerID = nil
        for session in sessions.filter({ !$0.host }) { session.disconnect() }
    }
    private func connectRequestedMapping() {
        guard mappingWindowActive, online, let id = requestedMappingPeerID else { return }
        if let session = mappingSession(for: id) {
            selectedSessionID = session.id; requestedMappingPeerID = nil; return
        }
        guard let peer = peers.first(where: { $0.id == id }) else { return }
        requestedMappingPeerID = nil; connect(to: peer)
    }
    private func remember(_ peers: [DesktopPeer]) {
        guard let accountID = settingsAccountID else { return }
        var next = knownPeers
        for peer in peers {
            if let index = next.firstIndex(where: { $0.id == peer.id }) { next[index] = peer }
            else if next.count < 512 { next.append(peer) }
        }
        if next != knownPeers {
            knownPeers = next
            if catalogWritable {
                do { try DesktopPortDeviceStore(defaults: defaults, accountID: accountID).save(next) }
                catch { message = error.localizedDescription }
            }
        }
    }
    private func clearMappingDrafts() {
        for forwarder in mappingDrafts.values { forwarder.close() }
        mappingDrafts.removeAll()
    }
    func attach(cloud: DesktopAccountState) {
        guard self.cloud == nil else { return }
        self.cloud = cloud
        cloud.$account.combineLatest(cloud.$needsLogin).sink { [weak self] _, _ in
            Task { @MainActor in self?.reconcile() }
        }.store(in: &observations)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in
                    self?.suspended = true; self?.shutdown(reason: L10n.text("电脑休眠或当前用户会话已离开，独立转发已停止。"))
                }
            }.store(in: &observations)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.suspended = false; self?.reconcile() }
            }.store(in: &observations)
        }
        reconcile()
    }
    func setAutoAccept(_ value: Bool) {
        guard let settingsAccountID, cloud?.account?.id == settingsAccountID, cloud?.peerClient != nil else { return }
        defaults.set(value, forKey: "taoscreen.ports.autoAccept.\(settingsAccountID)")
        autoAccept = value
    }
    private func reconcile() {
        let account = cloud?.peerClient != nil ? cloud?.account?.id : nil
        if settingsAccountID != account {
            clearMappingDrafts(); requestedMappingPeerID = nil; selectedPeerID = nil; knownPeers = []; catalogWritable = true
            settingsAccountID = account
            autoAccept = account.map { defaults.bool(forKey: "taoscreen.ports.autoAccept.\($0)") } ?? false
            if let account {
                do { knownPeers = try DesktopPortDeviceStore(defaults: defaults, accountID: account).load() }
                catch { catalogWritable = false; message = L10n.text("映射设备记录无法读取：\(error.localizedDescription)") }
            }
        }
        let desired = enabled && !suspended ? account : nil
        if desired == activeAccountID, serviceTask != nil { return }
        shutdown()
        guard let desired, let api = cloud?.peerClient else {
            status = enabled ? L10n.text("请先登录账户，并保持当前用户会话可用") : L10n.text("未开启独立端口转发")
            return
        }
        activeAccountID = desired
        RemoteAvailability.shared.setActive(.ports, true)
        let token = generation
        serviceTask = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled, self.generation == token {
                var attempted: URLSessionWebSocketTask?
                do {
                    self.status = L10n.text("正在连接独立端口服务…")
                    var request = try await api.portsRequest(); request.timeoutInterval = 15
                    guard self.generation == token, !Task.isCancelled else { return }
                    let socket = self.network.webSocketTask(with: request); attempted = socket; self.socket = socket
                    socket.maximumMessageSize = 64 * 1024; self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                    socket.resume()
                    self.heartbeat = Task { [weak self, weak socket] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            guard let self, let socket, self.generation == token, self.socket === socket, !Task.isCancelled else { return }
                            if ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 70 { socket.cancel(with: .goingAway, reason: nil); return }
                        }
                    }
                    while !Task.isCancelled, self.generation == token, self.socket === socket {
                        let response = try await socket.receive()
                        guard self.generation == token, !Task.isCancelled else { return }
                        let data: Data
                        switch response { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard data.count <= 64 * 1024 else { throw CloudError(L10n.text("独立端口信令过大。")) }
                        let signal = try JSONDecoder().decode(DesktopSignal.self, from: data)
                        self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                        if signal.type == "session_revoked" {
                            self.shutdown(reason: L10n.text("登录授权已失效，独立端口连接已停止。"))
                            self.cloud?.requireLogin(L10n.text("登录授权已失效，请重新登录。")); return
                        }
                        if signal.type == "hello" {
                            guard signal.payload?.independent == true else {
                                self.shutdown(reason: L10n.text("服务器未声明支持独立端口会话，请升级服务端。"))
                                self.message = L10n.text("服务器未声明支持独立端口会话，请升级服务端。")
                                return
                            }
                            self.online = true; self.status = L10n.text("独立端口服务在线 · 仅同账号设备可见"); attempt = 0
                            self.resumeSupported = signal.payload?.resume == true; self.keepaliveSupported = signal.payload?.keepalive == true
                            for session in self.sessions { session.signalHello(resume: self.resumeSupported, keepalive: self.keepaliveSupported) }
                            self.maintenance?.cancel()
                            self.maintenance = Task { [weak self] in
                                while !Task.isCancelled, let self, self.generation == token {
                                    await self.refresh(); try? await Task.sleep(for: .seconds(10))
                                }
                            }
                        } else if signal.type == "heartbeat" {
                            for session in self.sessions { session.heartbeat() }
                        } else { await self.receive(signal) }
                    }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    let failure = DesktopSignalFailure.classify(error,
                        httpStatus: (attempted?.response as? HTTPURLResponse)?.statusCode,
                        closeCode: attempted?.closeCode.rawValue)
                    if failure == .authentication {
                        self.shutdown(reason: L10n.text("登录授权已失效，独立端口连接已停止。"))
                        self.cloud?.requireLogin(L10n.text("独立端口服务登录已失效。")); return
                    }
                    if failure.endsSession { self.shutdown(reason: L10n.text("独立端口信令无效，连接已停止。")); return }
                    self.status = failure == .endpointUnavailable ? L10n.text("独立端口接口不可用，请确认服务端已升级") : L10n.text("独立端口信令中断，正在恢复…")
                    for session in self.sessions { session.signalInterrupted() }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.online = false; self.peers = []
                self.heartbeat?.cancel(); self.heartbeat = nil; self.maintenance?.cancel(); self.maintenance = nil
                self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
                self.sendTask?.cancel(); self.sendTask = nil
                try? await Task.sleep(for: .seconds(DesktopSignalRecovery.retryDelay(attempt: attempt)))
                attempt = min(4, attempt + 1)
            }
        }
    }
    func refresh() async {
        guard online, cloud?.account?.id == activeAccountID, let api = cloud?.peerClient else { return }
        let token = generation
        do {
            let peers = try await api.portsPeers()
            if generation == token {
                self.peers = peers; remember(peers); connectRequestedMapping()
            }
        } catch { if generation == token { message = L10n.text("独立端口设备列表刷新失败：\(error.localizedDescription)") } }
    }
    func connect(to peer: DesktopPeer) {
        guard online, let verified = peers.first(where: { $0.id == peer.id }),
              let api = cloud?.peerClient, let accountID = activeAccountID, cloud?.account?.id == accountID else { return }
        if let existing = sessions.first(where: { $0.peer.id == peer.id }) { selectedSessionID = existing.id; return }
        guard sessions.count < 8 else { message = L10n.text("最多同时建立 8 条独立端口连接。"); return }
        let session = makeSession(id: UUID(), peer: verified, host: false, api: api, accountID: accountID)
        sessions.append(session); selectedSessionID = session.id; session.request()
    }
    private func makeSession(id: UUID, peer: DesktopPeer, host: Bool, api: DesktopAPI, accountID: String) -> DesktopPortSession {
        mappingDrafts.removeValue(forKey: peer.id)?.close()
        let store = host ? nil : DesktopPortRuleStore(defaults: defaults, accountID: accountID, peerID: peer.id)
        let session = DesktopPortSession(id: id, peer: peer, host: host, store: store,
            configuration: { try await api.portsConfiguration() }, send: { [weak self] in self?.send($0) },
            ended: { [weak self] session, reason in
                guard let self else { return }
                self.sessions.removeAll { $0.id == session.id }
                self.sessionObservations.removeValue(forKey: session.id)
                if self.selectedSessionID == session.id { self.selectedSessionID = nil }
                if let reason { self.message = "\(session.peer.name)：\(reason)" }
            })
        session.signalHello(resume: resumeSupported, keepalive: keepaliveSupported)
        sessionObservations[id] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return session
    }
    private func receive(_ signal: DesktopSignal) async {
        guard let id = signal.id else { return }
        if let session = sessions.first(where: { $0.id == id }) { await session.receive(signal); return }
        guard signal.type == "invite", let from = signal.from else { return }
        let token = generation
        await refresh()
        guard generation == token, online, let peer = peers.first(where: { $0.id == from }),
              let api = cloud?.peerClient, let accountID = activeAccountID, cloud?.account?.id == accountID else { return }
        guard DesktopLocalSession.current.canHost, sessions.count < 8, !sessions.contains(where: { $0.peer.id == from }) else {
            send(.init(type: "reject", id: id, to: from, payload: .init(message: L10n.text("此设备已有独立端口连接或当前用户会话不可用。")))); return
        }
        let session = makeSession(id: id, peer: peer, host: true, api: api, accountID: accountID)
        remember([peer])
        sessions.append(session); session.awaitApproval()
        if autoAccept { session.accept() }
        else { NSApp.requestUserAttention(.informationalRequest) }
    }
    private func send(_ signal: DesktopSignal) {
        guard let socket, let data = try? JSONEncoder().encode(signal), let text = String(data: data, encoding: .utf8) else { return }
        let previous = sendTask, token = generation
        sendTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == token, self.socket === socket else { return }
            do { try await socket.send(.string(text)) }
            catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }
    func shutdown(reason: String? = nil) {
        for session in sessions { session.disconnect(reason) }
        sessions.removeAll(); sessionObservations.removeAll(); selectedSessionID = nil
        clearMappingDrafts()
        requestedMappingPeerID = nil
        generation = UUID(); online = false; peers = []; activeAccountID = nil
        serviceTask?.cancel(); serviceTask = nil; sendTask?.cancel(); sendTask = nil
        heartbeat?.cancel(); heartbeat = nil; maintenance?.cancel(); maintenance = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        RemoteAvailability.shared.setActive(.ports, false)
        status = reason ?? L10n.text("独立端口服务已停止")
    }
}
