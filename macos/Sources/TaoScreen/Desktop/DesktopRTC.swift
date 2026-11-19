import Foundation
import VideoToolbox
import WebRTC

enum DesktopH264 {
    // 4K/30 需要 Level 5.1，WebRTC 自带的 Constrained High 仅声明 Level 3.1。
    private static let ultraProfileLevelID = "640c33"
    static let supportsUltra: Bool = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else { return false }
        let width = Int32(DesktopVideoPreset.ultra.maximumLongEdge)
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(width: width, height: width / 16 * 9,
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification, encoderIDOut: nil,
            supportedPropertiesOut: &properties)
        guard status == noErr,
              let properties = properties as? [String: Any],
              let profile = properties[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any],
              let levels = profile[kVTPropertySupportedValueListKey as String] as? [String] else { return false }
        return levels.contains(kVTProfileLevel_H264_High_5_1 as String)
    }()

    fileprivate static func ultraFormats(_ codecs: [RTCVideoCodecInfo]) -> [RTCVideoCodecInfo] {
        codecs.map { codec in
            guard codec.name == "H264", codec.parameters["profile-level-id"] == "640c1f" else { return codec }
            var parameters = codec.parameters
            parameters["profile-level-id"] = ultraProfileLevelID
            return RTCVideoCodecInfo(name: codec.name, parameters: parameters, scalabilityModes: codec.scalabilityModes)
        }
    }
}

private final class DesktopVideoEncoderFactory: RTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] { DesktopH264.ultraFormats(super.supportedCodecs()) }
}

private final class DesktopVideoDecoderFactory: RTCDefaultVideoDecoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] { DesktopH264.ultraFormats(super.supportedCodecs()) }
}

