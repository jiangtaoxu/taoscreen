import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import Testing
import WebRTC
@testable import TaoScreen

struct DesktopVideoSettingsTests {
    private func status(_ preset: DesktopVideoPreset = .ultra, id: UUID? = nil, failure: String? = nil) -> DesktopVideoMessage {
        .init(action: .status, requestID: id, preset: preset, width: preset.maximumLongEdge,
              height: preset.maximumLongEdge / 16 * 9, failure: failure)
    }

    @Test(arguments: DesktopVideoPreset.allCases)
    func captureUsesSelectedSizeAndFrameInterval(preset: DesktopVideoPreset) {
        let config = DesktopVideoQuality.configuration(points: CGSize(width: 2560, height: 1440), pixelScale: 2,
            sound: true, showsCursor: false, preset: preset)
        #expect(config.width == preset.maximumLongEdge)
        #expect(config.height == preset.maximumLongEdge / 16 * 9)
        #expect(config.minimumFrameInterval == CMTime(value: 1, timescale: Int32(preset.framesPerSecond)))
        #expect(config.capturesAudio && !config.showsCursor)
        #expect(config.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(config.colorSpaceName == CGColorSpace.sRGB)
        for points in [CGSize(width: 1080, height: 1920), CGSize(width: 5120, height: 1440),
                       CGSize(width: 1512, height: 982), CGSize(width: 800, height: 600)] {
            let size = DesktopVideoQuality.captureSize(points: points, pixelScale: 1, preset: preset)
            #expect(size.width <= points.width && size.height <= points.height)
            let format = DesktopVideoFormat(preset: preset, width: Int(size.width), height: Int(size.height))
            #expect(format.isValid)
            // 偶数像素取整误差小于两个像素，不裁剪或拉伸。
            #expect(abs(size.width / points.width - size.height / points.height) < 2 / min(points.width, points.height))
        }
        #expect(preset.initialBitrate <= preset.maximumBitrate)
    }

