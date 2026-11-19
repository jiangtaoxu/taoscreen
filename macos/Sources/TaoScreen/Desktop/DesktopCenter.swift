import AppKit
import Combine
import WebRTC

/// 独立于文件互传的桌面在线服务。默认逐次确认，可在本机为当前账号开启无人值守。
@MainActor
final class DesktopCenter: ObservableObject, Identifiable {
    static let shared = DesktopCenter(permissions: .shared)
    let isDirect: Bool
    weak var alternateHost: DesktopCenter?
    let id = UUID()
    private let viewerDefaults: UserDefaults
    private var viewerPreferencesLoaded = false
    let permissions: DesktopPermissions
    private let passwordStore: DesktopRemotePasswordStore
    private let securityInput: DesktopSecurityInput

    init(defaults: UserDefaults = DesktopRuntime.defaults, permissions: DesktopPermissions? = nil,
         passwordStore: DesktopRemotePasswordStore = .keychain, securityInput: DesktopSecurityInput? = nil,
         isDirect: Bool = false) {
        self.isDirect = isDirect
        enabled = !isDirect && DesktopRuntime.defaults.bool(forKey: "taoscreen.desktop.enabled")
        viewerDefaults = defaults
        self.permissions = permissions ?? DesktopPermissions()
        self.passwordStore = passwordStore
        self.securityInput = securityInput ?? DesktopSecurityInput()
        self.permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    // 根中心持有唯一信令连接和本机共享；每个观看会话独立持有 RTC、输入、文件与超时。
    private weak var coordinator: DesktopCenter?
    @Published private(set) var viewerSessions: [DesktopCenter] = []
    @Published private(set) var selectedViewerID: UUID?
    var selectedViewer: DesktopCenter? { viewerSessions.first { $0.id == selectedViewerID } }
    func viewer(for peerID: UUID) -> DesktopCenter? { viewerSessions.first { $0.peer?.id == peerID } }
    @Published var enabled: Bool {
        didSet {
            guard !isDirect else { return }
            DesktopRuntime.defaults.set(enabled, forKey: "taoscreen.desktop.enabled"); reconcile()
        }
    }
    @Published private(set) var online = false
    @Published private(set) var status = "未开启"
    @Published private(set) var peers: [DesktopPeer] = []
    @Published private(set) var invitation: DesktopInvitation?
    @Published private(set) var peer: DesktopPeer?
    @Published private(set) var isHost = false
    @Published private var virtualDisplay: DesktopVirtualDisplay?
    var sharedScreenName: String { virtualDisplay?.preset.title ?? "屏幕" }
    var managedVirtualDisplayID: CGDirectDisplayID? { virtualDisplay?.id ?? alternateHost?.virtualDisplay?.id }
    @Published private(set) var controlAllowed = false
    @Published private(set) var audioAllowed = false
    @Published private(set) var filesAllowed = false
    @Published private(set) var fileMessage: String?
    @Published private(set) var fileProgress: Double?
    @Published private(set) var fileReceiveMessage: String?
    @Published private(set) var fileReceiveProgress: Double?
    @Published private(set) var receivedFileFolder: URL?
    @Published private(set) var transferState: DesktopTransferState?
    @Published private(set) var dropSupported = false
    @Published var fileDragHover = false
    private let dropDelivery = DesktopDropDelivery()
    private let fileReturnPanel = DesktopFileReturnPanel()
    private var fileTransfer: DesktopFileTransfer?
    private(set) lazy var desktopWindow = DesktopSessionWindow(center: self)
    var canSendFiles: Bool { !isHost && fileTransfer?.canSend == true }
    func showDesktopWindow(sessionID: UUID? = nil) {
        if let coordinator { coordinator.showDesktopWindow(sessionID: id); return }
        if let sessionID { selectViewer(sessionID) }
        guard selectedViewer != nil else { return }
        desktopWindow.show()
    }
    func selectViewer(_ id: UUID) {
        guard viewerSessions.contains(where: { $0.id == id }) else { return }
        if selectedViewerID != id {
            desktopWindow.releaseKeyboardFocus()
            selectedViewer?.sendInput(.init(kind: "release"))
            selectedViewer?.setViewerWindowActive(false)
            selectedViewer?.setViewerPresented(false)
            selectedViewerID = id
        }
        desktopWindow.updatePresentation()
    }
    @Published private(set) var video: RTCVideoTrack?
    @Published private(set) var route = "正在协商"
    @Published private(set) var connected = false
    @Published private(set) var connectionTiming = DesktopConnectionTiming()
    @Published private(set) var relayAvailable = false
    @Published private(set) var unattended = DesktopUnattendedSettings()
    @Published private(set) var canConfigureUnattended = false
    @Published private(set) var settingsAccountID: String?
    @Published private(set) var unattendedSession = false
    var restrictedDirectSession: Bool { isDirect && unattendedSession }
    @Published private(set) var remoteScreenLocked = false
    @Published private(set) var latencyMilliseconds: Double?
    @Published private(set) var connectionAddresses = DesktopConnectionAddresses()
    @Published private(set) var remoteSecurity = DesktopRemoteSecurityViewer()
    @Published private(set) var authenticatingRemotePassword = false
    private var securityAuthentication: Task<Void, Never>?
    @Published private(set) var hasSavedRemotePassword = false
    @Published private(set) var remotePasswordMessage: String?
    private var hostSecurity = DesktopRemoteSecurityHost()
    private var securityLockTimeout: Task<Void, Never>?
    private var securityUnlockTimeout: Task<Void, Never>?
    private var lockConfirmation: Task<Void, Never>?
    @Published var message: String?
    @Published var muted = false { didSet { if muted { playback.stop() }; saveViewerPreferences() } }
    @Published var clipboardEnabled = true { didSet { saveViewerPreferences(); clipboard?.refresh() } }
    @Published private(set) var clipboardSupported = false
    private var clipboard: DesktopClipboard?
    @Published var localInputEnabled = true { didSet { saveViewerPreferences() } }
    @Published var shortcutDestination = DesktopShortcutDestination.local { didSet { saveViewerPreferences() } }
    @Published var shortcutCaptureError: String?
    @Published private(set) var remoteShortcutsActive = false
    private var viewerPresented = false
    var acceptsViewerInput: Bool {
        connected && controlAllowed && viewerControlEnabled && viewerWindowActive && coordinator?.selectedViewerID == id
    }
    @Published var cursorMode = DesktopCursorMode.local {
        didSet {
            saveViewerPreferences()
            sendCursorPreference()
        }
    }
    @Published var viewerControlEnabled = true { didSet { saveViewerPreferences(); sendCursorPreference(); clipboard?.refresh() } }
    @Published private(set) var cursorSupported = false
    @Published private(set) var remoteCursorVisible = true
    private var viewerWindowActive = false
    private var requestedCursorVisible: Bool?
    private var hostCursorVisible = true
    private var cursorUpdateTask: Task<Void, Never>?
    @Published private(set) var videoSelection = DesktopVideoSelection()
    private var videoPreferenceApplied = false
    private var videoRequestTimeout: Task<Void, Never>?
    private var hostVideoPreset = DesktopVideoPreset.ultra
    private var hostVideoRequestID: UUID?
    private var videoUpdateTask: Task<Void, Never>?
    lazy var portService = DesktopPortService(defaults: viewerDefaults)

    lazy var privacyLibrary: DesktopPrivacyLibrary = {
        let library = DesktopPrivacyLibrary()
        library.onChange = { [weak self] in
            guard let self, self.isHost, self.privacyRequested else { return }
            self.refreshPrivacy()
        }
        return library
    }()
    private lazy var privacyCurtain: DesktopPrivacyCurtain = {
        let curtain = DesktopPrivacyCurtain()
        curtain.onEmergencyExit = { [weak self] in self?.setHostPrivacy(false) }
        return curtain
    }()
    @Published private(set) var privacyRequested = false
    @Published private(set) var privacyActive = false
    @Published private(set) var privacyChanging = false
    @Published private(set) var privacySupported = false
    @Published private(set) var privacyStateKnown = true
    private var privacyRequestTimeout: Task<Void, Never>?

    var privacyPausedForLock: Bool { privacyRequested && (isHost ? localSession.locked : remoteScreenLocked) }

    var privacyStatusText: String {
        if privacyChanging { return "正在切换隐私屏…" }
        if !privacyStateKnown { return "隐私屏状态未确认，请重新切换或在被控端检查。" }
        if privacyPausedForLock { return "锁屏期间暂停隐私屏，解锁后恢复。" }
        if privacyActive { return "隐私屏已开启 · 本机键鼠仍可使用 · ⌃⌥⇧Esc 退出" }
        return "隐私屏未开启 · 本机键鼠仍可使用 · 启用后可按 ⌃⌥⇧Esc 退出"
    }

    func setHostPrivacy(_ enabled: Bool) {
        guard isHost, sessionID != nil else { return }
        privacyRequested = enabled
        if !enabled { privacyCurtain.stop(); privacyActive = false }
        refreshPrivacy()
    }

    func requestPrivacy(_ enabled: Bool) {
        guard !isHost, connected, controlAllowed, privacySupported, !privacyChanging,
              let id = sessionID, rtc?.sendPrivacy(.init(action: .request, enabled: enabled)) == true else { return }
        privacyChanging = true
        privacyStateKnown = false
        privacyRequestTimeout?.cancel()
        privacyRequestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.sessionID == id else { return }
            self.privacyChanging = false
            self.privacyStateKnown = false
            self.message = "尚未收到隐私屏切换结果，请检查被控端状态后重试。"
        }
    }