@MainActor
final class DesktopRTC: NSObject {
    enum Purpose: Sendable { case desktop, ports }
    nonisolated let purpose: Purpose
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = DesktopH264.supportsUltra ? DesktopVideoEncoderFactory() : RTCDefaultVideoEncoderFactory()
        let decoder = DesktopH264.supportsUltra ? DesktopVideoDecoderFactory() : RTCDefaultVideoDecoderFactory()
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = h264 }
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()
    let source: RTCVideoSource
    private var connection: RTCPeerConnection!
    private var videoSender: RTCRtpSender?
    private(set) var videoPreset = DesktopVideoPreset.ultra
    private var control: RTCDataChannel?
    private var sound: RTCDataChannel?
    private var files: RTCDataChannel?
    private var ports: RTCDataChannel?
    nonisolated private let incomingAudio = DesktopAudioMailbox()
    nonisolated private let incomingMessages = DesktopMessageInbox()
    nonisolated private let incomingPorts = DesktopMessageInbox()
    private lazy var inputSender = DesktopReliableSender(limit: 64 * 1024, timeout: 1, send: { [weak self] data in
        guard let self, !self.closed, let control = self.control,
              control.readyState == .open, control.bufferedAmount < 64 * 1024 else { return false }
        return control.sendData(RTCDataBuffer(data: data, isBinary: false))
    }, failed: { [weak self] in self?.onState?(.failed) })
    private var pendingCandidates: [RTCIceCandidate] = []
    private var remoteSet = false
    private var pressedMouseButtons = Set<Int>()
    private var statisticsTask: Task<Void, Never>?
    private var statisticsGeneration = UUID()
    private var pendingCursor: DesktopCursorMessage?
    private var cursorSendTask: Task<Void, Never>?
    private var pendingPrivacy: DesktopPrivacyMessage?
    private var privacySendTask: Task<Void, Never>?
    private(set) var closed = false
    var onSignal: ((String, DesktopSignal.Payload) -> Void)?
    var onVideo: ((RTCVideoTrack) -> Void)?
    var onInput: ((DesktopInput) -> Void)?
    var onInputTrace: ((DesktopInputTrace) -> Void)?
    var onControlOpen: (() -> Void)?
    var onSessionStatus: ((DesktopSessionStatus) -> Void)?
    var onCursor: ((DesktopCursorMessage) -> Void)?
    var onPrivacy: ((DesktopPrivacyMessage) -> Void)?
    var onVideoSettings: ((DesktopVideoMessage) -> Void)?
    var onClipboard: ((DesktopClipboardMessage) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onFile: ((Data) -> Void)?
    var onPortData: ((Data) -> Void)?
    var onPortState: ((Bool) -> Void)?
    var onState: ((RTCPeerConnectionState) -> Void)?
    var onRoute: ((String) -> Void)?
    var onLatency: ((Double?) -> Void)?
    var onConnectionAddresses: ((DesktopConnectionAddresses) -> Void)?
    var onSecurity: ((DesktopRemoteSecurityMessage) -> Void)?

    init(configuration: DesktopConfiguration, host: Bool, purpose: Purpose = .desktop) throws {
        self.purpose = purpose
        source = Self.factory.videoSource(forScreenCast: true)
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = configuration.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.continualGatheringPolicy = .gatherContinually
        guard let peer = Self.factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else { throw CloudError("无法初始化远程桌面引擎。") }
        connection = peer
        if purpose == .desktop {
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = host ? .sendOnly : .recvOnly
            if host {
                let track = Self.factory.videoTrack(with: source, trackId: "desktop")
                videoSender = peer.add(track, streamIds: ["desktop"])
            } else { _ = peer.addTransceiver(of: .video, init: transceiver) }
        }
        if !host {
            let reliable = RTCDataChannelConfiguration()
            reliable.isOrdered = true
            if purpose == .ports {
                ports = peer.dataChannel(forLabel: "desktop-ports.v1", configuration: reliable)
                ports?.delegate = self
            } else {
                control = peer.dataChannel(forLabel: "control", configuration: reliable)
                control?.delegate = self
                files = peer.dataChannel(forLabel: "desktop-files.v1", configuration: reliable)
                files?.delegate = self
                let audio = RTCDataChannelConfiguration()
                audio.isOrdered = false; audio.maxRetransmits = 0
                sound = peer.dataChannel(forLabel: "system-audio", configuration: audio)
                sound?.delegate = self
            }
        }
    }

    func makeDescription(offer: Bool) async throws -> String {
        guard !closed else { throw CancellationError() }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: CloudError("无法协商桌面连接。")) }
            }
            if offer { connection.offer(for: constraints, completionHandler: callback) }
            else { connection.answer(for: constraints, completionHandler: callback) }
        }
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        guard !closed else { throw CancellationError() }
        if videoSender != nil { try setVideoPreset(videoPreset) }
        return description.sdp
    }

    func setVideoPreset(_ preset: DesktopVideoPreset) throws {
        guard !closed, let videoSender, !videoSender.parameters.encodings.isEmpty else {
            throw CloudError("视频编码尚未就绪。")
        }
        // Apply after SDP has associated the answerer's sender with its m-line.
        let parameters = videoSender.parameters
        parameters.degradationPreference = NSNumber(value: degradationPreference(for: preset).rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: preset.maximumBitrate)
            encoding.maxFramerate = NSNumber(value: preset.framesPerSecond)
            encoding.scaleResolutionDownBy = 1
        }
        videoSender.parameters = parameters
        // 原生 setter 不返回错误，读取实际参数确认，不能仅按本地变量报告成功。
        guard hasVideoConfiguration(preset) else { throw CloudError("视频编码器未接受所选画面参数。") }
        // Let congestion control lower the bitrate; a minimum would overwhelm slow links.
        connection.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: preset.initialBitrate),
                                      maxBitrateBps: NSNumber(value: preset.maximumBitrate))
        videoPreset = preset
    }

    func hasVideoConfiguration(_ preset: DesktopVideoPreset) -> Bool {
        guard !closed, let parameters = videoSender?.parameters, !parameters.encodings.isEmpty else { return false }
        return parameters.degradationPreference?.intValue == degradationPreference(for: preset).rawValue
            && parameters.encodings.allSatisfy {
                $0.maxBitrateBps?.intValue == preset.maximumBitrate
                    && $0.maxFramerate?.intValue == preset.framesPerSecond
                    && $0.scaleResolutionDownBy?.doubleValue == 1
            }
    }

    private func degradationPreference(for preset: DesktopVideoPreset) -> RTCDegradationPreference {
        preset == .smooth ? .maintainFramerate : .maintainResolution
    }
    func setRemote(_ sdp: String, offer: Bool) async throws {
        guard !closed, sdp.utf8.count <= 60*1024 else { throw CloudError("桌面连接参数无效。") }
        if purpose == .ports, sdp.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("m=video ") || $0.hasPrefix("m=audio ") }) {
            throw CloudError("独立端口连接不接受屏幕或声音轨道。")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: offer ? .offer : .answer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        guard !closed else { throw CancellationError() }
        remoteSet = true
        for candidate in pendingCandidates { connection.add(candidate) { _ in } }
        pendingCandidates.removeAll()
    }
    func addCandidate(_ payload: DesktopSignal.Payload) {
        guard !closed, let sdp = payload.candidate, sdp.utf8.count < 8192, let line = payload.line, line >= 0 else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: payload.mid)
        if remoteSet { connection.add(candidate) { _ in } }
        else if pendingCandidates.count < 256 { pendingCandidates.append(candidate) }
    }
    func send(_ input: DesktopInput) {
        guard !closed, input.isValid, let control, control.readyState == .open,
              let data = try? JSONEncoder().encode(input) else {
            DesktopInputDiagnostics.record("send_rejected", input: input,
                detail: "closed=\(closed) valid=\(input.isValid) channel=\(control?.readyState.rawValue ?? -1)")
            return
        }
        // Only coalesce unsent hover motion. Drag paths and button/key boundaries remain ordered.
        let hover = input.kind == "move" && pressedMouseButtons.isEmpty
        if input.kind == "button", let button = input.button {
            if input.down == true { pressedMouseButtons.insert(button) } else { pressedMouseButtons.remove(button) }
        } else if input.kind == "release" { pressedMouseButtons.removeAll() }
        DesktopInputDiagnostics.record("send_queued", input: input)
        inputSender.send(data, coalescible: hover)
    }

    func sendInputTrace(_ value: DesktopInputTrace) {
        guard DesktopInputDiagnostics.systemEnabled, value.isValid, !closed, let control,
              control.readyState == .open, control.bufferedAmount < 64 * 1024,
              let data = try? JSONEncoder().encode(value) else { return }
        _ = control.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    @discardableResult
    func sendClipboard(_ value: DesktopClipboardMessage) -> Bool {
        guard value.isValid, !closed, control?.readyState == .open,
              let data = try? JSONEncoder().encode(value) else { return false }
        // Share the input queue so writes and paste actions cannot overtake
        // keyboard input, including IME commits, during temporary congestion.
        inputSender.send(data)
        return true
    }
    func sendSessionStatus(_ value: DesktopSessionStatus) {
        guard value.isValid, !closed, control?.readyState == .open,
              let data = try? JSONEncoder().encode(value) else { return }
        inputSender.send(data)
    }
    @discardableResult
    func sendVideoSettings(_ value: DesktopVideoMessage) -> Bool {
        guard value.isValid, !closed, control?.readyState == .open,
              let data = try? JSONEncoder().encode(value) else { return false }
        inputSender.send(data)
        return true
    }
    @discardableResult
    func sendSecurity(_ value: DesktopRemoteSecurityMessage) -> Bool {
        guard value.isValid, purpose == .desktop, !closed, control?.readyState == .open,
              let data = try? JSONEncoder().encode(value) else { return false }
        inputSender.send(data)
        return true
    }
    @discardableResult
    func sendCursor(_ value: DesktopCursorMessage) -> Bool {
        guard value.isValid, !closed, control?.readyState == .open else { return false }
        // 暂时拥塞时保留最新状态，尤其不能丢掉窗口关闭时的“恢复光标”。
        pendingCursor = value
        flushCursor()
        if pendingCursor != nil, cursorSendTask == nil {
            cursorSendTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled, !self.closed else { return }
                    self.flushCursor()
                    if self.pendingCursor == nil { self.cursorSendTask = nil; return }
                }
            }
        }
        return true
    }
    private func flushCursor() {
        guard let value = pendingCursor, let control, control.readyState == .open,
              control.bufferedAmount < 64 * 1024,
              let data = try? JSONEncoder().encode(value) else { return }
        if control.sendData(RTCDataBuffer(data: data, isBinary: false)) { pendingCursor = nil }
    }
    @discardableResult
    func sendPrivacy(_ value: DesktopPrivacyMessage) -> Bool {
        guard value.isValid, !closed, control?.readyState == .open else { return false }
        pendingPrivacy = value
        flushPrivacy()
        if pendingPrivacy != nil, privacySendTask == nil {
            privacySendTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled, !self.closed else { return }
                    self.flushPrivacy()
                    if self.pendingPrivacy == nil { self.privacySendTask = nil; return }
                }
            }
        }
        return true
    }
    private func flushPrivacy() {
        guard let value = pendingPrivacy, let control, control.readyState == .open,
              control.bufferedAmount < 64 * 1024,
              let data = try? JSONEncoder().encode(value) else { return }
        if control.sendData(RTCDataBuffer(data: data, isBinary: false)) { pendingPrivacy = nil }
    }
    func sendAudio(_ data: Data) {
        guard !closed, let sound, sound.readyState == .open, sound.bufferedAmount < 32*1024 else { return }
        _ = sound.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    var fileChannelOpen: Bool { !closed && files?.readyState == .open }

    /// 发送缓存有界，调用者等待落盘确认并在拥塞时重试。
    func sendFile(_ data: Data) -> Bool {
        guard !closed, data.count <= DesktopFilePacket.maxPacketSize, let files,
              files.readyState == .open, files.bufferedAmount < 256 * 1024 else { return false }
        return files.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    func sendPortData(_ data: Data) -> Bool {
        guard !closed, data.count <= DesktopPortLimits.packet, let ports,
              ports.readyState == .open, ports.bufferedAmount < 256 * 1024 else { return false }
        return ports.sendData(RTCDataBuffer(data: data, isBinary: true))
    }
    func closePortChannel() {
        let channel = ports; ports = nil
        channel?.delegate = nil; channel?.close(); incomingPorts.close()
        onPortState?(false)
    }
    func close() {
        guard !closed else { return }
        closed = true
        inputSender.close(); incomingMessages.close()
        incomingAudio.close()
        closePortChannel()
        cursorSendTask?.cancel(); cursorSendTask = nil; pendingCursor = nil
        privacySendTask?.cancel(); privacySendTask = nil; pendingPrivacy = nil
        stopStatistics()
        control?.delegate = nil; sound?.delegate = nil; files?.delegate = nil
        control?.close(); sound?.close(); files?.close(); connection.delegate = nil; connection.close()
        pendingCandidates.removeAll()
    }

    private func startStatistics() {
        stopStatistics()
        let token = statisticsGeneration
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed, self.statisticsGeneration == token else { return }
                self.connection.statistics { [weak self] report in
                    Task { @MainActor in
                        guard let self, !self.closed, self.statisticsGeneration == token else { return }
                        let statistics = report.statistics.mapValues { ($0.type, $0.values) }
                        self.onLatency?(DesktopLatency.milliseconds(statistics: statistics))
                        self.onConnectionAddresses?(DesktopConnectionAddresses.selected(statistics: statistics))
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopStatistics() {
        statisticsTask?.cancel(); statisticsTask = nil
        statisticsGeneration = UUID()
        onLatency?(nil)
        onConnectionAddresses?(DesktopConnectionAddresses())
    }
}

extension DesktopRTC: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }
            self.onSignal?("candidate", .init(candidate: candidate.sdp, mid: candidate.sdpMid, line: candidate.sdpMLineIndex))
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            if newState == .connected { self.startStatistics() } else { self.stopStatistics() }
            self.onState?(newState)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let video = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onVideo?(video) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }
            if self.purpose == .desktop, dataChannel.label == "control", self.control == nil { self.control = dataChannel }
            else if self.purpose == .desktop, dataChannel.label == "system-audio", self.sound == nil { self.sound = dataChannel }
            else if self.purpose == .desktop, dataChannel.label == "desktop-files.v1", self.files == nil { self.files = dataChannel }
            else if self.purpose == .ports, dataChannel.label == "desktop-ports.v1", self.ports == nil { self.ports = dataChannel }
            else { dataChannel.close(); return }
            dataChannel.delegate = self
            if dataChannel.label == "control", dataChannel.readyState == .open { self.onControlOpen?() }
            if dataChannel.label == "desktop-ports.v1", dataChannel.readyState == .open { self.onPortState?(true) }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason: String) {
        let relayed = local.sdp.contains(" typ relay ") || remote.sdp.contains(" typ relay ")
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.onRoute?(relayed ? "服务器中继" : "设备直连") }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.label == "desktop-ports.v1" {
            let state = dataChannel.readyState
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if state == .open { self.onPortState?(true) }
                else if state == .closed { self.onPortState?(false) }
            }
            return
        }
        guard dataChannel.label == "control" else { return }
        let state = dataChannel.readyState
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            if state == .open { self.onControlOpen?() }
            else if state == .closed { self.onState?(.failed) }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel.label == "desktop-ports.v1" {
            guard buffer.isBinary, buffer.data.count <= DesktopPortLimits.packet else {
                Task { @MainActor [weak self] in self?.closePortChannel() }
                return
            }
            incomingPorts.enqueue(.init(label: dataChannel.label, data: buffer.data, binary: true), consume: { [weak self] in
                guard self?.closed == false else { return }; self?.onPortData?($0.data)
            }, overflow: { [weak self] in self?.closePortChannel() })
            return
        }
        guard buffer.data.count <= 32 * 1024 else { return }
        let message = DesktopMessageInbox.Message(label: dataChannel.label, data: buffer.data, binary: buffer.isBinary)
        if message.label == "system-audio", message.binary {
            incomingAudio.enqueue(message.data, on: .main) { [weak self] data in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.onAudio?(data)
                }
            }
            return
        }
        incomingMessages.enqueue(message, consume: { [weak self] message in
            self?.receive(message)
        }, overflow: { [weak self] in
            guard let self, !self.closed else { return }
            self.onState?(.failed)
        })
    }

    private func receive(_ message: DesktopMessageInbox.Message) {
        guard !closed else { return }
        let data = message.data
        if message.label == "desktop-files.v1", message.binary { onFile?(data); return }
        guard message.label == "control", !message.binary else { return }
        // Decode the discriminator once instead of trying every message type for every mouse move.
        struct Kind: Decodable { let kind: String }
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(Kind.self, from: data).kind else { return }
        switch kind {
        case "desktop-cursor.v1":
            if let value = try? decoder.decode(DesktopCursorMessage.self, from: data), value.isValid { onCursor?(value) }
        case "desktop-privacy.v1":
            if let value = try? decoder.decode(DesktopPrivacyMessage.self, from: data), value.isValid { onPrivacy?(value) }
        case "desktop-video.v1":
            if let value = try? decoder.decode(DesktopVideoMessage.self, from: data), value.isValid { onVideoSettings?(value) }
        case "desktop-clipboard.v1":
            if let value = try? decoder.decode(DesktopClipboardMessage.self, from: data), value.isValid { onClipboard?(value) }
        case "desktop-session.v1":
            if let value = try? decoder.decode(DesktopSessionStatus.self, from: data), value.isValid { onSessionStatus?(value) }
        case "desktop-security.v1":
            if let value = try? decoder.decode(DesktopRemoteSecurityMessage.self, from: data), value.isValid { onSecurity?(value) }
        default:
            if DesktopInputDiagnostics.systemEnabled,
               let value = try? decoder.decode(DesktopInputTrace.self, from: data), value.isValid { onInputTrace?(value) }
            else if let value = try? decoder.decode(DesktopInput.self, from: data), value.isValid {
                DesktopInputDiagnostics.record("received", input: value)
                onInput?(value)
            }
        }
    }
}