    @Test func defaultsPreserveExistingUltraConfiguration() throws {
        let config = DesktopVideoQuality.configuration(points: CGSize(width: 2560, height: 1440), pixelScale: 2, sound: false)
        #expect(config.width == 3840 && config.height == 2160)
        #expect(config.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(DesktopVideoPreset.ultra.initialBitrate == 8_000_000)
        #expect(DesktopVideoPreset.ultra.maximumBitrate == 24_000_000)
        let legacy = Data(#"{"viewerControlEnabled":false,"shortcutDestination":"remote","clipboardEnabled":false,"muted":true,"cursorMode":"remote"}"#.utf8)
        let preferences = try JSONDecoder().decode(DesktopViewerPreferences.self, from: legacy)
        #expect(preferences.videoPreset == nil)
        #expect(!preferences.viewerControlEnabled && preferences.cursorMode == .remote)
        let selection = DesktopVideoSelection()
        #expect(selection.preference == .ultra && selection.selectedPreset == .ultra)
        #expect(!selection.supported && selection.confirmed == nil)
        #expect(selection.statusText.contains("升级"))
    }

    @Test func protocolValidatesShapeAndRejectsMalformedOrUnknownValues() throws {
        for preset in DesktopVideoPreset.allCases {
            let request = DesktopVideoMessage(action: .request, requestID: UUID(), preset: preset)
            #expect(request.isValid)
            #expect(try JSONDecoder().decode(DesktopVideoMessage.self, from: JSONEncoder().encode(request)) == request)
            #expect(status(preset).isValid)
        }
        var value = status()
        value.width = Int.max
        #expect(!value.isValid) // 先界限检查，防止像素乘法溢出。
        value = status(); value.height = 1
        #expect(!value.isValid)
        value = status(); value.height = nil
        #expect(!value.isValid)
        value = status(); value.width = 3842
        #expect(!value.isValid)
        #expect(!DesktopVideoMessage(action: .request, preset: .standard).isValid)
        #expect(!DesktopVideoMessage(action: .request, requestID: UUID(), preset: .standard, failure: "拒绝").isValid)
        #expect(!DesktopVideoMessage(action: .status, preset: .ultra).isValid)
        #expect(DesktopVideoMessage(action: .status, preset: .ultra, failure: "采集不可用").isValid)
        #expect((try? JSONDecoder().decode(DesktopVideoMessage.self,
            from: Data(#"{"kind":"desktop-video.v1","action":"request","preset":"unknown"}"#.utf8))) == nil)
        #expect((try? JSONDecoder().decode(DesktopInput.self, from: JSONEncoder().encode(status())))?.isValid != true)
    }

    @Test func onlyMatchingSuccessConfirmsAndPersistsSelection() throws {
        var selection = DesktopVideoSelection()
        let result1 = selection.begin(.economy)
        #expect(result1 == nil)
        let result2 = selection.receive(status())
        #expect(result2)
        let requestValue = selection.begin(.smooth)
        let request = try #require(requestValue)
        #expect(selection.changing && selection.selectedPreset == .smooth)
        #expect(selection.preference == .ultra)
        let result3 = selection.begin(.standard)
        #expect(result3 == nil)
        let result4 = selection.receive(status(.smooth, id: UUID()))
        #expect(!result4)
        let result5 = selection.receive(status(.high, id: request.requestID))
        #expect(!result5)
        // 重建采集的主动消息不能确认另一个仍在进行的切换。
        let result6 = selection.receive(status())
        #expect(result6)
        #expect(selection.changing && selection.preference == .ultra)
        let result7 = selection.receive(status(.smooth, id: request.requestID))
        #expect(result7)
        #expect(!selection.changing && selection.request == nil)
        #expect(selection.preference == .smooth && selection.confirmed?.preset == .smooth)
        #expect(selection.retryPreset == nil)
        #expect(selection.statusText.contains("帧率上限 60"))
        let result8 = selection.receive(status(.standard, id: request.requestID))
        #expect(!result8)
    }

    @Test func timeoutLateAcknowledgementAndFailureNeverClaimUnconfirmedSuccess() throws {
        var selection = DesktopVideoSelection()
        selection.receive(status())
        let firstValue = selection.begin(.economy)
        let first = try #require(firstValue)
        selection.expire(UUID())
        #expect(selection.changing)
        selection.expire(try #require(first.requestID))
        #expect(!selection.changing && selection.confirmed == nil)
        #expect(selection.preference == .ultra && selection.failure != nil)
        let result9 = selection.receive(status(.economy, id: first.requestID))
        #expect(result9)
        #expect(selection.preference == .economy && selection.failure == nil)
        let secondValue = selection.begin(.smooth)
        let second = try #require(secondValue)
        selection.expire(try #require(second.requestID))
        let retryValue = selection.begin(.high)
        let retry = try #require(retryValue)
        let result10 = selection.receive(status(.smooth, id: second.requestID))
        #expect(!result10)
        let result11 = selection.receive(status(.economy, id: retry.requestID, failure: "切换失败，已恢复原配置"))
        #expect(result11)
        #expect(selection.preference == .economy && selection.selectedPreset == .economy)
        #expect(selection.retryPreset == .high)
        #expect(!selection.changing && selection.failure != nil)
        let unsentValue = selection.begin(.high)
        let unsent = try #require(unsentValue)
        selection.sendFailed(try #require(unsent.requestID))
        #expect(!selection.changing && selection.preference == .economy && selection.request == nil)
        #expect(selection.retryPreset == .high)
    }

    @Test @MainActor func switchingAppliesBothSettingsAndRestoresOnlyOnExplicitFailure() async throws {
        enum Failure: Error { case rejected }
        var events: [String] = []
        try await DesktopVideoUpdate.apply(.smooth, previous: .ultra, encoder: { events.append("encoder:\($0)") },
            capture: { events.append("capture:\($0)") })
        #expect(events == ["encoder:smooth", "capture:smooth"])
        events = []
        do {
            try await DesktopVideoUpdate.apply(.smooth, previous: .ultra, encoder: { events.append("encoder:\($0)") }, capture: {
                events.append("capture:\($0)")
                if $0 == .smooth { throw Failure.rejected }
            })
            Issue.record("切换失败不能报告成功")
        } catch DesktopVideoUpdateFailure.restored {
            #expect(events == ["encoder:smooth", "capture:smooth", "capture:ultra", "encoder:ultra"])
        }
        do {
            try await DesktopVideoUpdate.apply(.smooth, previous: .ultra, encoder: { _ in throw Failure.rejected },
                capture: { _ in throw Failure.rejected })
            Issue.record("原配置恢复失败必须报告状态无法确认")
        } catch DesktopVideoUpdateFailure.unknown { }
    }

    @Test @MainActor func confirmedPreferenceIsIsolatedByAccountServerAndDeviceAndSurvivesReconnect() throws {
        let suite = "taoscreen.desktop.video.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = CloudAccount(server: "https://video.example.test", userID: UUID(), email: "test@example.test")
        defaults.set(try JSONEncoder().encode(account), forKey: DesktopAccountState.accountKey)
        let peer = DesktopPeer(id: UUID(), name: "Video Mac")
        DesktopViewerPreferences(videoPreset: .smooth).save(accountID: account.id, peerID: peer.id, defaults: defaults)
        let cloud = DesktopAccountState(defaults: defaults)
        let center = DesktopCenter(defaults: defaults)
        center.attach(cloud: cloud)
        defer { center.shutdown() }
        let viewer = center.prepareViewer(for: peer)
        #expect(viewer.videoSelection.preference == .smooth)
        let other = center.prepareViewer(for: .init(id: UUID(), name: peer.name))
        #expect(other.videoSelection.preference == .ultra)
        viewer.receiveVideoSettings(status())
        #expect(viewer.videoSelection.preference == .smooth && viewer.videoSelection.confirmed?.preset == .ultra)
        viewer.requestVideoPreset(.economy) // 未连接，不能发送或保存新选择。
        #expect(viewer.videoSelection.preference == .smooth)
        viewer.disconnect(notify: false)
        #expect(!viewer.videoSelection.supported && viewer.videoSelection.confirmed == nil)
        #expect(center.prepareViewer(for: .init(id: peer.id, name: "Renamed")).videoSelection.preference == .smooth)
        for accountID in [CloudAccount(server: account.server, userID: UUID(), email: account.email).id,
                          CloudAccount(server: "https://other.example.test", userID: account.userID, email: account.email).id] {
            #expect(DesktopViewerPreferences.load(accountID: accountID, peerID: peer.id, defaults: defaults).videoPreset == nil)
        }
    }

    @Test(arguments: [true, false])
    @MainActor func desktopNegotiatesH264LevelAndRetainsVP8Fallback(offersH264: Bool) async throws {
        let configuration = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: configuration, host: true)
        let viewer = try DesktopRTC(configuration: configuration, host: false)
        defer { host.close(); viewer.close() }
        let original = try await viewer.makeDescription(offer: true)
        var lines = original.components(separatedBy: "\r\n")
        let highProfile = DesktopH264.supportsUltra ? "640c33" : "640c1f"
        #expect(original.contains("profile-level-id=\(highProfile)"))
        // 模拟只提供 VP8 的控制端。
        if !offersH264 {
            let videoIndex = try #require(lines.firstIndex { $0.hasPrefix("m=video ") })
            let video = lines[videoIndex].split(separator: " ")
            let payloads = video.dropFirst(3)
            let vp8 = try #require(payloads.first { payload in
                lines.contains { $0.hasPrefix("a=rtpmap:\(payload) VP8/") }
            })
            lines[videoIndex] = (Array(video.prefix(3)) + [vp8]).joined(separator: " ")
            let removed = payloads.filter { $0 != vp8 }
            lines.removeAll { line in
                removed.contains { payload in
                    line.hasPrefix("a=rtpmap:\(payload) ") || line.hasPrefix("a=fmtp:\(payload) ")
                        || line.hasPrefix("a=rtcp-fb:\(payload) ")
                }
            }
        }
        try await host.setRemote(lines.joined(separator: "\r\n"), offer: true)
        let answer = try await host.makeDescription(offer: false)
        let answerLines = answer.components(separatedBy: "\r\n")
        let answerVideo = try #require(answerLines.first { $0.hasPrefix("m=video ") })
        let preferred = try #require(answerVideo.split(separator: " ").dropFirst(3).first)
        let expected = offersH264 ? "H264" : "VP8"
        #expect(answerLines.contains { $0.hasPrefix("a=rtpmap:\(preferred) \(expected)/") })
        if offersH264 {
            #expect(answerLines.contains {
                $0.hasPrefix("a=fmtp:\(preferred) ") && $0.contains("profile-level-id=\(highProfile)")
            })
        }
    }