    private func sendPrivacyStatus(failure: String? = nil) {
        guard isHost else { return }
        rtc?.sendPrivacy(.init(action: .status, enabled: privacyRequested, active: privacyActive,
                               changing: privacyChanging, failure: failure))
    }

    func receivePrivacy(_ value: DesktopPrivacyMessage) {
        guard value.isValid, sessionID != nil else { return }
        if isHost, value.action == .request {
            guard controlAllowed else { sendPrivacyStatus(failure: "仅观看连接不能切换隐私屏。"); return }
            setHostPrivacy(value.enabled)
        } else if !isHost, value.action == .status {
            privacySupported = true; privacyRequested = value.enabled
            privacyStateKnown = true
            privacyActive = value.active; privacyChanging = value.changing
            if !value.changing { privacyRequestTimeout?.cancel(); privacyRequestTimeout = nil }
            if let failure = value.failure { message = failure }
        }
    }

    private func preparePrivacyCurtain() throws {
        guard privacyRequested, !localSession.locked else { privacyCurtain.stop(); privacyActive = false; return }
        let image = privacyLibrary.selectedImage.flatMap { privacyLibrary.image($0) }
        if privacyLibrary.selectedImage != nil && image == nil {
            message = "隐私屏图片无法读取，已改用深灰提示屏。"
        }
        try privacyCurtain.show(preset: privacyLibrary.preset, image: image)
    }

    private func refreshPrivacy() {
        guard isHost, sessionID != nil else { return }
        do {
            try preparePrivacyCurtain()
            // 先覆盖新接入的实体屏幕，再串行重建采集排除列表。
            if connected {
                privacyChanging = true; sendPrivacyStatus()
                restartCapture(reason: "privacy-changed")
            } else { sendPrivacyStatus() }
        } catch { disconnect("无法启用隐私屏：\(error.localizedDescription)") }
    }

    private weak var cloud: DesktopAccountState?
    private var observations: Set<AnyCancellable> = []
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sessionSuspended = false
    private var localSession = DesktopLocalSession.current
    private let displayActivity = DesktopDisplayActivity()
    private var captureRestartTask: Task<Void, Never>?
    private var captureGeneration = UUID()
    private var captureRecovery = DesktopCaptureRecovery()
    private var accountID: String?
    private struct DirectConnection {
        let id: UUID
        let send: (DesktopSignal) -> Void
        let finish: () -> Void
        let remember: (() -> Bool)?
        let authorizedGrant: (() -> DesktopTrustedGrant?)?
    }
    private var directConnection: DirectConnection?
    var canRememberDirectDevice: Bool { directConnection?.remember != nil }
    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var serviceTask: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var disconnectTimeout: Task<Void, Never>?
    private var configuration: DesktopConfiguration?
    private var rtc: DesktopRTC?
    private var capture: DesktopCapture?
    private let input = DesktopInputReceiver()
    private let playback = DesktopAudioPlayback()
    private(set) var sessionID: UUID?
    private var generation = UUID()
    private var lastHeartbeat: TimeInterval = 0
    private var heartbeatTask: Task<Void, Never>?
    private var signalRecovery = DesktopSignalRecovery()
    private var signalRecoveryTask: Task<Void, Never>?
    private var supportsSignalResume = false
    private var supportsSessionKeepalive = false
    private(set) var sessionEstablished = false
    private var pendingCandidates: [DesktopSignal] = []
    @Published private(set) var signalRecovering = false

    func attach(cloud: DesktopAccountState) {
        guard self.cloud == nil else { return }
        self.cloud = cloud
        portService.attach(cloud: cloud)
        cloud.$account.combineLatest(cloud.$needsLogin).sink { [weak self] _, _ in
            Task { @MainActor in self?.reconcile() }
        }.store(in: &observations)
        observeLocalSession()
        reconcile()
    }