/// Reliable messages keep their order across temporary send failures; retries and memory are bounded.
@MainActor
final class DesktopReliableSender {
    private let limit: Int
    private let timeout: TimeInterval
    private let attempt: (Data) -> Bool
    private let failed: () -> Void
    private var pending: [(data: Data, deadline: TimeInterval, coalescible: Bool)] = []
    private var bytes = 0
    private var task: Task<Void, Never>?
    private var stopped = false
    var bufferedBytes: Int { bytes }
    private var flushing = false

    init(limit: Int, timeout: TimeInterval, send: @escaping (Data) -> Bool, failed: @escaping () -> Void) {
        self.limit = limit; self.timeout = timeout; attempt = send; self.failed = failed
    }
    func send(_ data: Data, coalescible: Bool = false) {
        guard !stopped else { return }
        var deadline = ProcessInfo.processInfo.systemUptime + timeout
        if coalescible, let last = pending.last, last.coalescible {
            // Replacement must not extend the deadline of a stalled stream indefinitely.
            deadline = last.deadline
            bytes -= pending.removeLast().data.count
        }
        guard bytes + data.count <= limit, pending.count < 256 else { fail(); return }
        pending.append((data, deadline, coalescible)); bytes += data.count
        flush()
        if !pending.isEmpty, task == nil, !stopped {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard let self, !Task.isCancelled, !self.stopped else { return }
                    self.flush()
                    if self.pending.isEmpty { self.task = nil; return }
                }
            }
        }
    }
    private func flush() {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while !stopped, let first = pending.first {
            guard ProcessInfo.processInfo.systemUptime < first.deadline else { fail(); return }
            guard attempt(first.data), !stopped else { return }
            pending.removeFirst(); bytes -= first.data.count
        }
    }
    private func fail() { close(); failed() }
    func close() { stopped = true; task?.cancel(); task = nil; pending.removeAll(); bytes = 0 }
}