    @Test @MainActor func nativePeersSwitchPresetsWithoutRenegotiatingAndConfirmActualEncoderParameters() async throws {
        let configuration = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: configuration, host: true)
        let viewer = try DesktopRTC(configuration: configuration, host: false)
        defer { host.close(); viewer.close() }
        let probe = DesktopVideoFrameProbe()
        // RTCVideoTrack 包装对象析构会移除 renderer，需与会话一样持有至测试结束。
        var remoteVideo: RTCVideoTrack?
        defer { remoteVideo?.remove(probe) }
        let capturer = RTCVideoCapturer(delegate: host.source)
        var selection = DesktopVideoSelection()
        var requests: [UUID] = []
        var unexpectedInput = false
        var capturePreset = DesktopVideoPreset.ultra
        let screenSize = CGSize(width: 3840, height: 2160)
        var captureSize = screenSize
        var viewerOpen = false
        var switchTask: Task<Void, Never>?
        host.onSignal = { type, payload in if type == "candidate" { viewer.addCandidate(payload) } }
        viewer.onSignal = { type, payload in if type == "candidate" { host.addCandidate(payload) } }
        host.onControlOpen = {
            host.sendVideoSettings(.init(action: .status, preset: .ultra, width: Int(screenSize.width), height: Int(screenSize.height)))
        }
        host.onInput = { _ in unexpectedInput = true }
        viewer.onControlOpen = { viewerOpen = true }
        viewer.onVideo = { remoteVideo = $0; $0.add(probe) }
        viewer.onVideoSettings = { selection.receive($0) }
        host.onVideoSettings = { value in
            guard value.action == .request, let id = value.requestID else { Issue.record("应收到带 ID 的画面请求"); return }
            requests.append(id)
            switchTask = Task { @MainActor in
                do {
                    try await DesktopVideoUpdate.apply(value.preset, previous: capturePreset,
                        encoder: { try host.setVideoPreset($0) }, capture: {
                            captureSize = DesktopVideoQuality.captureSize(points: screenSize, pixelScale: 1, preset: $0)
                            capturePreset = $0
                        })
                    host.sendVideoSettings(.init(action: .status, requestID: id, preset: capturePreset,
                        width: Int(captureSize.width), height: Int(captureSize.height)))
                } catch { Issue.record(error) }
            }
        }
        let offer = try await viewer.makeDescription(offer: true)
        try await host.setRemote(offer, offer: true)
        let answer = try await host.makeDescription(offer: false)
        try await viewer.setRemote(answer, offer: false)
        let openingDeadline = Date().addingTimeInterval(10)
        while !(viewerOpen && selection.supported) && Date() < openingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(viewerOpen && selection.supported)
        #expect(host.hasVideoConfiguration(.ultra))