    func observeLocalSession() {
        guard lockObserver == nil else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.permissions.refresh() }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.suspendSharing("电脑进入睡眠，共享已停止。") } }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.localSessionChanged() } }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in
                guard let self else { return }
                self.sessionSuspended = false; self.shutdown()
                if !self.isDirect { self.reconcile() }
            } }.store(in: &observations)
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.localSessionChanged(locked: true) }
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.localSessionChanged(locked: false) }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.localSessionChanged() } }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, self.isHost else { return }
                if self.capture != nil, self.virtualDisplay?.isExtended == false {
                    self.endVirtualDisplaySharing("虚拟屏已断开或进入镜像模式，共享已停止。")
                } else if self.privacyRequested {
                    self.refreshPrivacy()
                }
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.privacyCurtain.stop() }.store(in: &observations)
    }

    private func suspendSharing(_ reason: String) {
        sessionSuspended = true
        disconnectAll(reason)
    }

    private var localSessionAvailable: Bool {
        !sessionSuspended && DesktopLocalSession.current.canHost
    }

    private func localSessionChanged(locked: Bool? = nil) {
        // 锁屏通知到达时 CGSession 字典可能仍反映上一次状态，通知本身决定锁定标记。
        let snapshot = DesktopLocalSession.current
        let next = locked.map { snapshot.withLockState($0) } ?? snapshot
        guard next != localSession else { return }
        localSession = next
        DesktopSessionLog.record("local-session console=\(next.onConsole) loggedIn=\(next.loggedIn) locked=\(next.locked) host=\(isHost)")
        guard next.canHost else {
            disconnectAll("当前用户会话已离开，共享已停止。")
            return
        }
        guard !sessionSuspended else { return }
        // 切换界面前释放拖动和修饰键，避免将按住状态带入密码输入框。
        if isHost {
            input.releaseAll()
            if next.locked { fileTransfer?.cancelSending() }
            refreshFileReturn()
            if next.locked { privacyCurtain.stop(); privacyActive = false }
            privacyChanging = privacyRequested
            sendPrivacyStatus()
            captureRecovery.sessionChanged()
            dropDelivery.invalidate()
            sendHostSessionStatus()
            restartCapture(reason: next.locked ? "screen-locked" : "screen-unlocked")
        } else {
            sendInput(.init(kind: "release"))
        }
        for viewer in viewerSessions { viewer.sendInput(.init(kind: "release")) }
    }

    private func makeCapture(id: UUID, rtc: DesktopRTC) -> DesktopCapture {
        let capture = DesktopCapture(source: rtc.source)
        capture.audio = { [weak self, weak capture] data in
            guard let self, let capture, self.sessionID == id, self.capture === capture else { return }
            self.rtc?.sendAudio(data)
        }

        capture.failed = { [weak self, weak capture] error in
            Task { @MainActor in
                guard let self, let capture, self.sessionID == id, self.capture === capture else { return }
                DesktopSessionLog.record("capture-stopped domain=\(error.domain) code=\(error.code)")
                if self.reportCapturePermissionFailure(error) { return }
                if self.connected, self.localSessionAvailable, self.captureRecovery.consume(error) {
                    self.restartCapture(reason: "system-stopped-stream")
                } else {
                    let reason = "屏幕采集已停止：\(error.localizedDescription)"
                    if self.virtualDisplay != nil { self.endVirtualDisplaySharing(reason) }
                    else { self.disconnect(reason) }
                }
            }
        }
        return capture
    }

    private func restartCapture(reason: String) {
        guard isHost, connected, let id = sessionID, let rtc, localSessionAvailable else { return }
        let previous = captureRestartTask
        let videoUpdate = videoUpdateTask
        previous?.cancel()
        let token = UUID(); captureGeneration = token
        captureRestartTask = Task { [weak self] in
            // 同一连接的重建串行执行，旧 stop/start 不得覆盖新采集。
            await previous?.value
            await videoUpdate?.value
            guard let self, !Task.isCancelled, self.sessionID == id, self.captureGeneration == token else { return }
            let old = self.capture; self.capture = nil
            await old?.stop()
            guard !Task.isCancelled, self.sessionID == id, self.captureGeneration == token else { return }
            do {
                try self.checkVirtualDisplay()
                try self.displayActivity.start()
                try self.preparePrivacyCurtain()
                let capture = self.makeCapture(id: id, rtc: rtc)
                self.capture = capture
                try await capture.start(displayID: self.input.displayID, sound: self.audioAllowed,
                                        showsCursor: self.hostCursorVisible, excludingWindowIDs: self.privacyCurtain.windowIDs,
                                        preset: self.hostVideoPreset)
                guard !Task.isCancelled, self.sessionID == id, self.captureGeneration == token else {
                    await capture.stop(); return
                }
                try self.checkVirtualDisplay()
                DesktopSessionLog.record("capture-restarted reason=\(reason)")
                self.privacyActive = self.privacyRequested && !self.localSession.locked
                self.privacyChanging = false; self.sendPrivacyStatus()
                self.updateHostCursor()
                self.sendVideoStatus()
            } catch {
                guard !Task.isCancelled, self.sessionID == id, self.captureGeneration == token else { return }
                let reason = "无法恢复屏幕采集：\(error.localizedDescription)"
                if self.virtualDisplay != nil { self.endVirtualDisplaySharing(reason) }
                else { self.disconnect(reason) }
            }
        }
    }

    /// 仅本机设置入口调用。自动接受时只检查权限，不唤起系统授权弹窗。
    @discardableResult
    func updateUnattended(_ settings: DesktopUnattendedSettings, for accountID: String?) -> Bool {
        guard let account = cloud?.account, cloud?.peerClient != nil, account.id == settingsAccountID, account.id == accountID else { return false }
        if settings.enabled, !checkPermissions(control: settings.control, prompt: true) { return false }
        // 系统权限弹窗可能运行嵌套事件循环，返回后再次确认账号没有切换。
        guard cloud?.account?.id == account.id, cloud?.peerClient != nil, settingsAccountID == account.id else { return false }
        if unattendedSession, settings != unattended { disconnect("无人值守设置已更改，共享已停止。") }
        unattended = settings
        settings.save(accountID: account.id, defaults: DesktopRuntime.defaults)
        message = nil
        return true
    }

    private func checkPermissions(control: Bool, prompt: Bool) -> Bool {
        permissions.check(control: control, prompt: prompt)
    }

    private func reportCapturePermissionFailure(_ error: Error) -> Bool {
        guard DesktopPermissions.isCapturePermissionError(error), let id = sessionID, let peer else { return false }
        permissions.recordCaptureDenial()
        permissions.remind(requester: peer.name, control: controlAllowed)
        let reason = permissions.snapshot.rejectionMessage(control: controlAllowed)
        send(.init(type: "end", id: id, to: peer.id, payload: .init(message: reason)))
        disconnect(notify: false)
        NSApp.requestUserAttention(.informationalRequest)
        return true
    }

    func restartForPermissions() {
        do {
            let process = try DesktopPermissionRelaunch.process(app: Bundle.main.bundleURL, pid: ProcessInfo.processInfo.processIdentifier)
            try process.run()
            DesktopPermissionRelaunch.prepareForTermination(windows: NSApp.windows)
            shutdown()
            status = "正在重启 TaoScreen…"
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } catch { message = "无法重启 TaoScreen：\(error.localizedDescription)。请退出后从“应用程序”重新打开。" }
    }

    private func reconcile() {
        let settingsAccount = cloud?.peerClient != nil ? cloud?.account?.id : nil
        canConfigureUnattended = settingsAccount != nil
        if settingsAccountID != settingsAccount {
            settingsAccountID = settingsAccount
            unattended = .load(accountID: settingsAccount, defaults: DesktopRuntime.defaults)
        }
        let next = enabled ? settingsAccount : nil
        if next == accountID, serviceTask != nil { return }
        shutdown()
        guard let next, let api = cloud?.peerClient else {
            status = enabled ? "请先登录 TaoScreen 账户" : "未开启"; return
        }
        accountID = next
        RemoteAvailability.shared.setActive(.desktop, true)
        let token = generation
        serviceTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, self.generation == token {
                var attemptedSocket: URLSessionWebSocketTask?
                var openedAt: TimeInterval?
                var permanentFailure = false
                do {
                    self.status = self.signalRecovering ? "正在恢复桌面信令…" : "正在连接服务…"
                    self.configuration = try await api.desktopConfiguration()
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.relayAvailable = self.configuration?.relayAvailable == true
                    var request = try await api.desktopRequest()
                    request.timeoutInterval = 15
                    guard self.generation == token, !Task.isCancelled else { return }
                    let socket = self.session.webSocketTask(with: request)
                    attemptedSocket = socket
                    socket.maximumMessageSize = 64 * 1024
                    self.socket = socket
                    self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                    socket.resume()
                    // 心跳检测不等待 HTTP 设备列表请求，慢请求不能阻塞断线检测。
                    self.heartbeatTask = Task { [weak self, weak socket] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            guard let self, let socket, !Task.isCancelled,
                                  self.generation == token, self.socket === socket else { return }
                            if ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 70 {
                                DesktopSessionLog.record("signal-heartbeat-timeout task=\(socket.taskIdentifier)")
                                socket.cancel(with: .goingAway, reason: nil)
                                return
                            }
                        }
                    }
                    self.maintenance = Task { [weak self, weak socket] in
                        while !Task.isCancelled {
                            guard let self, let socket, self.generation == token, self.socket === socket else { return }
                            await self.refresh()
                            try? await Task.sleep(for: .seconds(10))
                        }
                    }
                    while !Task.isCancelled, self.generation == token, self.socket === socket {
                        let value = try await socket.receive()
                        guard self.generation == token, !Task.isCancelled, self.socket === socket else { return }
                        let data: Data
                        switch value { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                        guard data.count <= 64 * 1024 else { throw CloudError("桌面信令过大。") }
                        let signal = try JSONDecoder().decode(DesktopSignal.self, from: data)
                        self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                        if signal.type == "hello" { openedAt = self.lastHeartbeat }
                        if signal.type == "session_revoked" {
                            self.cloud?.requireLogin(DesktopSignalFailure.authentication.message)
                            return
                        }
                        await self.receive(signal)
                    }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    let httpStatus = (attemptedSocket?.response as? HTTPURLResponse)?.statusCode ?? (error as? CloudHTTPError)?.statusCode
                    let closeCode = attemptedSocket?.closeCode.rawValue
                    let failure = DesktopSignalFailure.classify(error, httpStatus: httpStatus, closeCode: closeCode)
                    if failure == .authentication {
                        self.cloud?.requireLogin(failure.message)
                        return
                    }
                    let nsError = error as NSError
                    DesktopSessionLog.record("signal-failed task=\(attemptedSocket?.taskIdentifier ?? -1) http=\(httpStatus ?? 0) close=\(closeCode ?? 0) domain=\(nsError.domain) code=\(nsError.code) recovery=\(self.signalRecovery.isRecovering)")
                    permanentFailure = failure.endsSession
                    self.status = failure.message
                    if permanentFailure || !self.beginSignalRecovery() {
                        if self.sessionID != nil || self.invitation != nil {
                            self.disconnect(failure.endsSession ? failure.message : "信令连接中断，当前连接无法恢复，请重新连接。", notify: false)
                        }
                    }
                    for viewer in self.viewerSessions {
                        if permanentFailure || !viewer.beginSignalRecovery() {
                            viewer.disconnect(failure.endsSession ? failure.message : "信令连接中断，请重新连接。", notify: false)
                        }
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.online = false; self.peers = []
                for viewer in self.viewerSessions { viewer.online = false }
                self.maintenance?.cancel(); self.maintenance = nil
                self.heartbeatTask?.cancel(); self.heartbeatTask = nil
                self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
                self.sendTask?.cancel(); self.sendTask = nil
                if permanentFailure { self.serviceTask = nil; return }
                if let openedAt, ProcessInfo.processInfo.systemUptime - openedAt >= 25 { attempt = 0 }
                let delay = DesktopSignalRecovery.retryDelay(attempt: attempt)
                attempt = min(4, attempt + 1)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func beginSignalRecovery() -> Bool {
        guard supportsSignalResume, sessionID != nil, sessionEstablished, rtc != nil else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard signalRecovery.begin(now: now) else { return false }
        signalRecovering = true
        if signalRecoveryTask == nil {
            let id = sessionID, recoveryToken = signalRecovery.token
            let remaining = max(0, (signalRecovery.deadline ?? now) - now)
            DesktopSessionLog.record("signal-recovery-start seconds=\(remaining)")
            signalRecoveryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self, self.sessionID == id,
                      self.signalRecovery.token == recoveryToken else { return }
                self.disconnect("信令在一分钟内未能恢复，桌面共享已停止，请重新连接。", notify: false)
            }
        }
        return true
    }

    func refresh() async {
        guard enabled, let api = cloud?.peerClient else { return }
        let token = generation
        do {
            let peers = try await api.desktopPeers()
            guard generation == token else { return }
            self.peers = peers
        } catch { /* 在线服务循环负责显示连接错误；单次刷新失败不清空当前会话。 */ }
    }

    func connect(to peer: DesktopPeer) {
        guard coordinator == nil, online, invitation == nil else { return }
        if let existing = viewer(for: peer.id) { showDesktopWindow(sessionID: existing.id); return }
        let viewer = prepareViewer(for: peer)
        showDesktopWindow(sessionID: viewer.id)
        guard let connectionID = viewer.sessionID else { return }
        viewer.send(.init(type: "invite", id: connectionID, to: peer.id))
        viewer.armTimeout(connectionID, seconds: 60, message: "对方未在一分钟内响应连接请求。")
    }

    /// 先登记会话，随后由 connect 打开窗口、发送邀请；所有观看会话共享根中心的信令通道。
    func prepareViewer(for peer: DesktopPeer) -> DesktopCenter {
        if let existing = viewer(for: peer.id) { return existing }
        let viewer = DesktopCenter(defaults: viewerDefaults, permissions: permissions, passwordStore: passwordStore,
                                   securityInput: securityInput, isDirect: isDirect)
        viewer.coordinator = self; viewer.cloud = cloud; viewer.accountID = accountID ?? cloud?.account?.id
        viewer.online = online; viewer.supportsSignalResume = supportsSignalResume
        viewer.supportsSessionKeepalive = supportsSessionKeepalive
        viewer.sessionID = UUID(); viewer.peer = peer; viewer.route = "正在请求连接"
        viewer.restoreViewerPreferences()
        viewerSessions.append(viewer)
        return viewer
    }

    func openDirectConnection(id: UUID, peer: DesktopPeer, incoming: Bool, showWindow: Bool = true,
                              trusted: Bool = false, remember: (() -> Bool)? = nil,
                              authorizedGrant: (() -> DesktopTrustedGrant?)? = nil,
                              send: @escaping (DesktopSignal) -> Void, finish: @escaping () -> Void) -> Bool {
        guard isDirect, directConnection == nil, localSessionAvailable else { return false }
        if incoming {
            guard availableForInvitation, DesktopLocalSession.current.canStart(unattended: trusted),
                  !trusted || authorizedGrant?() != nil else { return false }
        }
        directConnection = .init(id: id, send: send, finish: finish, remember: remember, authorizedGrant: authorizedGrant)
        online = true
        RemoteAvailability.shared.setActive(.direct, true)
        message = nil
        if incoming {
            let request = DesktopInvitation(id: id, peer: peer)
            if trusted {
                Task { [weak self] in await self?.acceptTrustedDirect(request) }
            } else { presentInvitation(request) }
        } else {
            let viewer = prepareViewer(for: peer)
            viewer.sessionID = id
            viewer.unattendedSession = trusted
            if showWindow { showDesktopWindow(sessionID: viewer.id) }
            viewer.armTimeout(id, seconds: 60, message: trusted ? "对方未能启动无人值守共享。" : "对方未在一分钟内确认免登录连接。")
        }
        return true
    }

    private func acceptTrustedDirect(_ request: DesktopInvitation) async {
        guard let connection = directConnection, connection.id == request.id else { return }
        guard let grant = connection.authorizedGrant?() else {
            send(.init(type: "reject", id: request.id, to: request.peer.id,
                       payload: .init(message: "无人值守授权已失效，请在被控 Mac 检查。")))
            finishDirectConnection()
            return
        }
        guard checkPermissions(control: grant.control, prompt: false) else {
            permissions.remind(requester: request.peer.name, control: grant.control)
            NSApp?.requestUserAttention(.informationalRequest)
            let missing = permissions.snapshot.missing(control: grant.control)
            let base = permissions.snapshot.rejectionMessage(control: grant.control)
                ?? "无人值守授权或 macOS 屏幕录制、辅助功能权限不可用，请在被控 Mac 检查。"
            let reason = missing.contains(.screenRecording)
                ? "\(base)（请确认系统设置中的屏幕录制权限已勾选并重启 TaoScreen）"
                : base
            send(.init(type: "reject", id: request.id, to: request.peer.id,
                       payload: .init(message: reason)))
            finishDirectConnection()
            return
        }
        await startSharing(request, display: grant.shareDisplay, control: grant.control, audio: grant.audio, unattended: true)
    }

    func directConnectionClosed(id: UUID, reason: String?) {
        guard directConnection?.id == id else { return }
        disconnectAll(reason, notify: false)
    }

    private func finishDirectConnection() {
        guard let link = directConnection else { return }
        directConnection = nil
        online = false
        RemoteAvailability.shared.setActive(.direct, false)
        link.finish()
    }

    private var availableForInvitation: Bool {
        sessionID == nil && invitation == nil && alternateHost?.invitation == nil && alternateHost?.isHost != true
    }

    private func restoreViewerPreferences() {
        guard let peer else { return }
        viewerPreferencesLoaded = false
        let preferences = DesktopViewerPreferences.load(accountID: accountID, peerID: peer.id, defaults: viewerDefaults)
        viewerControlEnabled = preferences.viewerControlEnabled
        shortcutDestination = preferences.shortcutDestination
        clipboardEnabled = preferences.clipboardEnabled
        muted = preferences.muted
        cursorMode = preferences.cursorMode
        localInputEnabled = preferences.localInputEnabled ?? true
        videoSelection.preference = preferences.videoPreset ?? .ultra
        remoteSecurity.preference = preferences.lockRemoteOnDisconnect == true
        refreshRemotePasswordAvailability()
        viewerPreferencesLoaded = true
    }

    private func saveViewerPreferences() {
        guard viewerPreferencesLoaded, coordinator != nil, !isHost, sessionID != nil,
              let accountID, let peer else { return }
        DesktopViewerPreferences(viewerControlEnabled: viewerControlEnabled, shortcutDestination: shortcutDestination,
                                 clipboardEnabled: clipboardEnabled, muted: muted, cursorMode: cursorMode,
                                 localInputEnabled: localInputEnabled ? nil : false,
                                 videoPreset: videoSelection.preference == .ultra ? nil : videoSelection.preference,
                                 lockRemoteOnDisconnect: remoteSecurity.preference ? true : nil)
            .save(accountID: accountID, peerID: peer.id, defaults: viewerDefaults)
    }

    func reject(reason: String? = nil) {
        guard let invitation else { return }
        send(.init(type: "reject", id: invitation.id, to: invitation.peer.id, payload: reason.map { .init(message: $0) }))
        self.invitation = nil; timeout?.cancel()
        if isDirect { finishDirectConnection() }
    }

    func accept(display: DesktopShareDisplay, control: Bool, audio: Bool, rememberDirectDevice: Bool = false) async {
        guard let invitation, sessionID == nil, online else { return }
        guard checkPermissions(control: control, prompt: true) else {
            permissions.remind(requester: invitation.peer.name, control: control)
            reject(reason: permissions.snapshot.rejectionMessage(control: control)); return
        }
        guard self.invitation?.id == invitation.id else { return }
        await startSharing(invitation, display: display, control: control, audio: audio, unattended: false,
                           rememberDirectDevice: rememberDirectDevice)
    }

    private func startSharing(_ invitation: DesktopInvitation, display: DesktopShareDisplay, control: Bool, audio: Bool,
                              unattended: Bool, rememberDirectDevice: Bool = false) async {
        let grant = isDirect && unattended ? directConnection?.authorizedGrant?() : nil
        let authorized = isDirect ? (directConnection?.id == invitation.id && (!unattended ||
            (grant?.shareDisplay == display && grant?.control == control && grant?.audio == audio)))
            : (enabled && cloud?.peerClient != nil && cloud?.account?.id == accountID)
        guard sessionID == nil, online, authorized, alternateHost?.isHost != true, localSessionAvailable,
              DesktopLocalSession.current.canStart(unattended: unattended) else {
            if self.invitation?.id == invitation.id { reject() }
            else {
                send(.init(type: "reject", id: invitation.id, to: invitation.peer.id))
                if isDirect, directConnection?.id == invitation.id { finishDirectConnection() }
            }
            return
        }
        let id = invitation.id
        permissions.clearReminder()
        sessionID = id; peer = invitation.peer; self.invitation = nil; isHost = true
        unattendedSession = unattended
        controlAllowed = control; audioAllowed = audio; route = "正在准备共享"; message = nil
        hostVideoPreset = .ultra
        privacyRequested = privacyLibrary.settings.automatic
        privacyChanging = privacyRequested
        armTimeout(id, seconds: 45, message: "桌面连接超时。")
        do {
            localSession = .current
            let displayID: CGDirectDisplayID
            switch display {
            case .main:
                displayID = CGMainDisplayID()
            case let .fixed(selectedID):
                displayID = selectedID
            case let .virtual(preset):
                try displayActivity.start()
                let created = try DesktopVirtualDisplay(preset: preset)
                virtualDisplay = created
                displayID = created.id
            }
            if let preset = display.virtualPreset {
                try await DesktopVirtualDisplay.waitUntilReady(displayID, preset: preset) { self.sessionID == id }
                guard sessionID == id else { return }
            }
            input.displayID = displayID; input.enabled = control
            try preparePrivacyCurtain()
            if virtualDisplay == nil { try displayActivity.start() }
            captureRecovery = DesktopCaptureRecovery()
            try await prepareRTC(id: id, host: true)
            guard sessionID == id, let rtc else { return }
            try checkVirtualDisplay()
            let capture = makeCapture(id: id, rtc: rtc)
            self.capture = capture
            try await capture.start(displayID: displayID, sound: audio, excludingWindowIDs: privacyCurtain.windowIDs,
                                    preset: hostVideoPreset)
            guard sessionID == id else { await capture.stop(); return }
            try checkVirtualDisplay()
            privacyActive = privacyRequested && !localSession.locked
            privacyChanging = false
            let paired = isDirect && !unattended && rememberDirectDevice && directConnection?.remember?() == true
            send(.init(type: "accept", id: id, to: peer?.id,
                       payload: .init(control: control, audio: audio, files: control && !restrictedDirectSession, paired: paired ? true : nil)))
        } catch {
            guard sessionID == id else { return }
            if !reportCapturePermissionFailure(error) {
                if display.virtualPreset != nil { endVirtualDisplaySharing(error.localizedDescription) }
                else { disconnect(error.localizedDescription) }
            }
        }
    }

    private func checkVirtualDisplay() throws {
        if virtualDisplay?.isExtended == false {
            throw CloudError("虚拟屏已断开或进入镜像模式。")
        }
    }

    private func endVirtualDisplaySharing(_ reason: String) {
        if let id = sessionID, let peer {
            send(.init(type: "end", id: id, to: peer.id, payload: .init(message: reason)))
        }
        disconnect(reason, notify: false)
    }

    private func prepareRTC(id: UUID, host: Bool) async throws {
        let config: DesktopConfiguration
        if isDirect {
            config = .init(iceServers: [], relayAvailable: false)
        } else {
            guard let api = cloud?.peerClient else { throw CloudError("请重新登录。") }
            // 每个账号会话重新获取短期 TURN 凭据。
            config = try await api.desktopConfiguration()
        }
        guard sessionID == id else { throw CancellationError() }
        let rtc = try DesktopRTC(configuration: config, host: host)
        self.rtc = rtc
        let files = DesktopFileTransfer(host: host,
            root: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("TaoScreen", isDirectory: true),
            dropRoot: host ? DesktopDropStorage.root : nil,
            allowed: { [weak self] in
                guard let self else { return false }
                return self.sessionID == id && self.connected && self.controlAllowed && !self.restrictedDirectSession
                    && (host ? self.localSessionAvailable : self.filesAllowed)
            }, send: { [weak rtc] in rtc?.sendFile($0) == true })
        fileTransfer = files
        files.onState = { [weak self] state in
            guard let self, self.sessionID == id else { return }
            self.transferState = state
            if host { self.fileReturnPanel.updateTransfer(state) }
        }
        if host {
            files.onPrepareDrop = { [weak self] point in
                guard let self, self.sessionID == id else { return }
                await self.dropDelivery.prepare(point, input: self.input, allowed: {
                    self.sessionID == id && self.connected && self.controlAllowed && self.localSessionAvailable && !self.localSession.locked
                })
            }
            files.onDeliverDrop = { [weak self] urls in
                guard let self else { return .init(message: "连接已结束，文件未投放。", warning: true, paths: urls.map(\.path)) }
                return await self.dropDelivery.deliver(urls, input: self.input, allowed: {
                    self.sessionID == id && self.connected && self.controlAllowed && self.localSessionAvailable && !self.localSession.locked
                })
            }
            files.onCancelDrop = { [weak self] in self?.dropDelivery.invalidate() }
            files.onDropDescription = { [weak self] in self?.dropDelivery.summary ?? "文件将保存在远端暂存目录。" }
        }
        files.onStatus = { [weak self] message, progress in
            guard self?.sessionID == id else { return }
            self?.fileMessage = message; self?.fileProgress = progress
        }
        files.onReceiveStatus = { [weak self] message, progress in
            guard let self, self.sessionID == id else { return }
            self.fileReceiveMessage = message; self.fileReceiveProgress = progress
            self.receivedFileFolder = nil
        }
        files.onFiles = { [weak self] urls, paste in
            guard let self, self.sessionID == id, self.controlAllowed else { return }
            guard host else {
                self.receivedFileFolder = urls.first?.deletingLastPathComponent()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
            self.clipboard?.didWriteSharedClipboard()
            if paste {
                self.input.receive(.init(kind: "release"))
                self.input.receive(.init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue))
                self.input.receive(.init(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue))
            }
        }
        rtc.onFile = { [weak files] in files?.receive($0) }
        rtc.onSignal = { [weak self] type, payload in
            guard let self, self.sessionID == id else { return }
            self.send(.init(type: type, id: id, to: self.peer?.id, payload: payload))
        }
        rtc.onVideo = { [weak self] track in
            guard let self, self.sessionID == id, !host else { return }
            track.isEnabled = self.viewerPresented; self.video = track
        }
        rtc.onInput = { [weak self] value in
            guard let self, self.sessionID == id, host, self.localSessionAvailable else { return }
            // The native drag owns mouse state until its completion callback.
            // Pointer motion from the viewer must not move that drag elsewhere.
            if self.dropDelivery.isDelivering {
                if value.kind != "move" { self.dropDelivery.invalidate() }
                return
            }
            if ["button", "key", "clipboard", "scroll"].contains(value.kind) { self.dropDelivery.invalidate() }
            if self.restrictedDirectSession, value.kind == "clipboard", value.transient != true { return }
            if value.kind == "clipboard", value.transient == true, self.clipboard?.beforeTransientWrite() == false { return }
            if value.kind == "key", self.clipboard?.beforeKey(value) == false { return }
            self.input.receive(value)
            if value.kind == "clipboard" {
                if value.transient == true { self.clipboard?.didWriteClipboard() }
                else { self.clipboard?.didWriteSharedClipboard() }
            }
        }
        let clipboard = DesktopClipboard(host: host, allowed: { [weak self] in
            guard let self, self.sessionID == id, self.connected, self.controlAllowed, !self.restrictedDirectSession else { return false }
            if host { return self.localSessionAvailable && !self.localSession.locked }
            let local = DesktopLocalSession.current
            return self.acceptsViewerInput && self.viewerPresented && self.clipboardEnabled && !self.remoteScreenLocked
                && local.canHost && !local.locked
        }, transientAllowed: { [weak self] in
            guard let self, host, self.sessionID == id, self.connected, self.controlAllowed else { return false }
            return self.localSessionAvailable && !self.localSession.locked
        }, send: { [weak rtc] in rtc?.sendClipboard($0) == true }, paste: { [weak self] in
            guard let self, self.sessionID == id else { return }
            if host {
                self.input.receive(.init(kind: "release"))
                self.input.receive(.init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue))
                self.input.receive(.init(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue))
            } else { self.pasteRemoteClipboard() }
        }, pasteFiles: { [weak self] in self?.sendFiles($0, paste: true) }, failure: { [weak self] in self?.message = $0 })
        self.clipboard = clipboard
        clipboard.onSupport = { [weak self] in self?.clipboardSupported = true }
        rtc.onClipboard = { [weak self, weak clipboard] value in
            guard let self, self.sessionID == id, !self.restrictedDirectSession else { return }
            if host, value.action == .write || value.action == .paste {
                let delivering = self.dropDelivery.isDelivering
                self.dropDelivery.invalidate()
                if delivering { return }
            }
            clipboard?.receive(value)
        }
        rtc.onControlOpen = { [weak self, weak rtc] in
            guard let self, self.sessionID == id else { return }
            if !self.restrictedDirectSession { self.clipboard?.open() }
            guard host else { return }
            self.sendHostSessionStatus()
            rtc?.sendCursor(.init(action: .status, showsCursor: self.capture?.showsCursor ?? true))
            self.sendPrivacyStatus()
            self.sendVideoStatus()
            if !self.isDirect { rtc?.sendSecurity(.init(action: .status, lockOnDisconnect: self.hostSecurity.lockOnDisconnect)) }
        }
        rtc.onSecurity = { [weak self] value in
            guard self?.sessionID == id else { return }; self?.receiveRemoteSecurity(value)
        }
        rtc.onVideoSettings = { [weak self] value in
            guard self?.sessionID == id else { return }
            self?.receiveVideoSettings(value)
        }
        rtc.onPrivacy = { [weak self] value in
            guard self?.sessionID == id else { return }
            self?.receivePrivacy(value)
        }
        rtc.onCursor = { [weak self] value in
            guard let self, self.sessionID == id else { return }
            if host, value.action == .request {
                self.hostCursorVisible = !self.controlAllowed || value.showsCursor
                self.updateHostCursor()
            } else if !host, value.action == .status {
                self.cursorSupported = true
                self.remoteCursorVisible = value.showsCursor
                if value.failed { self.message = "光标显示切换失败，已保留原来的显示方式。可切换光标选项重试。" }
                self.sendCursorPreference()
            }
        }
        rtc.onSessionStatus = { [weak self, weak rtc] value in
            guard let self, self.sessionID == id else { return }
            self.fileTransfer?.supportsDirectories = value.fileDirectories == true
            if host {
                self.fileTransfer?.reverseEnabled = value.fileReturn == true
                self.refreshFileReturn()
                return
            }
            self.remoteScreenLocked = value.locked
            if !value.locked { self.remoteSecurity.confirmUnlocked() }
            self.clipboard?.refresh()
            self.dropSupported = value.fileDrop == true
            if value.fileReturn == true, self.controlAllowed, self.filesAllowed {
                self.fileTransfer?.reverseEnabled = true
                rtc?.sendSessionStatus(.init(locked: false, fileDirectories: true, fileReturn: true))
            }
        }
        input.systemObserver.onTrace = { [weak self, weak rtc] value in
            guard self?.sessionID == id, host else { return }; rtc?.sendInputTrace(value)
        }
        rtc.onInputTrace = { [weak self] value in
            guard self?.sessionID == id, !host else { return }; DesktopInputDiagnostics.trace(value, remote: true)
        }
        rtc.onAudio = { [weak self] data in
            guard let self, self.sessionID == id, !host, self.audioAllowed, !self.muted, self.viewerPresented else { return }
            self.playback.play(data)
        }
        rtc.onLatency = { [weak self] value in
            guard self?.sessionID == id else { return }; self?.latencyMilliseconds = value
        }
        rtc.onConnectionAddresses = { [weak self] value in self?.receiveConnectionAddresses(value, id: id) }
        rtc.onRoute = { [weak self] route in
            guard let self, self.sessionID == id else { return }
            if self.restrictedDirectSession { self.route = "Tailscale 无人值守" }
            else { self.route = self.isDirect ? "免登录直连" : route }
        }
        rtc.onState = { [weak self] state in
            self?.receiveRTCState(state, id: id)
        }
    }

    func receiveConnectionAddresses(_ value: DesktopConnectionAddresses, id: UUID) {
        guard sessionID == id else { return }
        connectionAddresses = connected ? value : DesktopConnectionAddresses()
    }

    func receiveRTCState(_ state: RTCPeerConnectionState, id: UUID) {
        guard sessionID == id else { return }
        switch state {
        case .connected:
            let reconnecting = sessionEstablished && !connected
            self.connectionTiming.start()
            self.connected = true; self.timeout?.cancel(); self.disconnectTimeout?.cancel()
            self.clipboard?.refresh()
            self.sessionEstablished = true
            if isHost { sendHostSessionStatus(); refreshFileReturn() }
            if isHost, reconnecting { refreshPrivacy() }
            if !isHost { applyInitialVideoPreference() }
        case .failed, .closed: self.disconnect("远程桌面连接已结束。")
        case .disconnected:
            self.input.releaseAll(); self.connected = false
            if isHost { refreshFileReturn() }
            connectionAddresses = DesktopConnectionAddresses(); latencyMilliseconds = nil
            self.clipboard?.refresh()
            self.disconnectTimeout?.cancel()
            self.disconnectTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, self?.sessionID == id else { return }
                self?.disconnect("网络连接中断，请重新连接。")
            }
        default: break
        }
    }

    /// 活跃会话随服务端心跳续期；旧服务端未声明能力时不发送新消息。
    func sessionKeepalive() -> DesktopSignal? {
        guard supportsSessionKeepalive, online, sessionEstablished, !signalRecovery.isRecovering,
              let sessionID, let peer else { return nil }
        return .init(type: "keepalive", id: sessionID, to: peer.id)
    }

    func receive(_ signal: DesktopSignal) async {
        let token = generation
        if signal.type == "hello" {
            for viewer in viewerSessions { await viewer.receive(signal) }
            online = true
            supportsSignalResume = signal.payload?.resume == true
            supportsSessionKeepalive = signal.payload?.keepalive == true
            if signalRecovery.isRecovering, let id = sessionID, let peer {
                guard supportsSignalResume else {
                    disconnect("服务端不支持恢复原桌面会话，请重新连接。", notify: false)
                    status = "在线 · 仅同账户设备可见"
                    return
                }
                status = "正在验证原桌面会话…"
                send(.init(type: "resume", id: id, to: peer.id, payload: .init(resumeToken: signalRecovery.token)))
            } else { status = "在线 · 仅同账户设备可见" }
            return
        }
        if signal.type == "heartbeat" {
            for viewer in viewerSessions { await viewer.receive(signal) }
            if let keepalive = sessionKeepalive() { send(keepalive) }
            return
        }
        guard let id = signal.id else { return }
        if let viewer = viewerSessions.first(where: { $0.sessionID == id }) {
            await viewer.receive(signal); return
        }
        if signal.type == "invite", let from = signal.from {
            guard availableForInvitation else { send(.init(type: "reject", id: id, to: from)); return }
            // 名称从已认证的通讯录获取，不使用请求携带的名称。
            await refresh()
            guard generation == token else { return }
            guard online, enabled, cloud?.peerClient != nil, cloud?.account?.id == accountID, availableForInvitation,
                  let peer = peers.first(where: { $0.id == from }) else {
                send(.init(type: "reject", id: id, to: from)); return
            }
            let request = DesktopInvitation(id: id, peer: peer)
            if unattended.enabled, settingsAccountID == accountID, cloud?.peerClient != nil {
                guard localSessionAvailable else {
                    send(.init(type: "reject", id: id, to: from, payload: .init(message: "对方当前处于休眠、未登录或非活动用户会话，暂时无法无人值守连接。"))); return
                }
                guard checkPermissions(control: unattended.control, prompt: false) else {
                    permissions.remind(requester: peer.name, control: unattended.control)
                    NSApp.requestUserAttention(.informationalRequest)
                    send(.init(type: "reject", id: id, to: from, payload: .init(message: permissions.snapshot.rejectionMessage(control: unattended.control)))); return
                }
                await startSharing(request, display: unattended.shareDisplay,
                                   control: unattended.control, audio: unattended.audio, unattended: true)
                return
            }
            guard DesktopLocalSession.current.canStart(unattended: false), !sessionSuspended else {
                send(.init(type: "reject", id: id, to: from, payload: .init(message: "对方屏幕已锁定，需事先在被控电脑上开启无人值守才能免确认连接。"))); return
            }
            presentInvitation(request)
            return
        }
        if invitation?.id == id, signal.from == invitation?.peer.id, signal.type == "end" {
            invitation = nil; timeout?.cancel()
            if isDirect { finishDirectConnection() }
            return
        }
        guard sessionID == id, signal.type == "error" || signal.from == peer?.id else { return }
        do {
            switch signal.type {
            case "resumed":
                guard signalRecovery.confirm(signal.payload?.resumeToken, now: ProcessInfo.processInfo.systemUptime) else { return }
                signalRecoveryTask?.cancel(); signalRecoveryTask = nil; signalRecovering = false
                status = "在线 · 仅同账户设备可见"
                DesktopSessionLog.record("signal-recovery-confirmed")
                let candidates = pendingCandidates; pendingCandidates.removeAll()
                for candidate in candidates { send(candidate) }
            case "accept" where !isHost && rtc == nil:
                controlAllowed = signal.payload?.control == true; audioAllowed = signal.payload?.audio == true
                filesAllowed = !restrictedDirectSession && signal.payload?.files == true
                route = "正在建立加密连接"
                armTimeout(id, seconds: 40, message: isDirect ? "无法建立画面连接，请检查两台 Mac 的网络和防火墙。"
                            : "无法连接对方，请检查网络或 TURN 中继配置。")
                try await prepareRTC(id: id, host: false)
                guard sessionID == id, let rtc else { return }
                let sdp = try await rtc.makeDescription(offer: true)
                guard sessionID == id else { return }
                send(.init(type: "offer", id: id, to: peer?.id, payload: .init(sdp: sdp)))
            case "offer" where isHost:
                guard let sdp = signal.payload?.sdp, let rtc else { throw CloudError("无效的桌面连接请求。") }
                try await rtc.setRemote(sdp, offer: true)
                let answer = try await rtc.makeDescription(offer: false)
                guard sessionID == id else { return }
                send(.init(type: "answer", id: id, to: peer?.id, payload: .init(sdp: answer)))
            case "answer" where !isHost:
                guard let sdp = signal.payload?.sdp, let rtc else { throw CloudError("无效的桌面连接响应。") }
                try await rtc.setRemote(sdp, offer: false)
            case "candidate": if let payload = signal.payload { rtc?.addCandidate(payload) }
            case "reject": disconnect(signal.payload?.message ?? "对方拒绝或当前正忙。", notify: false)
            case "end": disconnect(signal.payload?.message ?? "对方已结束共享。", notify: false)
            case "error":
                if signalRecovery.isRecovering, ["service_unavailable", "rate_limited"].contains(signal.payload?.code ?? "") {
                    (coordinator?.socket ?? socket)?.cancel(with: .goingAway, reason: nil)
                } else {
                    disconnect(signal.payload?.message ?? "桌面请求失败。", notify: false)
                }
            default: break
            }
        } catch { if sessionID == id { disconnect(error.localizedDescription) } }
    }

    private func presentInvitation(_ request: DesktopInvitation) {
        invitation = request
        permissions.refresh()
        permissions.requireControl(!isDirect)
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(55))
            guard !Task.isCancelled, let self, self.invitation?.id == request.id else { return }
            self.permissions.refresh()
            let control = self.permissions.requestedControl
            if !self.permissions.snapshot.missing(control: control).isEmpty {
                self.permissions.remind(requester: request.peer.name, control: control)
            }
            self.reject(reason: self.permissions.snapshot.rejectionMessage(control: control) ?? "对方未在有效期内确认连接，请重新发起连接。")
        }
        NSApp?.requestUserAttention(.informationalRequest)
    }

    private func send(_ signal: DesktopSignal) {
        if signal.type == "candidate", sessionEstablished, (!online || signalRecovery.isRecovering) {
            pendingCandidates.append(signal)
            if pendingCandidates.count > 256 { pendingCandidates.removeFirst() }
            return
        }
        (coordinator ?? self).sendTransport(signal)
    }

    private func sendTransport(_ signal: DesktopSignal) {
        if isDirect { directConnection?.send(signal); return }
        guard let socket, let data = try? JSONEncoder().encode(signal), let text = String(data: data, encoding: .utf8) else { return }
        let previous = sendTask, token = generation
        sendTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == token, self?.socket === socket else { return }
            do { try await socket.send(.string(text)) }
            catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }
    private func armTimeout(_ id: UUID, seconds: Double, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.sessionID == id else { return }; self?.disconnect(message)
        }
    }
    func sendInput(_ value: DesktopInput) { if !isHost, controlAllowed { rtc?.send(value) } }

    var canPerformMacControl: Bool { !isHost && acceptsViewerInput && !remoteScreenLocked }
    func performMacControl(_ action: DesktopMacControl) {
        guard canPerformMacControl else { return }
        for input in action.inputs { sendInput(input) }
    }

    func setViewerWindowActive(_ active: Bool) {
        if viewerWindowActive && !active { sendInput(.init(kind: "release")) }
        viewerWindowActive = active
        clipboard?.refresh()
        if !active { setRemoteShortcutsActive(false) }
        sendCursorPreference()
    }

    func setRemoteShortcutsActive(_ active: Bool) {
        let value = active && acceptsViewerInput && shortcutDestination == .remote
        if remoteShortcutsActive != value { remoteShortcutsActive = value }
    }

    func setViewerPresented(_ presented: Bool) {
        viewerPresented = presented
        clipboard?.refresh()
        video?.isEnabled = presented
        if !presented {
            // 关闭窗口、切换会话和断开连接都在拆除视频视图前走这里。
            // 不在 dismantleNSView 中发布状态，避免重入 SwiftUI 的销毁事务。
            if fileDragHover { fileDragHover = false }
            playback.stop()
        }
    }

    func setShortcutDestination(_ destination: DesktopShortcutDestination) {
        setRemoteShortcutsActive(false)
        sendInput(.init(kind: "release"))
        shortcutCaptureError = nil
        if destination == .remote, !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                shortcutCaptureError = "请在此 Mac 的系统设置中授予 TaoScreen 辅助功能权限，再选择由被控电脑接收快捷键。"
                return
            }
        }
        shortcutDestination = destination
    }

    func requestVideoPreset(_ preset: DesktopVideoPreset) {
        guard !isHost, connected, let id = sessionID,
              let request = videoSelection.begin(preset), let requestID = request.requestID else { return }
        videoPreferenceApplied = true
        videoRequestTimeout?.cancel(); videoRequestTimeout = nil
        guard rtc?.sendVideoSettings(request) == true else {
            videoSelection.sendFailed(requestID)
            return
        }
        videoRequestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.sessionID == id else { return }
            self.videoSelection.expire(requestID)
        }
    }

    private func applyInitialVideoPreference() {
        guard !isHost, connected, videoSelection.supported, !videoPreferenceApplied,
              let confirmed = videoSelection.confirmed else { return }
        if confirmed.preset == videoSelection.preference { videoPreferenceApplied = true }
        else { requestVideoPreset(videoSelection.preference) }
    }

    func receiveVideoSettings(_ value: DesktopVideoMessage) {
        guard value.isValid, sessionID != nil else { return }
        if isHost, value.action == .request { applyHostVideoPreset(value); return }
        guard !isHost, value.action == .status else { return }
        let requestedID = videoSelection.request?.requestID
        guard videoSelection.receive(value) else { return }
        if let requestedID, requestedID == value.requestID {
            videoRequestTimeout?.cancel(); videoRequestTimeout = nil
            if value.failure == nil { saveViewerPreferences() }
        }
        applyInitialVideoPreference()
    }

    private func sendVideoStatus(requestID: UUID? = nil, failure: String? = nil) {
        guard isHost, let rtc else { return }
        let format = capture?.videoFormat
        let confirmed = format?.preset == hostVideoPreset && rtc.hasVideoConfiguration(hostVideoPreset)
        rtc.sendVideoSettings(.init(action: .status, requestID: requestID, preset: hostVideoPreset,
            width: confirmed ? format?.width : nil, height: confirmed ? format?.height : nil,
            failure: failure.map { String($0.prefix(500)) } ?? (confirmed ? nil : "画面采集或编码状态尚未确认。")))
    }

    private func applyHostVideoPreset(_ request: DesktopVideoMessage) {
        guard let id = sessionID, let requestID = request.requestID, let rtc else { return }
        guard hostVideoRequestID == nil else {
            sendVideoStatus(requestID: requestID, failure: "上一次画面设置仍在应用，请稍后重试。")
            return
        }
        hostVideoRequestID = requestID
        let restarting = captureRestartTask
        videoUpdateTask = Task { [weak self] in
            // 等待已排队的采集重建；后续重建则等待此任务，保持操作顺序。
            await restarting?.value
            guard let self, !Task.isCancelled, self.sessionID == id, self.rtc === rtc else { return }
            defer {
                if self.sessionID == id, self.hostVideoRequestID == requestID {
                    self.hostVideoRequestID = nil; self.videoUpdateTask = nil
                }
            }
            guard self.localSessionAvailable, let capture = self.capture else {
                self.sendVideoStatus(requestID: requestID, failure: "屏幕采集当前不可用，请稍后重试。")
                return
            }
            let previous = self.hostVideoPreset
            do {
                try await DesktopVideoUpdate.apply(request.preset, previous: previous, encoder: { preset in
                    guard self.sessionID == id, self.capture === capture, !Task.isCancelled else { throw CancellationError() }
                    try rtc.setVideoPreset(preset)
                }, capture: { preset in
                    guard self.sessionID == id, self.capture === capture, !Task.isCancelled else { throw CancellationError() }
                    try await capture.setVideoPreset(preset)
                })
                guard !Task.isCancelled, self.sessionID == id, self.capture === capture else { return }
                self.hostVideoPreset = request.preset
                self.sendVideoStatus(requestID: requestID)
            } catch {
                guard !Task.isCancelled, self.sessionID == id, self.capture === capture else { return }
                if case DesktopVideoUpdateFailure.unknown = error {
                    self.disconnect(error.localizedDescription)
                } else {
                    self.sendVideoStatus(requestID: requestID, failure: error.localizedDescription)
                }
            }
        }
    }

    private func sendCursorPreference() {
        guard !isHost, sessionID != nil, cursorSupported else { return }
        let visible = cursorMode.showsRemoteCursor(canControl: controlAllowed && viewerControlEnabled,
                                                  windowActive: viewerWindowActive)
        guard requestedCursorVisible != visible else { return }
        if rtc?.sendCursor(.init(action: .request, showsCursor: visible)) == true {
            requestedCursorVisible = visible
        }
    }

    private func updateHostCursor() {
        guard isHost, let id = sessionID, let capture else { return }
        let previous = cursorUpdateTask
        let visible = hostCursorVisible
        cursorUpdateTask = Task { [weak self, weak capture] in
            await previous?.value
            guard let self, let capture, !Task.isCancelled,
                  self.sessionID == id, self.capture === capture else { return }
            do {
                guard try await capture.setCursorVisible(visible) else { return }
                guard !Task.isCancelled, self.sessionID == id, self.capture === capture else { return }
                self.rtc?.sendCursor(.init(action: .status, showsCursor: capture.showsCursor))
            } catch {
                guard !Task.isCancelled, self.sessionID == id, self.capture === capture else { return }
                self.rtc?.sendCursor(.init(action: .status, showsCursor: capture.showsCursor, failed: true))
            }
        }
    }
    private func sendHostSessionStatus() {
        rtc?.sendSessionStatus(.init(locked: localSession.locked, fileDrop: !restrictedDirectSession,
                                     fileDirectories: !restrictedDirectSession,
                                     fileReturn: controlAllowed && !restrictedDirectSession ? true : nil))
    }

    private func refreshFileReturn() {
        guard isHost, connected, controlAllowed, !restrictedDirectSession, localSessionAvailable, !localSession.locked,
              fileTransfer?.reverseEnabled == true else {
            input.onLeftMouseEvent = nil
            fileReturnPanel.stop()
            return
        }
        fileReturnPanel.start(displayID: input.displayID, peer: peer?.name ?? "控制端", allowed: { [weak self] in
            self?.rtc?.fileChannelOpen == true && self?.dropDelivery.isDelivering == false
                && self?.fileTransfer?.canSend == true
        }, send: { [weak self] urls in
            self?.fileTransfer?.send(urls, paste: false) == true
        }, cancel: { [weak self] in self?.cancelFileTransfer() })
        input.onLeftMouseEvent = { [weak self] type in self?.fileReturnPanel.observe(type, remote: true) }
    }

    @discardableResult
    func sendFiles(_ urls: [URL], paste: Bool = false) -> Bool {
        guard canSendFiles else {
            message = filesAllowed ? "请等待连接或当前文件传输完成。" : "对方未允许文件传输，或使用的 TaoScreen 版本不支持该功能。"
            return false
        }
        return fileTransfer?.send(urls, paste: paste) == true
    }
    @discardableResult
    func dropFiles(_ urls: [URL], at point: DesktopDropPoint) -> Bool {
        guard canSendFiles, viewerControlEnabled, !remoteScreenLocked, point.isValid else { return false }
        if !dropSupported {
            message = "对方版本不支持按位置投放；文件将保存到远端下载目录，请升级两端 TaoScreen。"
            return sendFiles(urls)
        }
        return fileTransfer?.send(urls, paste: false, drop: point) == true
    }
    func dismissFileStatus() {
        guard transferState?.active != true else { return }
        transferState = nil; fileMessage = nil
    }
    func cancelFileTransfer() { fileTransfer?.cancelSending() }
    func dismissFileReceipt() {
        guard fileReceiveProgress == nil else { return }
        fileReceiveMessage = nil; receivedFileFolder = nil
    }
    func chooseFiles() {
        guard canSendFiles else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "发送到远端"
        let currentSession = sessionID
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, self.sessionID == currentSession else { return }
                self.sendFiles(panel.urls)
            }
        }
    }
    /// 显式本机粘贴仍可覆盖远端，普通 ⌘V 由会话剪贴板决定来源。
    func pasteClipboard() {
        guard connected, !isHost, controlAllowed, viewerControlEnabled, clipboardEnabled, !remoteScreenLocked,
              !restrictedDirectSession else { return }
        clipboard?.useLocalSource()
        if let files = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            sendFiles(files, paste: true); return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { message = "当前支持粘贴文本、文件和文件夹。"; return }
        pasteText(text)
    }
    func pasteUnifiedClipboard() {
        guard acceptsViewerInput else { return }
        if clipboardEnabled, !remoteScreenLocked, !restrictedDirectSession { clipboard?.pasteUnified() }
        else { pasteRemoteClipboard() }
    }
    /// 输入法提交的文字直接传输，不读取或改写控制端的剪贴板。
    func insertLocalText(_ text: String) {
        guard localInputEnabled, acceptsViewerInput, !isHost, !remoteScreenLocked else { return }
        pasteText(text, transient: true)
    }
    private func pasteText(_ text: String, transient: Bool = false) {
        do { for input in try DesktopInput.textPaste(text, transient: transient) { sendInput(input) } }
        catch { message = error.localizedDescription }
    }
    func pasteRemoteClipboard() {
        sendInput(.init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue))
        sendInput(.init(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue))
    }
    var remotePasswordScope: DesktopRemotePasswordScope? {
        guard !isHost, let accountID, let peer else { return nil }
        return .init(accountID: accountID, peerID: peer.id)
    }
    func refreshRemotePasswordAvailability() {
        hasSavedRemotePassword = false; remotePasswordMessage = nil
        guard let scope = remotePasswordScope else { return }
        do { hasSavedRemotePassword = try passwordStore.contains(scope) }
        catch { remotePasswordMessage = error.localizedDescription }
    }
    func saveRemotePassword(_ password: String, for scope: DesktopRemotePasswordScope) throws {
        guard remotePasswordScope == scope else { throw CloudError("账号或远程电脑已改变，未保存密码。") }
        guard DesktopRemoteSecurityMessage.validPassword(password) else { throw CloudError("密码不能为空、超过 1024 字节或包含控制字符。") }
        try passwordStore.save(scope, password)
        if remotePasswordScope == scope { hasSavedRemotePassword = true; remotePasswordMessage = "密码已保存到本机钥匙串。" }
    }
    func deleteRemotePassword(for scope: DesktopRemotePasswordScope) throws {
        guard remotePasswordScope == scope else { throw CloudError("账号或远程电脑已改变，未删除密码。") }
        try passwordStore.delete(scope)
        if remotePasswordScope == scope { hasSavedRemotePassword = false; remotePasswordMessage = "已删除本机保存的密码。" }
    }
    private var canSubmitSavedPassword: Bool {
        !isHost && connected && controlAllowed && viewerControlEnabled && remoteScreenLocked &&
        remoteSecurity.supported && hasSavedRemotePassword && remoteSecurity.unlockRequest == nil
    }
    var canUnlockWithSavedPassword: Bool { canSubmitSavedPassword && !authenticatingRemotePassword }

    func unlockWithSavedPassword() {
        guard canUnlockWithSavedPassword, let sessionID, let scope = remotePasswordScope else { return }
        coordinator?.desktopWindow.releaseKeyboardFocus()
        sendInput(.init(kind: "release"))
        authenticatingRemotePassword = true
        securityAuthentication = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    authenticatingRemotePassword = false
                    securityAuthentication = nil
                }
            }
            do {
                let password = try await passwordStore.read(scope)
                try Task.checkCancellation()
                guard self.sessionID == sessionID, remotePasswordScope == scope, canSubmitSavedPassword else {
                    throw CloudError("连接或锁屏状态已改变，未发送密码。")
                }
                guard let password else {
                    hasSavedRemotePassword = false
                    throw CloudError("本机未找到受保护的密码，请重新保存。")
                }
                guard DesktopRemoteSecurityMessage.validPassword(password) else {
                    throw CloudError("本机保存的密码格式无效，请重新保存。")
                }
                guard let id = remoteSecurity.beginUnlock() else { return }
                guard rtc?.sendSecurity(.init(action: .unlock, requestID: id, password: password)) == true else {
                    remoteSecurity.unlockFailed("加密控制通道未就绪，未发送密码。")
                    return
                }
                securityUnlockTimeout?.cancel()
                securityUnlockTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard self?.sessionID == sessionID else { return }
                    self?.remoteSecurity.expireUnlock(id)
                }
            } catch is CancellationError {
                if !Task.isCancelled { remoteSecurity.unlockFailed("已取消本机验证。") }
            } catch {
                if !Task.isCancelled { remoteSecurity.unlockFailed(error.localizedDescription) }
            }
        }
    }
    func setRemoteDisconnectLock(_ enabled: Bool) {
        guard !isHost, connected, controlAllowed, let value = remoteSecurity.configure(enabled) else { return }
        sendSecurityConfiguration(value)
    }
    private func sendSecurityConfiguration(_ value: DesktopRemoteSecurityMessage) {
        guard let id = value.requestID, let sessionID else { return }
        guard controlAllowed, rtc?.sendSecurity(value) == true else { remoteSecurity.lockSendFailed(id); return }
        securityLockTimeout?.cancel()
        securityLockTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.sessionID == sessionID else { return }; self?.remoteSecurity.expireLock(id)
        }
    }
    func receiveRemoteSecurity(_ value: DesktopRemoteSecurityMessage) {
        guard !isDirect, value.isValid, sessionID != nil else { return }
        if !isHost {
            let oldPreference = remoteSecurity.preference
            if let configuration = remoteSecurity.receive(value) { sendSecurityConfiguration(configuration) }
            if oldPreference != remoteSecurity.preference { saveViewerPreferences() }
            return
        }
        if value.action == .configure, let enabled = value.lockOnDisconnect {
            let accepted = hostSecurity.configure(enabled, authorized: controlAllowed && localSessionAvailable)
            rtc?.sendSecurity(.init(action: .status, requestID: value.requestID, lockOnDisconnect: hostSecurity.lockOnDisconnect,
                                    failure: accepted ? nil : .permission))
        } else if value.action == .unlock, let id = value.requestID, let password = value.password {
            let current = DesktopLocalSession.current
            var failure = hostSecurity.authorizeUnlock(id, authorized: connected && controlAllowed && input.enabled && localSessionAvailable,
                                                       locked: current.canHost && current.locked && localSession.locked,
                                                       now: ProcessInfo.processInfo.systemUptime)
            if failure == nil {
                input.releaseAll()
                do { try securityInput.submitPassword(password) }
                catch { failure = .inputUnavailable }
            }
            rtc?.sendSecurity(.init(action: .unlockResult, requestID: id, submitted: failure == nil, failure: failure))
        }
    }
    private func lockAfterRemoteDisconnect() {
        do {
            try securityInput.lock()
            lockConfirmation?.cancel()
            lockConfirmation = Task { [weak self] in
                for _ in 0..<30 {
                    guard self?.sessionID == nil else { return }
                    if DesktopLocalSession.current.locked { return }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                self?.message = "断连锁屏请求已发送，但系统尚未确认锁定。请检查辅助功能权限和系统 ⌃⌘Q 锁屏快捷键。"
            }
        } catch { message = "断连锁屏未完成：\(error.localizedDescription)" }
    }

    func stopControl() { input.enabled = false; disconnect("本机已停止控制授权。") }
    func disconnect(_ reason: String? = nil, notify: Bool = true) {
        let lockAfterDisconnect = hostSecurity.end(established: sessionEstablished, authorized: isHost && controlAllowed,
                                                   localSession: DesktopLocalSession.current)
        securityLockTimeout?.cancel(); securityLockTimeout = nil
        securityUnlockTimeout?.cancel(); securityUnlockTimeout = nil
        securityAuthentication?.cancel(); securityAuthentication = nil; authenticatingRemotePassword = false
        remoteSecurity = DesktopRemoteSecurityViewer(); hasSavedRemotePassword = false; remotePasswordMessage = nil
        // 清理会话时的临时重置不能覆盖用户保存的选项。
        viewerPreferencesLoaded = false
        clipboard?.close(); clipboard = nil; clipboardSupported = false
        videoRequestTimeout?.cancel(); videoRequestTimeout = nil
        videoUpdateTask?.cancel(); videoUpdateTask = nil; hostVideoRequestID = nil
        hostVideoPreset = .ultra; videoSelection = DesktopVideoSelection(); videoPreferenceApplied = false
        let disconnectedPeer = peer
        if let reason { DesktopSessionLog.record("disconnect reason=\(reason)") }
        signalRecoveryTask?.cancel(); signalRecoveryTask = nil
        signalRecovery.reset(); signalRecovering = false; sessionEstablished = false; pendingCandidates.removeAll()
        connectionTiming = DesktopConnectionTiming()
        privacyRequestTimeout?.cancel(); privacyRequestTimeout = nil
        privacyCurtain.stop()
        privacyRequested = false; privacyActive = false; privacyChanging = false; privacySupported = false
        privacyStateKnown = true
        captureGeneration = UUID(); captureRestartTask?.cancel(); captureRestartTask = nil
        displayActivity.stop()
        if notify, let id = sessionID, let peer { send(.init(type: "end", id: id, to: peer.id)) }
        if notify { reject() }
        setViewerPresented(false)
        cursorUpdateTask?.cancel(); cursorUpdateTask = nil
        cursorSupported = false; remoteCursorVisible = true; requestedCursorVisible = nil
        hostCursorVisible = true; viewerWindowActive = false; viewerControlEnabled = true
        input.onLeftMouseEvent = nil; fileReturnPanel.stop()
        fileTransfer?.close(); fileTransfer = nil
        filesAllowed = false; fileProgress = nil; fileMessage = nil
        fileReceiveMessage = nil; fileReceiveProgress = nil; receivedFileFolder = nil
        if transferState?.active == true {
            transferState?.phase = .failed; transferState?.message = "连接已断开，未完成的传输已停止。"
        }
        dropSupported = false; dropDelivery.invalidate()
        setRemoteShortcutsActive(false)
        sessionID = nil; invitation = nil; peer = nil; connected = false; video = nil
        controlAllowed = false; audioAllowed = false; isHost = false; unattendedSession = false; remoteScreenLocked = false; latencyMilliseconds = nil
        connectionAddresses = DesktopConnectionAddresses()
        timeout?.cancel(); timeout = nil; disconnectTimeout?.cancel(); disconnectTimeout = nil
        input.enabled = false; playback.stop(); rtc?.close(); rtc = nil
        let old = capture; capture = nil
        virtualDisplay = nil
        Task { await old?.stop() }
        if let reason { message = reason }
        if lockAfterDisconnect { lockAfterRemoteDisconnect() }
        if let coordinator {
            if let reason, let disconnectedPeer { coordinator.message = "\(disconnectedPeer.name)：\(reason)" }
            coordinator.removeViewer(id)
        }
        if isDirect { (coordinator ?? self).finishDirectConnection() }
    }
    private func removeViewer(_ id: UUID) {
        viewerSessions.removeAll { $0.id == id }
        if selectedViewerID == id { selectedViewerID = viewerSessions.first?.id }
        if viewerSessions.isEmpty { desktopWindow.close() }
        else { desktopWindow.updatePresentation() }
    }
    private func disconnectAll(_ reason: String? = nil, notify: Bool = true) {
        for viewer in viewerSessions { viewer.disconnect(reason, notify: notify) }
        disconnect(reason, notify: notify)
    }
    func shutdown() {
        permissions.clearReminder()
        if !isDirect { RemoteAvailability.shared.setActive(.desktop, false) }
        disconnectAll()
        generation = UUID(); accountID = nil; online = false; peers = []
        serviceTask?.cancel(); serviceTask = nil; maintenance?.cancel(); maintenance = nil
        heartbeatTask?.cancel(); heartbeatTask = nil; supportsSignalResume = false
        supportsSessionKeepalive = false
        sendTask?.cancel(); sendTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}