/// Bound the queue before DispatchQueue.main, including while the UI is stalled.
final class DesktopMessageInbox: @unchecked Sendable {
    struct Message { let label: String; let data: Data; let binary: Bool }
    private let lock = NSLock()
    private var pending: [Message] = []
    private var bytes = 0
    private var scheduled = false
    private var stopped = false

    func enqueue(_ message: Message, consume: @escaping @MainActor (Message) -> Void,
                 overflow: @escaping @MainActor () -> Void) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard bytes + message.data.count <= 512 * 1024, pending.count < 256 else {
            stopped = true; pending.removeAll(); bytes = 0
            lock.unlock()
            DispatchQueue.main.async { overflow() }
            return
        }
        pending.append(message); bytes += message.data.count
        let needsSchedule = !scheduled; scheduled = true
        lock.unlock()
        if needsSchedule { DispatchQueue.main.async { self.drain(consume) } }
    }
    @MainActor private func drain(_ consume: @escaping @MainActor (Message) -> Void) {
        // Yield between small batches so input/UI work is not monopolized by a transfer.
        for _ in 0..<16 {
            lock.lock()
            guard !stopped, !pending.isEmpty else { scheduled = false; lock.unlock(); return }
            let message = pending.removeFirst(); bytes -= message.data.count
            lock.unlock()
            consume(message)
        }
        DispatchQueue.main.async { self.drain(consume) }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; pending.removeAll(); bytes = 0
    }
}