        // 同一条 ICE/DTLS/SCTP/RTP 连接连续改变帧率、码率和输入尺寸。
        for preset in DesktopVideoPreset.allCases + [.economy, .ultra] {
            let requested = selection.begin(preset)
            let request = try #require(requested)
            #expect(viewer.sendVideoSettings(request))
            let confirmationDeadline = Date().addingTimeInterval(6)
            while selection.changing && Date() < confirmationDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!selection.changing)
            #expect(selection.preference == preset && selection.confirmed?.preset == preset)
            #expect(host.videoPreset == preset && host.hasVideoConfiguration(preset))
            let format = try #require(selection.confirmed)
            var pixelBuffer: CVPixelBuffer?
            try #require(CVPixelBufferCreate(kCFAllocatorDefault, format.width, format.height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
            let pixels = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
                memset(CVPixelBufferGetBaseAddressOfPlane(pixels, plane), plane == 0 ? 96 : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let initialFrames = probe.count(width: format.width, height: format.height)
            let frameDeadline = Date().addingTimeInterval(8)
            while probe.count(width: format.width, height: format.height) <= initialFrames && Date() < frameDeadline {
                host.source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels),
                    rotation: ._0, timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(probe.count(width: format.width, height: format.height) > initialFrames)
        }
        await switchTask?.value
        #expect(requests.count == 7 && Set(requests).count == 7)
        #expect(!unexpectedInput)
    }

    @Test @MainActor func settingsLayoutSupportsLongContent() throws {
        _ = NSApplication.shared
        let center = DesktopCenter()
        defer { center.shutdown() }
        let viewer = center.prepareViewer(for: .init(id: UUID(), name: "MacBook Pro"))
        viewer.receiveVideoSettings(status())
        viewer.receiveRTCState(.connected, id: try #require(viewer.sessionID))
        let view = NSHostingView(rootView: DesktopViewerSettings(center: viewer)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 550),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil }
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 550)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width == 380 && view.fittingSize.height == 550)
        if let path = ProcessInfo.processInfo.environment["TAOSCREEN_VIDEO_SETTINGS_PREVIEW"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}

private final class DesktopVideoFrameProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: Int] = [:]
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); defer { lock.unlock() }
        frames["\(frame.width)x\(frame.height)", default: 0] += 1
    }
    func count(width: Int, height: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return frames["\(width)x\(height)", default: 0]
    }
}
