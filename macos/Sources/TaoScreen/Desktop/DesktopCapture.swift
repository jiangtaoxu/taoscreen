import AVFoundation
import ScreenCaptureKit
import WebRTC

enum DesktopVideoQuality {
    /// Use backing pixels, not the display's logical point size. Bound 5K/6K and
    /// ultrawide displays without reducing ordinary Retina desktops to 1080p.
    static func captureSize(points: CGSize, pixelScale: CGFloat, preset: DesktopVideoPreset = .ultra) -> CGSize {
        let width = max(2, points.width * pixelScale)
        let height = max(2, points.height * pixelScale)
        let scale = min(1, CGFloat(preset.maximumLongEdge) / max(width, height), sqrt(CGFloat(preset.maximumPixels) / (width * height)))
        return CGSize(width: max(2, Int(width * scale) / 2 * 2),
                      height: max(2, Int(height * scale) / 2 * 2))
    }

    static func configuration(points: CGSize, pixelScale: CGFloat, sound: Bool, showsCursor: Bool = true,
                              preset: DesktopVideoPreset = .ultra) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = captureSize(points: points, pixelScale: pixelScale, preset: preset)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.framesPerSecond))
        config.queueDepth = 3
        // RTCMTLNSVideoView converts to I420, then uses a full-range BT.601
        // shader. Passing 420v or display-native P3 values washes out the image.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_601_4
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = showsCursor
        config.capturesAudio = sound
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        return config
    }
}

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @MainActor private var stream: SCStream?
    @MainActor private var configuration: SCStreamConfiguration?
    @MainActor private var capturePoints = CGSize.zero
    @MainActor private var pixelScale: CGFloat = 1
    @MainActor private var sound = false
    @MainActor private var preset = DesktopVideoPreset.ultra
    @MainActor private var configurationUpdates: Task<Void, Never>?
    @MainActor private(set) var showsCursor = true
    @MainActor var videoFormat: DesktopVideoFormat? {
        guard let configuration else { return nil }
        return DesktopVideoFormat(preset: preset, width: configuration.width, height: configuration.height)
    }
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let queue = DispatchQueue(label: "taoscreen.desktop.capture")
    private let audioDelivery = DesktopAudioMailbox()
    var audio: (@MainActor @Sendable (Data) -> Void)?
    var failed: (@Sendable (NSError) -> Void)?

    init(source: RTCVideoSource) {
        self.source = source
        capturer = RTCVideoCapturer(delegate: source)
    }
    @MainActor func start(displayID: CGDirectDisplayID, sound: Bool, showsCursor: Bool = true,
                          excludingWindowIDs: Set<CGWindowID> = [], preset: DesktopVideoPreset = .ultra) async throws {
        let filter = try await Self.contentFilter(displayID: displayID, excludingWindowIDs: excludingWindowIDs)
        let config = DesktopVideoQuality.configuration(points: filter.contentRect.size,
            pixelScale: CGFloat(filter.pointPixelScale), sound: sound, showsCursor: showsCursor, preset: preset)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if sound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
        guard self.stream === stream else { return }
        configuration = config
        capturePoints = filter.contentRect.size; pixelScale = CGFloat(filter.pointPixelScale)
        self.sound = sound; self.preset = preset
        self.showsCursor = showsCursor
    }

    @MainActor static func contentFilter(displayID: CGDirectDisplayID, excludingWindowIDs: Set<CGWindowID>) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CloudError(L10n.text("所选屏幕已断开。")) }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        guard Set(excluded.map(\.windowID)) == excludingWindowIDs else {
            throw CloudError(L10n.text("无法从远程画面排除隐私屏，共享已停止，请重新连接。"))
        }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }
    /// 调用方串行更新；采集尚未启动时，启动完成后再应用最新偏好。
    @MainActor func setCursorVisible(_ visible: Bool) async throws -> Bool {
        guard stream != nil, configuration != nil else { return false }
        try await updateConfiguration(cursor: visible)
        return true
    }

    @MainActor func setVideoPreset(_ preset: DesktopVideoPreset) async throws {
        try await updateConfiguration(preset: preset)
    }

    /// 每次基于上一次成功配置创建新对象，防止光标与画面更新在 await 期间互相覆盖。
    @MainActor private func updateConfiguration(preset: DesktopVideoPreset? = nil, cursor: Bool? = nil) async throws {
        let previous = configurationUpdates
        let update = Task { @MainActor in
            await previous?.value
            guard let stream = self.stream, self.configuration != nil else { throw CancellationError() }
            let nextPreset = preset ?? self.preset
            let nextCursor = cursor ?? self.showsCursor
            let next = DesktopVideoQuality.configuration(points: self.capturePoints, pixelScale: self.pixelScale,
                sound: self.sound, showsCursor: nextCursor, preset: nextPreset)
            try await stream.updateConfiguration(next)
            guard self.stream === stream else { throw CancellationError() }
            self.configuration = next; self.preset = nextPreset; self.showsCursor = nextCursor
        }
        // 尾任务只负责串行等待；错误由各自的调用方通过 update.value 接收。
        configurationUpdates = Task { _ = await update.result }
        try await update.value
    }
    @MainActor func stop() async {
        audioDelivery.close()
        let old = stream; stream = nil; configuration = nil
        let updates = configurationUpdates; configurationUpdates = nil
        await updates?.value
        try? await old?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failed?(error as NSError) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
                  let image = sampleBuffer.imageBuffer else { return }
            let nanos = Int64(CMTimeGetSeconds(sampleBuffer.presentationTimeStamp) * 1_000_000_000)
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: image), rotation: ._0, timeStampNs: nanos))
        } else if type == .audio {
            // ScreenCaptureKit's 48 kHz stereo Float32 samples become bounded interleaved PCM.
            // A separate lossy DataChannel keeps late audio from blocking keyboard events.
            guard let description = sampleBuffer.formatDescription,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mSampleRate == 48000, format.mChannelsPerFrame == 2,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, frames <= 4096 else { return }
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { list.unsafeMutablePointer.deallocate() }
            var retained: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
                bufferListOut: list.unsafeMutablePointer, bufferListSize: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retained) == noErr else { return }
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            guard list.count == (planar ? 2 : 1), list.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= frames * (planar ? 4 : 8) }) else { return }
            var samples = [Int16](repeating: 0, count: frames * 2)
            for frame in 0..<frames { for channel in 0..<2 {
                let buffer = list[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)
                let value = buffer[planar ? frame : frame * 2 + channel]
                samples[frame * 2 + channel] = Int16((min(1, max(-1, value.isFinite ? value : 0)) * 32767).rounded()).littleEndian
            } }
            audioDelivery.enqueue(samples.withUnsafeBytes { Data($0) }, on: .main) { [weak self] data in
                MainActor.assumeIsolated { self?.audio?(data) }
            }
        }
    }
}

/// PCM remains 48 kHz, stereo, 16-bit. Bound both memory and age before scheduling work.
struct DesktopAudioPendingBuffer {
    static let maximumAge: TimeInterval = 0.2
    static let maximumBytes = 38_400 // 200 ms, independent of packet size
    private var pending: [(data: Data, time: TimeInterval)] = []
    private(set) var bytes = 0
    mutating func append(_ data: Data, now: TimeInterval) -> Bool {
        guard !data.isEmpty, data.count <= 16_384, data.count % 4 == 0 else { return false }
        while let first = pending.first,
              bytes + data.count > Self.maximumBytes || pending.count >= 128 || now - first.time > Self.maximumAge {
            bytes -= pending.removeFirst().data.count
        }
        pending.append((data, now)); bytes += data.count
        return true
    }
    mutating func next(now: TimeInterval) -> Data? {
        while !pending.isEmpty {
            let first = pending.removeFirst(); bytes -= first.data.count
            if now - first.time <= Self.maximumAge { return first.data }
        }
        return nil
    }
    mutating func removeAll() { pending.removeAll(); bytes = 0 }
}

/// A single scheduled drain replaces one unbounded Dispatch/Task allocation per audio packet.
final class DesktopAudioMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = DesktopAudioPendingBuffer()
    private var scheduled = false
    private var stopped = false

    func enqueue(_ data: Data, on queue: DispatchQueue, consume: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        guard !stopped, buffer.append(data, now: ProcessInfo.processInfo.systemUptime) else { lock.unlock(); return }
        let needsSchedule = !scheduled; scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { self.drain(on: queue, consume: consume) } }
    }
    private func drain(on queue: DispatchQueue, consume: @escaping @Sendable (Data) -> Void) {
        // Limit each turn as well as the queue, including when producers continuously enqueue.
        for _ in 0..<8 {
            lock.lock()
            guard !stopped, let data = buffer.next(now: ProcessInfo.processInfo.systemUptime) else {
                scheduled = false; lock.unlock(); return
            }
            lock.unlock()
            consume(data)
        }
        queue.async { self.drain(on: queue, consume: consume) }
    }
    func removeAll() { lock.lock(); buffer.removeAll(); lock.unlock() }
    func close() { lock.lock(); stopped = true; buffer.removeAll(); lock.unlock() }
}

/// All engine and PCM work is confined to this serial queue, away from input/UI handling.
final class DesktopAudioPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "taoscreen.desktop.playback", qos: .userInitiated)
    private let mailbox = DesktopAudioMailbox()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var configurationObserver: NSObjectProtocol?
    private var queuedFrames = 0
    private var nextStartAttempt: TimeInterval = 0
    private var generation = 0

    func play(_ data: Data) {
        mailbox.enqueue(data, on: queue) { [weak self] data in self?.schedule(data) }
    }
    private func schedule(_ data: Data) {
        if let engine, !engine.isRunning { reset() }
        let frames = data.count / 4
        guard queuedFrames + frames <= 9600,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        if engine == nil {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= nextStartAttempt else { return }
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { nextStartAttempt = now + 1; return }
            nextStartAttempt = 0
            node.play(); self.engine = engine; self.node = node
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self, weak engine] _ in
                // Apple delivers this on an internal queue. Never tear the engine down there.
                guard let self else { return }
                self.queue.async { [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine else { return }
                    self.mailbox.removeAll(); self.reset()
                }
            }
        }
        pcm.frameLength = pcm.frameCapacity
        data.withUnsafeBytes { raw in
            for index in 0..<frames { for channel in 0..<2 {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (index * 2 + channel) * 2, as: Int16.self))
                pcm.floatChannelData![channel][index] = Float(sample) / 32768
            } }
        }
        queuedFrames += frames
        let token = generation
        node?.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }
    func stop() {
        mailbox.removeAll()
        queue.async { [self] in reset() }
    }
    private func reset() {
        generation += 1
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        node?.stop(); engine?.stop(); node = nil; engine = nil; queuedFrames = 0
    }
    deinit {
        mailbox.close()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        node?.stop(); engine?.stop()
    }
}
