import AppKit
import CoreVideo
import CryptoKit
import Foundation
import SwiftUI
import ScreenCaptureKit
import Testing
import WebRTC
@testable import TaoScreen

struct DesktopPerformanceTests {
    @Test func audioBufferBoundsMemoryAndDropsStaleSamples() {
        var buffer = DesktopAudioPendingBuffer()
        for index in 0..<10_000 {
            let accepted = buffer.append(Data(repeating: UInt8(index % 251), count: 1920), now: 10)
            #expect(accepted)
            #expect(buffer.bytes <= DesktopAudioPendingBuffer.maximumBytes)
        }
        var samples: [Data] = []
        while let data = buffer.next(now: 10) { samples.append(data) }
        #expect(samples.count == 20)
        #expect(samples.first?.first == UInt8(9980 % 251))
        #expect(samples.last?.first == UInt8(9999 % 251))
        #expect(buffer.bytes == 0)
        let invalid = buffer.append(Data([1]), now: 10)
        let oversized = buffer.append(Data(repeating: 0, count: 16_388), now: 10)
        let valid = buffer.append(Data(repeating: 0, count: 1920), now: 10)
        let expired = buffer.next(now: 10.201)
        #expect(!invalid && !oversized && valid)
        #expect(expired == nil)
        #expect(buffer.bytes == 0)
    }

    @Test func audioMailboxClearsPendingWorkAndRejectsPacketsAfterClose() async {
        let queue = DispatchQueue(label: "desktop-audio-mailbox-test")
        let mailbox = DesktopAudioMailbox(), sink = DesktopAudioTestSink()
        queue.suspend()
        for _ in 0..<1000 {
            mailbox.enqueue(Data(repeating: 1, count: 1920), on: queue) { sink.add($0) }
        }
        mailbox.removeAll()
        mailbox.enqueue(Data(repeating: 2, count: 1920), on: queue) { sink.add($0) }
        queue.resume()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(sink.values.map(\.first) == [2])
        mailbox.close()
        mailbox.enqueue(Data(repeating: 3, count: 1920), on: queue) { sink.add($0) }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(sink.values.map(\.first) == [2])
    }

    @Test @MainActor func reliableSenderRetriesInOrderWithoutDuplicatingAcceptedMessages() async throws {
        var writable = false, rejectSecondOnce = true
        var delivered: [Data] = [], failures = 0
        let sender = DesktopReliableSender(limit: 1024, timeout: 5, send: { data in
            guard writable else { return false }
            if data == Data([1]), rejectSecondOnce { rejectSecondOnce = false; return false }
            delivered.append(data); return true
        }, failed: { failures += 1 })
        defer { sender.close() }
        for value in UInt8(0)...3 { sender.send(Data([value])) }
        #expect(delivered.isEmpty)
        writable = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while delivered.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered == [Data([0]), Data([1]), Data([2]), Data([3])])
        #expect(failures == 0)
        sender.close(); sender.send(Data([4]))
        #expect(delivered.count == 4)
    }

    @Test(arguments: [false, true]) @MainActor func reliableSenderFailsOnceOnTimeoutOrOverflow(overflow: Bool) async throws {
        var failures = 0, attempts = 0
        let sender = DesktopReliableSender(limit: 4, timeout: 0.03, send: { _ in attempts += 1; return false }, failed: { failures += 1 })
        sender.send(Data(repeating: 0, count: 4))
        if overflow { sender.send(Data([1])) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while failures == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failures == 1)
        let oldAttempts = attempts
        sender.send(Data([2]))
        try await Task.sleep(for: .milliseconds(40))
        #expect(attempts == oldAttempts)
        #expect(failures == 1)
    }

    @Test @MainActor func hoverCoalescingDoesNotCrossClickOrDragBoundaries() async throws {
        var writable = false
        var delivered: [UInt8] = []
        let sender = DesktopReliableSender(limit: 1024, timeout: 5, send: { data in
            guard writable else { return false }
            delivered.append(data[0]); return true
        }, failed: { Issue.record("unexpected send failure") })
        defer { sender.close() }
        for value in UInt8(0)..<100 { sender.send(Data([value]), coalescible: true) }
        sender.send(Data([100])) // mouse down
        sender.send(Data([101])) // drag point 1
        sender.send(Data([102])) // drag point 2
        sender.send(Data([103])) // mouse up
        sender.send(Data([104]), coalescible: true)
        sender.send(Data([105]), coalescible: true)
        sender.send(Data([106])) // key/release barrier
        writable = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while delivered.count < 7, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered == [99, 100, 101, 102, 103, 105, 106])
    }

    @Test(arguments: [1, 32 * 1024]) @MainActor func messageIngressIsBoundedBeforeTheMainQueueRuns(packetSize: Int) async throws {
        let inbox = DesktopMessageInbox()
        var received = 0, failures = 0
        for _ in 0..<1000 {
            inbox.enqueue(.init(label: "control", data: Data(repeating: 0, count: packetSize), binary: false),
                          consume: { _ in received += 1 }, overflow: { failures += 1 })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while failures == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failures == 1)
        #expect(received == 0)
        inbox.close()
    }

    @Test @MainActor func messageIngressPreservesOrderAcrossBatchesAndStopsOnClose() async throws {
        let inbox = DesktopMessageInbox()
        var received: [UInt8] = []
        for value in UInt8(0)..<100 {
            inbox.enqueue(.init(label: "control", data: Data([value]), binary: false),
                          consume: { received.append($0.data[0]) }, overflow: { Issue.record("unexpected overflow") })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while received.count < 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received == Array(UInt8(0)..<100))
        inbox.enqueue(.init(label: "control", data: Data([100]), binary: false),
                      consume: { received.append($0.data[0]) }, overflow: {})
        inbox.close()
        try await Task.sleep(for: .milliseconds(20))
        #expect(received.count == 100)
    }

    @Test @MainActor func fileAcknowledgementRetriesAndBackgroundTransferPreservesBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-background-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("source.bin")
        try data.write(to: source)
        var outgoing: DesktopFileTransfer?, delivered: [URL] = []
        var rejectAck = true, rejected = false, finished = false
        let incoming = DesktopFileTransfer(host: true, root: root.appendingPathComponent("received"), allowed: { true }, send: { bytes in
            if rejectAck { rejected = true; return false }
            outgoing?.receive(bytes); return true
        })
        incoming.onFiles = { urls, _ in delivered = urls }
        outgoing = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: { incoming.receive($0); return true })
        outgoing?.onState = { finished = $0.phase == .completed }
        #expect(outgoing?.send([source], paste: false) == true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !rejected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rejected)
        #expect(!finished)
        rejectAck = false
        while !finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
        let destination = try #require(delivered.first)
        #expect(try Data(contentsOf: destination) == data)
        outgoing?.close(); incoming.close()
        await incoming.waitForReceiving()
        // Closing a session must not remove completed files.
        #expect(try Data(contentsOf: destination) == data)
    }
}

private final class DesktopAudioTestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Data] = []
    func add(_ value: Data) { lock.lock(); samples.append(value); lock.unlock() }
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return samples }
}

struct DesktopTests {
    @Test @MainActor func viewerPreferencesSurviveDisconnectAndNewCentersByDevice() throws {
        let suite = "taoscreen.desktop.preferences.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let account = CloudAccount(server: "https://desktop.example.test", userID: UUID(), email: "test@example.test")
        defaults.set(try JSONEncoder().encode(account), forKey: DesktopAccountState.accountKey)
        let cloud = DesktopAccountState(defaults: defaults)
        let center = DesktopCenter(defaults: defaults)
        center.attach(cloud: cloud)
        defer { center.shutdown() }
        let firstPeer = DesktopPeer(id: UUID(), name: "Mac")
        let secondPeer = DesktopPeer(id: UUID(), name: "Mac") // 同名电脑也应独立记录。
        let first = center.prepareViewer(for: firstPeer)
        let second = center.prepareViewer(for: secondPeer)
        first.viewerControlEnabled = false
        first.shortcutDestination = .remote // 不触发系统授权提示或实际快捷键接管。
        first.clipboardEnabled = false
        first.muted = true
        first.cursorMode = .remote
        first.localInputEnabled = false
        let expected = DesktopViewerPreferences(viewerControlEnabled: false, shortcutDestination: .remote,
                                               clipboardEnabled: false, muted: true, cursorMode: .remote, localInputEnabled: false)
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: firstPeer.id, defaults: defaults) == expected)
        #expect(second.viewerControlEnabled && second.clipboardEnabled && !second.muted)
        #expect(second.shortcutDestination == .local && second.cursorMode == .local)
        #expect(defaults.string(forKey: "taoscreen.desktop.cursorMode") == nil)
        first.disconnect(notify: false)
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: firstPeer.id, defaults: defaults) == expected)
        // 新中心、新 UserDefaults 实例模拟重开，设备改名仍恢复原来的五项选择。
        let reopened = DesktopCenter(defaults: try #require(UserDefaults(suiteName: suite)))
        reopened.attach(cloud: cloud)
        defer { reopened.shutdown() }
        let restored = reopened.prepareViewer(for: .init(id: firstPeer.id, name: "Renamed Mac"))
        #expect(!restored.viewerControlEnabled && !restored.clipboardEnabled && restored.muted)
        #expect(restored.shortcutDestination == .remote && restored.cursorMode == .remote)
        #expect(!restored.localInputEnabled && second.localInputEnabled)
        #expect(!restored.remoteShortcutsActive && !restored.acceptsViewerInput)
        restored.setShortcutDestination(.local)
        restored.viewerControlEnabled = true
        restored.clipboardEnabled = true
        restored.muted = false
        restored.cursorMode = .local
        restored.localInputEnabled = true
        restored.disconnect(notify: false)
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: firstPeer.id, defaults: defaults) == .init())
    }

    @Test func viewerPreferencesIsolateAccountsAndServersAndMigrateLegacyCursor() throws {
        let suite = "taoscreen.desktop.preferences.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peerID = UUID()
        let account = CloudAccount(server: "https://one.example", userID: UUID(), email: "test@example.test")
        let otherUser = CloudAccount(server: account.server, userID: UUID(), email: account.email)
        let otherServer = CloudAccount(server: "https://two.example", userID: account.userID, email: account.email)
        let saved = DesktopViewerPreferences(shortcutDestination: .remote, muted: true)
        saved.save(accountID: account.id, peerID: peerID, defaults: defaults)
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: peerID, defaults: defaults) == saved)
        for id in [otherUser.id, otherServer.id, nil] {
            #expect(DesktopViewerPreferences.load(accountID: id, peerID: peerID, defaults: defaults) == .init())
        }
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: UUID(), defaults: defaults) == .init())
        defaults.set("remote", forKey: "taoscreen.desktop.cursorMode")
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: UUID(), defaults: defaults).cursorMode == .remote)
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: peerID, defaults: defaults) == saved)
        defaults.set(Data("invalid".utf8), forKey: "taoscreen.desktop.viewer.\(account.id).\(peerID.uuidString)")
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: peerID, defaults: defaults) == .init(cursorMode: .remote))
        defaults.set("invalid", forKey: "taoscreen.desktop.cursorMode")
        #expect(DesktopViewerPreferences.load(accountID: account.id, peerID: peerID, defaults: defaults) == .init())
        let legacy = Data(#"{"viewerControlEnabled":false,"shortcutDestination":"remote","clipboardEnabled":false,"muted":true,"cursorMode":"remote"}"#.utf8)
        defaults.set(legacy, forKey: "taoscreen.desktop.viewer.\(account.id).\(peerID.uuidString)")
        let migrated = DesktopViewerPreferences.load(accountID: account.id, peerID: peerID, defaults: defaults)
        #expect(migrated.localInputEnabled == nil && !migrated.viewerControlEnabled && migrated.shortcutDestination == .remote)
    }

    @MainActor private func focusedInputSurface() throws -> (NSWindow, DesktopVideoNSView) {
        _ = NSApplication.shared
        let view = DesktopVideoNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.canControl = true
        view.layout()
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 320, y: 180), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        return (window, view)
    }

    @Test @MainActor func inputMethodCommitsVoiceAndCompositionWithoutReadingLocalClipboard() throws {
        let (window, view) = try focusedInputSurface()
        defer { window.close() }
        var texts: [String] = []
        var inputs: [DesktopInput] = []
        view.commitText = { texts.append($0) }
        view.send = { inputs.append($0) }
        let clipboardCount = NSPasteboard.general.changeCount
        let unspecified = NSRange(location: NSNotFound, length: 0)
        #expect(view.inputContext != nil)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
        #expect(view.hasMarkedText() && texts.isEmpty && inputs.isEmpty)
        #expect(view.markedRange() == NSRange(location: 0, length: 5))
        view.setMarkedText(NSAttributedString(string: "你好👋🏽"), selectedRange: NSRange(location: 99, length: 99), replacementRange: view.markedRange())
        #expect(view.selectedRange().location == "你好👋🏽".utf16.count)
        #expect(view.selectedRange().length == 0)
        var actual = unspecified
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: Int.max), actualRange: &actual)?.string == "你好👋🏽")
        #expect(view.attributedSubstring(forProposedRange: unspecified, actualRange: nil) == nil)
        view.insertText(NSAttributedString(string: "你好👋🏽"), replacementRange: view.markedRange())
        // 两个 NSResponder / NSTextInputClient 入口，以及辅助功能插入均支持异步提交。
        let responder: NSResponder = view
        responder.insertText("语音识别完成。")
        responder.insertText(NSAttributedString(string: "第二段\nEnglish 🎤"))
        view.setAccessibilitySelectedText("辅助功能提交")
        #expect(texts == ["你好👋🏽", "语音识别完成。", "第二段\nEnglish 🎤", "辅助功能提交"])
        #expect(!view.hasMarkedText())
        #expect(inputs.allSatisfy { $0.kind == "release" })
        #expect(NSPasteboard.general.changeCount == clipboardCount)
        #expect(!view.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")))
    }

    @Test @MainActor func lateInputMethodResultsAreRejectedAfterFocusOrSessionChanges() throws {
        let (window, view) = try focusedInputSurface()
        defer { window.close() }
        var texts: [String] = []
        view.commitText = { texts.append($0) }
        let unspecified = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("尚未确认", selectedRange: NSRange(location: 4, length: 0), replacementRange: unspecified)
        view.inputIsCurrent = { false }
        view.insertText("旧连接的语音结果")
        view.setAccessibilitySelectedText("旧连接的辅助功能结果")
        view.inputIsCurrent = { true }
        view.releaseKeyboardFocus()
        #expect(!view.hasMarkedText())
        view.insertText("失焦后的语音结果")
        view.setMarkedText("迟到的候选", selectedRange: .init(location: 0, length: 0), replacementRange: unspecified)
        #expect(!view.hasMarkedText() && texts.isEmpty)
        #expect(!view.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedText:")))
        // 重新允许控制或重新显示画面不能自动接收上次听写的结果。
        view.canControl = false; view.canControl = true
        view.insertText("尚未点击画面")
        view.localInputEnabled = false
        #expect(view.inputContext == nil)
        view.insertText("已关闭本机输入法")
        #expect(texts.isEmpty)
    }

    @Test @MainActor func localInputShortcutsBypassCaptureAndPlainKeysStillHaveMatchingKeyUps() throws {
        let (window, view) = try focusedInputSurface()
        defer { window.close() }
        var inputs: [DesktopInput] = []
        view.send = { inputs.append($0) }
        func event(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: key))
        }
        // 通过真实 AppKit 输入上下文派发普通英文，确认不会再叠加一次文本粘贴。
        var committed: [String] = []
        view.commitText = { committed.append($0) }
        view.keyDown(with: try event(.keyDown, key: 0, text: "a"))
        view.keyUp(with: try event(.keyUp, key: 0, text: "a"))
        #expect(inputs.filter { $0.kind == "key" }.map(\.down) == [true, false])
        #expect(committed.isEmpty)
        view.shortcutDestination = .remote
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 320, y: 180), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        inputs.removeAll()
        for e in [try event(.flagsChanged, key: 63, flags: .function), try event(.keyDown, key: 49, flags: .control),
                  try event(.keyDown, key: 49, flags: [.control, .shift]), try event(.keyDown, key: 0, text: "a")] {
            #expect(!view.handleCapturedKey(e))
            #expect(!view.performKeyEquivalent(with: e))
        }
        #expect(inputs.isEmpty)
        #expect(view.handleCapturedKey(try event(.keyDown, key: 12, flags: .command)))
        #expect(view.handleCapturedKey(try event(.keyUp, key: 12, flags: .command)))
        #expect(inputs.map(\.down) == [true, false])
    }

    @Test func committedTextUsesExistingPasteProtocolWithSizeLimitsAndNoSubmit() throws {
        let text = "语音输入完成👋🏽\n第二行 English"
        let inputs = try DesktopInput.textPaste(text)
        #expect(inputs.map(\.kind) == ["release", "clipboard", "key", "key"])
        #expect(inputs[1].text == text)
        #expect(inputs.suffix(2).allSatisfy { $0.key == 9 && $0.flags == CGEventFlags.maskCommand.rawValue })
        #expect(inputs.suffix(2).map(\.down) == [true, false])
        #expect(inputs.allSatisfy { $0.isValid })
        #expect(try DesktopInput.textPaste("").isEmpty)
        #expect(throws: (any Error).self) { try DesktopInput.textPaste(String(repeating: "中", count: 6000)) }
        #expect(throws: (any Error).self) { try DesktopInput.textPaste(String(repeating: "\u{01}", count: 16000)) }
        #expect(try DesktopInput.textPaste(String(repeating: "a", count: 16 * 1024)).count == 4)
    }

    @Test func connectionDurationUsesMonotonicTimeAndDoesNotWrapAfterADay() {
        var timing = DesktopConnectionTiming()
        #expect(timing.startedAt == nil && timing.elapsed(uptime: 100) == nil)
        #expect(DesktopConnectionTiming.durationText(nil) == "—")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        timing.start(date: start, uptime: 100)
        // 系统时间改变、同会话再次 connected，都不能重置计时。
        timing.start(date: start.addingTimeInterval(-3600), uptime: 160)
        #expect(timing.startedAt == start)
        #expect(timing.elapsed(uptime: 161) == 61)
        #expect(DesktopConnectionTiming.durationText(timing.elapsed(uptime: 161)) == "00:01:01")
        #expect(DesktopConnectionTiming.durationText(timing.elapsed(uptime: 100 + 26 * 3600 + 61)) == "26:01:01")
        #expect(DesktopConnectionTiming.durationText(0) == "00:00:00")
    }

    @Test @MainActor func establishedSessionsRenewIndependentlyAndSurviveRTCRecovery() async throws {
        let center = DesktopCenter()
        defer { center.shutdown() }
        await center.receive(.init(type: "hello", payload: .init(resume: true, keepalive: true)))
        let first = center.prepareViewer(for: .init(id: UUID(), name: "First Mac"))
        let second = center.prepareViewer(for: .init(id: UUID(), name: "Second Mac"))
        let firstID = try #require(first.sessionID), secondID = try #require(second.sessionID)
        #expect(first.sessionKeepalive() == nil) // 未建立连接不能延长邀请。
        first.receiveRTCState(.connected, id: firstID)
        second.receiveRTCState(.connected, id: secondID)
        let connectedAt = try #require(first.connectionTiming.startedAt)
        #expect(first.sessionKeepalive()?.id == firstID)
        #expect(first.sessionKeepalive()?.to == first.peer?.id)
        #expect(second.sessionKeepalive()?.id == secondID)
        first.receiveRTCState(.disconnected, id: firstID)
        #expect(first.sessionEstablished && !first.connected)
        first.receiveRTCState(.connected, id: firstID)
        #expect(first.connectionTiming.startedAt == connectedAt)
        #expect(first.connected && first.sessionKeepalive()?.type == "keepalive")
        // 旧连接的迟到状态不能清理当前会话。
        first.receiveRTCState(.closed, id: UUID())
        #expect(first.connected)
        first.disconnect(notify: false)
        #expect(first.connectionTiming.startedAt == nil && first.connectionTiming.elapsed() == nil)
        #expect(!first.sessionEstablished && first.sessionKeepalive() == nil)
        #expect(second.connected && second.sessionKeepalive()?.id == secondID)
        // 兼容旧服务端，不发送它无法识别的续期消息。
        await center.receive(.init(type: "hello", payload: .init(resume: true)))
        #expect(second.sessionKeepalive() == nil)
        await center.receive(.init(type: "hello", payload: .init(resume: true, keepalive: true)))
        #expect(second.sessionKeepalive()?.id == secondID)
    }

    @Test func signalRecoveryNeverExtendsGraceOrAcceptsStaleConfirmation() {
        var recovery = DesktopSignalRecovery()
        let began = recovery.begin(now: 100)
        #expect(began)
        let original = recovery.token
        #expect(recovery.deadline == 160)
        let continued = recovery.begin(now: 150)
        #expect(continued)
        #expect(recovery.token == original && recovery.deadline == 160)
        let wrongToken = recovery.confirm(UUID(), now: 151)
        let missingToken = recovery.confirm(nil, now: 151)
        #expect(!wrongToken && !missingToken)
        #expect(recovery.isRecovering)
        let confirmed = recovery.confirm(original, now: 159)
        #expect(confirmed)
        #expect(!recovery.isRecovering)
        let restarted = recovery.begin(now: 200)
        let stale = recovery.confirm(original, now: 201)
        let expired = recovery.begin(now: 260)
        let late = recovery.confirm(recovery.token, now: 260)
        #expect(restarted && !stale && !expired && !late)
        recovery.reset() // 用户断开/切换账号不能保留恢复状态。
        #expect(!recovery.isRecovering && recovery.token == nil)
    }

    @Test @MainActor func viewerSessionsRouteByConnectionAndKeepOtherTabsAlive() async throws {
        let center = DesktopCenter()
        defer { center.shutdown() }
        let firstPeer = DesktopPeer(id: UUID(), name: "Mac Studio")
        let secondPeer = DesktopPeer(id: UUID(), name: "MacBook Pro")
        let first = center.prepareViewer(for: firstPeer)
        let second = center.prepareViewer(for: secondPeer)
        #expect(center.prepareViewer(for: firstPeer) === first)
        #expect(center.viewerSessions.count == 2)
        #expect(first.sessionID != second.sessionID)
        center.selectViewer(second.id)
        #expect(center.selectedViewer === second)
        // 会话 ID 正确但发送设备不符，不得结束任何标签。
        await center.receive(.init(type: "end", id: first.sessionID, from: secondPeer.id))
        #expect(center.viewerSessions.count == 2)
        await center.receive(.init(type: "end", id: first.sessionID, from: firstPeer.id))
        #expect(center.viewerSessions.count == 1)
        #expect(center.message?.contains(firstPeer.name) == true)
        #expect(center.selectedViewer === second)
        #expect(second.sessionID != nil)
        // 根中心的本机共享结束，不得连带关闭观看会话。
        center.disconnect(notify: false)
        #expect(center.viewerSessions.count == 1)
        center.shutdown()
        #expect(center.viewerSessions.isEmpty && center.selectedViewer == nil)
        #expect(second.sessionID == nil)
    }

    @Test @MainActor func dismantlingVideoSurfaceDoesNotPublishDragHover() {
        _ = NSApplication.shared
        let surface = DesktopVideoNSView(frame: .zero)
        var hoverChanges: [Bool] = []
        var inputs: [DesktopInput] = []
        surface.dragHover = { hoverChanges.append($0) }
        surface.send = { inputs.append($0) }

        surface.dismantle()
        #expect(hoverChanges.isEmpty)
        #expect(surface.dragHover == nil)
        #expect(inputs.contains { $0.kind == "release" })
        #expect(!surface.keyboardFocusRequested)
        // AppKit 在拆除后补发拖拽退出事件，也不能再触达 SwiftUI 状态。
        surface.draggingExited(nil)
        #expect(hoverChanges.isEmpty)
    }

    @Test @MainActor func hidingAndSwitchingViewersClearDragHoverBeforeTeardown() {
        let center = DesktopCenter()
        defer { center.shutdown() }
        let first = center.prepareViewer(for: .init(id: UUID(), name: "First Mac"))
        let second = center.prepareViewer(for: .init(id: UUID(), name: "Second Mac"))
        center.selectViewer(first.id)
        first.setViewerPresented(true)
        first.fileDragHover = true
        center.selectViewer(second.id)
        #expect(!first.fileDragHover)
        #expect(first.sessionID != nil && second.sessionID != nil)

        second.setViewerPresented(true)
        second.fileDragHover = true
        second.setViewerPresented(true)
        #expect(second.fileDragHover)
        second.setViewerPresented(false)
        #expect(!second.fileDragHover)
        second.setViewerPresented(true)
        #expect(!second.fileDragHover)

        second.fileDragHover = true
        second.disconnect(notify: false)
        #expect(!second.fileDragHover)
        #expect(first.sessionID != nil)
    }

    @Test @MainActor func desktopWindowIsSharedAndClosingItPreservesConnections() throws {
        _ = NSApplication.shared
        let center = DesktopCenter()
        let wasEnabled = center.enabled
        if ProcessInfo.processInfo.environment["TAOSCREEN_DESKTOP_PREVIEW"] != nil { center.enabled = true }
        defer { center.shutdown(); if center.enabled != wasEnabled { center.enabled = wasEnabled } }
        let first = center.prepareViewer(for: .init(id: UUID(), name: "Mac Studio"))
        let second = center.prepareViewer(for: .init(id: UUID(), name: "MacBook Pro"))
        center.showDesktopWindow(sessionID: first.id)
        let window = try #require(center.desktopWindow.window)
        center.showDesktopWindow(sessionID: second.id)
        #expect(center.desktopWindow.window === window)
        #expect(center.selectedViewer === second)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
        if let directory = ProcessInfo.processInfo.environment["TAOSCREEN_DESKTOP_PREVIEW"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("desktop-tabs.png"))
            // 用相同窗口布局导出悬停浮层，检查它能越过标签栏并保持在窗口内。
            window.contentView = NSHostingView(rootView: DesktopWorkspaceView(center: center, hoveredConnectionID: second.id))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let hoverFrame = try #require(window.contentView?.superview)
            hoverFrame.layoutSubtreeIfNeeded()
            let hoverBitmap = try #require(hoverFrame.bitmapImageRepForCachingDisplay(in: hoverFrame.bounds))
            hoverFrame.cacheDisplay(in: hoverFrame.bounds, to: hoverBitmap)
            try #require(hoverBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("desktop-connection-info.png"))
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for size in [CGSize(width: 960, height: 640), CGSize(width: 820, height: 560)] {
                    let list = NSHostingView(rootView: DesktopView(center: center)
                        .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = list
                    window.setContentSize(size)
                    list.layoutSubtreeIfNeeded()
                    let listBitmap = try #require(list.bitmapImageRepForCachingDisplay(in: list.bounds))
                    list.cacheDisplay(in: list.bounds, to: listBitmap)
                    let filename = "desktop-list-\(Int(size.width))-\(dark ? "dark" : "light").png"
                    try #require(listBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
                }
            }
            let settings = NSHostingView(rootView: DesktopViewerSettings(center: second).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = settings
            window.setContentSize(settings.fittingSize)
            settings.layoutSubtreeIfNeeded()
            let settingsBitmap = try #require(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
            settings.cacheDisplay(in: settings.bounds, to: settingsBitmap)
            try #require(settingsBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("desktop-settings.png"))
        }
        second.fileDragHover = true
        window.close()
        #expect(center.desktopWindow.window == nil)
        #expect(!second.fileDragHover)
        #expect(center.viewerSessions.count == 2)
        #expect(first.sessionID != nil && second.sessionID != nil)
        first.disconnect(notify: false)
        #expect(center.selectedViewer === second)
        second.disconnect(notify: false)
        #expect(center.selectedViewerID == nil)
    }

    @Test func shortcutRoutingAndQualityUseExplicitState() {
        #expect(DesktopShortcutDestination.local.forwards([]))
        #expect(DesktopShortcutDestination.local.forwards([.shift, .option]))
        #expect(!DesktopShortcutDestination.local.forwards([.command]))
        #expect(!DesktopShortcutDestination.local.forwards([.control, .shift]))
        #expect(DesktopShortcutDestination.remote.forwards([.command, .control]))
        #expect(DesktopConnectionQuality(milliseconds: nil) == .unknown)
        #expect(DesktopConnectionQuality(milliseconds: .nan) == .unknown)
        #expect(DesktopConnectionQuality(milliseconds: -1) == .unknown)
        #expect(DesktopConnectionQuality(milliseconds: 79) == .good)
        #expect(DesktopConnectionQuality(milliseconds: 80) == .fair)
        #expect(DesktopConnectionQuality(milliseconds: 200) == .poor)
    }

    @Test @MainActor func capturedKeysReleaseAndDoNotLeakIntoLocalMode() throws {
        _ = NSApplication.shared
        let view = DesktopVideoNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var inputs: [DesktopInput] = []
        view.canControl = true
        view.shortcutDestination = .remote
        view.send = { inputs.append($0) }
        view.layout()
        func focus() throws {
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 320, y: 180), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
            view.releaseInput()
            inputs.removeAll()
        }
        func event(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
        }
        let down = try event(.keyDown, key: 48, flags: .command)
        let up = try event(.keyUp, key: 48, flags: .command)
        #expect(!view.handleCapturedKey(down))
        try focus()
        #expect(view.handleCapturedKey(down))
        #expect(view.handleCapturedKey(up))
        #expect(inputs.map(\.down) == [true, false])
        #expect(inputs.allSatisfy { $0.key == 48 && $0.flags == UInt64(NSEvent.ModifierFlags.command.rawValue) })
        // 标签切换在 SwiftUI 销毁旧画面前已经生效，旧画面不能继续吞键或发给原电脑。
        view.inputIsCurrent = { false }
        #expect(!view.handleCapturedKey(down))
        #expect(inputs.count == 2)
        view.inputIsCurrent = { true }
        let escape = try event(.keyDown, key: 53, flags: [.control, .option])
        #expect(view.handleCapturedKey(escape))
        #expect(inputs.last?.kind == "release")
        #expect(!inputs.contains { $0.key == 53 })
        #expect(!view.handleCapturedKey(down))
        view.shortcutDestination = .local
        let count = inputs.count
        #expect(!view.handleCapturedKey(down))
        #expect(!view.performKeyEquivalent(with: down))
        view.keyUp(with: up)
        #expect(inputs.count == count)
        view.shortcutDestination = .remote
        try focus()
        _ = view.handleCapturedKey(down)
        view.canControl = false
        #expect(inputs.last?.kind == "release")
        #expect(!view.handleCapturedKey(up))
    }

    @Test(arguments: [false, true]) @MainActor func navigationClicksReleaseFocusBeforeDispatchAndOnlyVideoClicksReclaimIt(flipped: Bool) throws {
        _ = NSApplication.shared
        let window = DesktopControlWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = DesktopFocusTestContent(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        content.usesFlippedCoordinates = flipped
        let video = DesktopVideoNSView(frame: NSRect(x: 0, y: flipped ? 44 : 0, width: 800, height: 556))
        let navigation = DesktopNavigationProbe(frame: NSRect(x: 0, y: flipped ? 0 : 556, width: 800, height: 44))
        content.addSubview(video); content.addSubview(navigation); window.contentView = content
        window.orderFront(nil)
        video.canControl = true; video.shortcutDestination = .remote; video.layout()
        var inputs: [DesktopInput] = []
        video.send = { inputs.append($0) }
        let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }
        func checkLocal() {
            #expect(!video.keyboardFocusRequested)
            #expect(window.firstResponder !== video)
            #expect(!video.performKeyEquivalent(with: shortcut))
            #expect(!video.handleCapturedKey(shortcut))
        }
        checkLocal()
        window.makeFirstResponder(video)
        checkLocal() // 检查实际首响应者；AppKit 可退回窗口并返回 true。
        // 顶栏左侧、当前标签、空白、右侧设置位置均在控件收到 mouseDown 前释放。
        for x in [30.0, 160, 460, 770] {
            try click(NSPoint(x: 400, y: 280))
            #expect(window.firstResponder === video && video.keyboardFocusRequested)
            #expect(video.handleCapturedKey(shortcut))
            var deliveredToNavigation = false
            navigation.clicked = {
                checkLocal()
                #expect(inputs.last?.kind == "release")
                deliveredToNavigation = true
            }
            try click(NSPoint(x: x, y: 580))
            #expect(deliveredToNavigation)
            checkLocal()
            #expect(video.shortcutDestination == .remote)
        }
        let count = inputs.filter { $0.kind == "button" }.count
        try click(NSPoint(x: 400, y: 20)) // 视频下方黑边。
        checkLocal()
        #expect(inputs.filter { $0.kind == "button" }.count == count)
        try click(NSPoint(x: 400, y: 280))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        checkLocal()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        checkLocal()
        video.canControl = false; video.canControl = true
        checkLocal() // 设置浮窗关闭、重新开启控制均不抢回焦点。
        try click(NSPoint(x: 400, y: 280))
        #expect(video.keyboardFocusRequested)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        checkLocal()
        try click(NSPoint(x: 400, y: 280))
        let otherResponder = NSButton(frame: .zero)
        content.addSubview(otherResponder)
        window.makeFirstResponder(otherResponder)
        checkLocal()
    }

    @Test func signalFailuresDistinguishOccupiedConnectionFromRevokedAuthorization() throws {
        let transport = URLError(.networkConnectionLost)
        #expect(DesktopSignalFailure.classify(transport, httpStatus: 409, closeCode: nil) == .occupied)
        #expect(!DesktopSignalFailure.occupied.endsSession)
        #expect(DesktopSignalFailure.classify(transport, httpStatus: 101, closeCode: 4001) == .authentication)
        #expect(DesktopSignalFailure.classify(transport, httpStatus: 401, closeCode: nil).endsSession)
        #expect(DesktopSignalFailure.classify(transport, httpStatus: 503, closeCode: nil) == .network)
        // 部署期间代理返回的 404 不代表缺少远程桌面能力，也不能永久停掉重连。
        #expect(DesktopSignalFailure.classify(transport, httpStatus: 404, closeCode: nil) == .endpointUnavailable)
        #expect(!DesktopSignalFailure.endpointUnavailable.endsSession)
        let missingRoute = CloudHTTPError(statusCode: 404, path: "/v1/desktop/config")
        #expect(DesktopSignalFailure.classify(missingRoute, httpStatus: nil, closeCode: nil) == .endpointUnavailable)
        #expect(DesktopSignalFailure.classify(CloudHTTPError(statusCode: 401, path: "/v1/desktop/config"), httpStatus: nil, closeCode: nil) == .authentication)
        let revoked = CloudAPIError(code: "unauthorized", message: "revoked", details: nil)
        #expect(DesktopSignalFailure.classify(revoked, httpStatus: nil, closeCode: nil).endsSession)
        let delays = (0...6).map { DesktopSignalRecovery.retryDelay(attempt: $0, jitter: 1) }
        #expect(delays == [1, 2, 4, 8, 10, 10, 10])
        #expect(DesktopSignalRecovery.retryDelay(attempt: 100, jitter: 1.2) <= 10)
        let legacy = try JSONDecoder().decode(DesktopSignal.self, from: Data(#"{"type":"hello"}"#.utf8))
        #expect(legacy.payload?.resume != true)
        let nonce = UUID()
        let request = DesktopSignal(type: "resume", id: UUID(), to: UUID(), payload: .init(resumeToken: nonce))
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("resume_token"))
        #expect(try JSONDecoder().decode(DesktopSignal.self, from: data).payload?.resumeToken == nonce)
    }

    @Test func localCursorIsUsedOnlyWhileActivelyControlling() {
        #expect(!DesktopCursorMode.local.showsRemoteCursor(canControl: true, windowActive: true))
        // 仅观看/关闭鼠标键盘，以及窗口失焦、最小化或关闭后，视频要能指示远端操作。
        for active in [false, true] {
            #expect(DesktopCursorMode.local.showsRemoteCursor(canControl: false, windowActive: active))
            #expect(DesktopCursorMode.remote.showsRemoteCursor(canControl: true, windowActive: active))
        }
        #expect(DesktopCursorMode.local.showsRemoteCursor(canControl: true, windowActive: false))
    }

    @Test func cursorMessagesRemainSeparateFromInputAndSessionStatus() throws {
        for action in [DesktopCursorMessage.Action.request, .status] {
            let message = DesktopCursorMessage(action: action, showsCursor: false)
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(DesktopCursorMessage.self, from: data) == message)
            #expect(try !JSONDecoder().decode(DesktopInput.self, from: data).isValid)
            #expect((try? JSONDecoder().decode(DesktopSessionStatus.self, from: data)) == nil)
        }
        #expect(!DesktopCursorMessage(kind: "move", action: .request, showsCursor: false).isValid)
        #expect(!DesktopCursorMessage(action: .request, showsCursor: false, failed: true).isValid)
        #expect(DesktopCursorMessage(action: .status, showsCursor: true, failed: true).isValid)
        #expect((try? JSONDecoder().decode(DesktopCursorMessage.self,
            from: Data(#"{"kind":"desktop-cursor.v1","action":"request"}"#.utf8))) == nil)
    }

    @Test func lockedSessionAllowsUnattendedConnectionButNotAnUnanswerablePrompt() throws {
        var info: [String: Any] = [kCGSessionOnConsoleKey as String: true,
                                  kCGSessionLoginDoneKey as String: true,
                                  "CGSSessionScreenIsLocked": false]
        let unlocked = DesktopLocalSession.from(info)
        #expect(unlocked.canStart(unattended: false))
        info["CGSSessionScreenIsLocked"] = true
        let locked = DesktopLocalSession.from(info)
        #expect(locked.canHost)
        #expect(locked.canStart(unattended: true))
        #expect(!locked.canStart(unattended: false))
        #expect(locked.withLockState(false) == unlocked)
        #expect(unlocked.withLockState(true) == locked)
        info[kCGSessionOnConsoleKey as String] = false
        #expect(!DesktopLocalSession.from(info).canStart(unattended: true))
        info[kCGSessionOnConsoleKey as String] = true
        info[kCGSessionLoginDoneKey as String] = false
        #expect(!DesktopLocalSession.from(info).canStart(unattended: true))
        #expect(!DesktopLocalSession.from(nil).canHost)
        #expect(!DesktopLocalSession.from([:]).canHost)

        let status = DesktopSessionStatus(locked: true)
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(DesktopSessionStatus.self, from: data) == status)
        #expect(try !JSONDecoder().decode(DesktopInput.self, from: data).isValid)
        #expect(!DesktopSessionStatus(kind: "button", locked: true).isValid)
    }

    @Test func captureRecoveryDoesNotRestartUserStoppedOrUnauthorizedStreams() {
        var recovery = DesktopCaptureRecovery()
        for code in [SCStreamError.userStopped.rawValue, SCStreamError.userDeclined.rawValue,
                     SCStreamError.missingEntitlements.rawValue, SCStreamError.internalError.rawValue] {
            let allowed = recovery.consume(NSError(domain: SCStreamErrorDomain, code: code))
            #expect(!allowed)
        }
        if #available(macOS 15, *) {
            let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.systemStoppedStream.rawValue)
            let unrelated = recovery.consume(NSError(domain: "unrelated", code: error.code))
            let first = recovery.consume(error), repeated = recovery.consume(error)
            #expect(!unrelated && first && !repeated)
            recovery.sessionChanged()
            let nextTransition = recovery.consume(error), repeatedAgain = recovery.consume(error)
            #expect(nextTransition && !repeatedAgain)
        }
    }
    @Test @MainActor func systemDiagnosticsRemainInactiveInOrdinaryBuilds() throws {
        #expect(!DesktopInputDiagnostics.systemEnabled)
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left))
        event.setIntegerValueField(.eventSourceUserData, value: 123)
        let observer = DesktopInputSystemObserver()
        var traces: [DesktopInputTrace] = []
        observer.onTrace = { traces.append($0) }
        observer.prepare(event)
        observer.stop()
        #expect(traces.isEmpty)
        #expect(event.getIntegerValueField(.eventSourceUserData) == 123)
    }

    @Test func diagnosticMessagesCannotBeTreatedAsControlInput() throws {
        let trace = DesktopInputTrace(stage: "target", detail: "type=1")
        let data = try JSONEncoder().encode(trace)
        #expect(try JSONDecoder().decode(DesktopInputTrace.self, from: data).isValid)
        #expect(try !JSONDecoder().decode(DesktopInput.self, from: data).isValid)
        #expect(!DesktopInputTrace(kind: "button", stage: "target", detail: "type=1").isValid)
        #expect(!DesktopInputTrace(stage: "target", detail: String(repeating: "x", count: 2049)).isValid)
    }

    @Test @MainActor func hostedVideoSurfaceReceivesWindowDispatchedClicks() throws {
        _ = NSApplication.shared
        let surface = DesktopVideoNSView(frame: .zero)
        surface.canControl = true
        var inputs: [DesktopInput] = []
        surface.send = { inputs.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: VStack {
            Text("Remote desktop")
            ZStack {
                Color.black
                DesktopTestSurface(surface: surface)
            }.clipShape(RoundedRectangle(cornerRadius: 8))
        }.padding(12))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        surface.layout()
        let location = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        #expect(surface.bounds.width > 0 && surface.bounds.height > 0)
        #expect(host.hitTest(host.convert(location, from: nil)) === surface)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        #expect(inputs.filter { $0.kind == "button" }.map(\.down) == [true, false])
        #expect(window.firstResponder === surface)
    }

    @Test @MainActor func videoSurfaceDeliversMouseButtonsAndFocus() throws {
        _ = NSApplication.shared
        let view = DesktopVideoNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.canControl = true
        view.layout()
        var inputs: [DesktopInput] = []
        view.send = { inputs.append($0) }
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.mouseDownCanMoveWindow)
        #expect(view.hitTest(NSPoint(x: 320, y: 180)) === view)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 320, y: 180),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            // Exercise hit testing and responder methods without activating a
            // real window or posting synthetic clicks into the user's session.
            let target = try #require(view.hitTest(event.locationInWindow))
            if type == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
        #expect(inputs.filter { $0.kind == "button" }.map(\.down) == [true, false])
        #expect(window.firstResponder === view)
    }

    @Test @MainActor func injectedClicksKeepMatchingPressMetadataAndReleaseOnDisable() throws {
        var events: [CGEvent] = []
        let receiver = DesktopInputReceiver(canPost: { true }, post: { events.append($0) })
        receiver.enabled = true
        for button in 0...2 {
            receiver.receive(.init(kind: "button", x: 0.4, y: 0.5, button: button, down: true, clicks: 2))
            receiver.receive(.init(kind: "move", x: 0.6, y: 0.7))
            receiver.receive(.init(kind: "button", x: 0.6, y: 0.7, button: button, down: false, clicks: 0))
            let press = events[events.count - 3], drag = events[events.count - 2], release = events[events.count - 1]
            #expect(press.getIntegerValueField(.mouseEventNumber) > 0)
            #expect(press.getIntegerValueField(.mouseEventNumber) == release.getIntegerValueField(.mouseEventNumber))
            #expect(drag.getIntegerValueField(.mouseEventNumber) == press.getIntegerValueField(.mouseEventNumber))
            #expect(drag.type == [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged][button])
            #expect(try #require(NSEvent(cgEvent: release)).clickCount == 2)
            #expect(release.getIntegerValueField(.mouseEventButtonNumber) == Int64(button))
            #expect(press.getDoubleValueField(.mouseEventPressure) == 1)
            #expect(release.getDoubleValueField(.mouseEventPressure) == 0)
        }
        #expect(Set(events.map { $0.getIntegerValueField(.mouseEventNumber) }).count == 3)
        receiver.receive(.init(kind: "button", x: 0.4, y: 0.5, button: 0, down: true, clicks: 0))
        let down = try #require(events.last)
        receiver.enabled = false
        let up = try #require(events.last)
        #expect(up.type == .leftMouseUp)
        #expect(up.getIntegerValueField(.mouseEventClickState) == 1)
        #expect(up.getIntegerValueField(.mouseEventNumber) == down.getIntegerValueField(.mouseEventNumber))
        let count = events.count
        receiver.releaseAll()
        receiver.receive(.init(kind: "button", x: 0.4, y: 0.5, button: 0, down: true))
        #expect(events.count == count)
    }

    @Test @MainActor func injectedEventsHaveCurrentTimestampsIncludingDisconnectReleases() throws {
        var events: [CGEvent] = []
        let receiver = DesktopInputReceiver(canPost: { true }, post: { events.append($0) })
        receiver.enabled = true
        let earliest = DispatchTime.now().uptimeNanoseconds
        receiver.receive(.init(kind: "move", x: 0.4, y: 0.5))
        receiver.receive(.init(kind: "button", x: 0.4, y: 0.5, button: 0, down: true))
        receiver.receive(.init(kind: "move", x: 0.6, y: 0.7))
        receiver.receive(.init(kind: "button", x: 0.6, y: 0.7, button: 0, down: false))
        receiver.receive(.init(kind: "scroll", dx: 0, dy: 10))
        receiver.receive(.init(kind: "key", down: true, key: 12))
        receiver.receive(.init(kind: "key", down: false, key: 12))
        receiver.receive(.init(kind: "button", x: 0.4, y: 0.5, button: 1, down: true))
        receiver.receive(.init(kind: "key", down: true, key: 56))
        receiver.enabled = false
        let latest = DispatchTime.now().uptimeNanoseconds
        #expect(events.count == 11)
        #expect(events.suffix(2).map(\.type) == [.flagsChanged, .rightMouseUp])
        for event in events {
            #expect((earliest...latest).contains(event.timestamp))
            #expect(try #require(NSEvent(cgEvent: event)).timestamp > 0)
        }
        #expect(events.map(\.timestamp) == events.map(\.timestamp).sorted())
    }

    @Test func capturePreservesRetinaPixelsAndBoundsLargeDisplays() {
        #expect(DesktopVideoQuality.captureSize(points: CGSize(width: 1512, height: 982), pixelScale: 2)
            == CGSize(width: 3024, height: 1964))
        #expect(DesktopVideoQuality.captureSize(points: CGSize(width: 1920, height: 1080), pixelScale: 1)
            == CGSize(width: 1920, height: 1080))
        #expect(DesktopVideoQuality.captureSize(points: CGSize(width: 2560, height: 1440), pixelScale: 2)
            == CGSize(width: 3840, height: 2160))
        #expect(DesktopVideoQuality.captureSize(points: CGSize(width: 1440, height: 2560), pixelScale: 2)
            == CGSize(width: 2160, height: 3840))
        let config = DesktopVideoQuality.configuration(points: CGSize(width: 1512, height: 982), pixelScale: 2, sound: false)
        #expect(config.width == 3024 && config.height == 1964)
        #expect(config.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(config.colorSpaceName == CGColorSpace.sRGB)
        #expect(config.colorMatrix == CGDisplayStream.yCbCrMatrix_ITU_R_601_4)
        #expect(config.showsCursor)
        let localCursor = DesktopVideoQuality.configuration(points: CGSize(width: 1512, height: 982),
            pixelScale: 2, sound: true, showsCursor: false)
        #expect(!localCursor.showsCursor)
        #expect(localCursor.capturesAudio)
        #expect(localCursor.width == config.width && localCursor.height == config.height)
        #expect(localCursor.pixelFormat == config.pixelFormat && localCursor.colorSpaceName == config.colorSpaceName)
    }

    @Test func unattendedSettingsPersistOnlyForTheConfiguredAccountAndServer() throws {
        let suite = "taoscreen.desktop.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let userID = UUID()
        let account = CloudAccount(server: "https://one.example", userID: userID, email: "one@example.com")
        let otherUser = CloudAccount(server: account.server, userID: UUID(), email: "two@example.com")
        let otherServer = CloudAccount(server: "https://two.example", userID: userID, email: account.email)
        #expect(!DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults).enabled)
        let settings = DesktopUnattendedSettings(enabled: true, displayID: 42, control: false, audio: true)
        settings.save(accountID: account.id, defaults: defaults)
        #expect(DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults) == settings)
        #expect(DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults).shareDisplay == .fixed(42))
        var virtual = settings
        virtual.shareDisplay = .virtual(.quadHD)
        virtual.save(accountID: account.id, defaults: defaults)
        let restored = DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults)
        #expect(restored.shareDisplay == .virtual(.quadHD) && restored.displayID == nil)
        virtual.shareDisplay = .main
        #expect(virtual.shareDisplay == .main && virtual.virtualDisplayPreset == nil)
        #expect(!DesktopUnattendedSettings.load(accountID: otherUser.id, defaults: defaults).enabled)
        #expect(!DesktopUnattendedSettings.load(accountID: otherServer.id, defaults: defaults).enabled)
        #expect(!DesktopUnattendedSettings.load(accountID: nil, defaults: defaults).enabled)
        var disabled = settings
        disabled.enabled = false
        disabled.save(accountID: account.id, defaults: defaults)
        #expect(DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults) == disabled)
        defaults.set(Data("{\"enabled\":true}".utf8), forKey: "taoscreen.desktop.unattended.\(account.id)")
        #expect(!DesktopUnattendedSettings.load(accountID: account.id, defaults: defaults).enabled)
    }

    @Test func latencyUsesOnlyTheSelectedPairAndRejectsInvalidSamples() {
        var statistics: [String: (type: String, values: [String: NSObject])] = [
            "transport": ("transport", ["selectedCandidatePairId": "active" as NSString]),
            "active": ("candidate-pair", ["currentRoundTripTime": NSNumber(value: 0.042)]),
            "old": ("candidate-pair", ["currentRoundTripTime": NSNumber(value: 0.9)])
        ]
        #expect(DesktopLatency.milliseconds(statistics: statistics) == 42)
        statistics["active"]?.values.removeValue(forKey: "currentRoundTripTime")
        #expect(DesktopLatency.milliseconds(statistics: statistics) == nil)
        for invalid in [-1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            statistics["active"]?.values["currentRoundTripTime"] = NSNumber(value: invalid)
            #expect(DesktopLatency.milliseconds(statistics: statistics) == nil)
        }
        statistics["active"]?.values["currentRoundTripTime"] = NSNumber(value: 0)
        #expect(DesktopLatency.milliseconds(statistics: statistics) == 0)
        statistics.removeValue(forKey: "transport")
        #expect(DesktopLatency.milliseconds(statistics: statistics) == nil)
    }

    @Test func inputRejectsMalformedAndUnboundedEvents() throws {
        #expect(!DesktopInput(kind: "move", x: .nan, y: 0).isValid)
        #expect(!DesktopInput(kind: "button", x: 0, y: 1, button: 3, down: true).isValid)
        #expect(!DesktopInput(kind: "move", x: -0.1, y: 0).isValid)
        #expect(!DesktopInput(kind: "key", down: true, key: 128).isValid)
        #expect(!DesktopInput(kind: "scroll", dx: .infinity, dy: 0).isValid)
        #expect(!DesktopInput(kind: "clipboard", text: String(repeating: "中", count: 6000)).isValid)
        #expect(DesktopInput(kind: "button", x: 0, y: 1, button: 2, down: false).isValid)
        #expect(DesktopInput(kind: "release").isValid)
        let input = DesktopInput(kind: "key", down: false, key: 55, flags: 0)
        let decoded = try JSONDecoder().decode(DesktopInput.self, from: JSONEncoder().encode(input))
        #expect(decoded.isValid && decoded.down == false && decoded.key == 55)
    }
    @Test func aspectFitCoordinatesExcludeBlackBarsAndFlipY() {
        let bounds = CGRect(x: 10, y: 100, width: 400, height: 200)
        #expect(DesktopInput.normalized(CGPoint(x: 210, y: 150), bounds: bounds) == CGPoint(x: 0.5, y: 0.75))
        #expect(DesktopInput.normalized(CGPoint(x: 200, y: 50), bounds: bounds) == nil)
        #expect(DesktopInput.normalized(.zero, bounds: .zero) == nil)
    }
    @Test func fileReceiverRejectsTraversalWrongOffsetsAndInvalidDigests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = DesktopFileReceiver(root: root)
        let id = UUID()
        try receiver.receive(.init(kind: "begin", id: id, sequence: 1, bytes: 3, count: 1))
        for path in ["../escape", "/absolute", "folder/../../escape", "a\\b", "a:b"] {
            #expect(throws: (any Error).self) {
                try receiver.receive(.init(kind: "file", id: id, sequence: 2, path: path, bytes: 3))
            }
        }
        try receiver.receive(.init(kind: "file", id: id, sequence: 2, path: "folder/file.txt", bytes: 3))
        #expect(throws: (any Error).self) {
            try receiver.receive(.init(kind: "chunk", id: id, sequence: 3, offset: 1, data: Data([1])))
        }
        #expect(throws: (any Error).self) {
            try receiver.receive(.init(kind: "chunk", id: id, sequence: 3, offset: 0, data: Data(repeating: 1, count: 4)))
        }
        try receiver.receive(.init(kind: "chunk", id: id, sequence: 3, offset: 0, data: Data([1, 2, 3])))
        #expect(throws: (any Error).self) {
            try receiver.receive(.init(kind: "endFile", id: id, sequence: 4, digest: "wrong"))
        }
        receiver.cancel()
        #expect(receiver.id == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test @MainActor func fileTransferRequiresControlAndCleansUpOnClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var permitted = false
        var replies: [DesktopFilePacket] = []
        let transfer = DesktopFileTransfer(host: true, root: root, allowed: { permitted }, send: {
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: $0) { replies.append(packet) }
            return true
        })
        let id = UUID()
        let begin = try JSONEncoder().encode(DesktopFilePacket(kind: "begin", id: id, sequence: 1, bytes: 5, count: 1))
        transfer.receive(begin)
        await transfer.waitForReceiving()
        #expect(replies.last?.kind == "error")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        permitted = true
        transfer.receive(begin)
        await transfer.waitForReceiving()
        #expect(replies.last?.kind == "ack")
        transfer.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "file", id: id, sequence: 2, path: "partial.txt", bytes: 5)))
        transfer.close()
        await transfer.waitForReceiving()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test @MainActor func cancelledFileSendRemovesPartialBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 7, count: 1024 * 1024).write(to: source)
        var outgoing: DesktopFileTransfer?
        var cancelled = false
        let incoming = DesktopFileTransfer(host: true, root: root.appendingPathComponent("received"), allowed: { true }, send: { data in
            outgoing?.receive(data); return true
        })
        outgoing = DesktopFileTransfer(host: false, root: root.appendingPathComponent("unused"), allowed: { true }, send: { data in
            incoming.receive(data)
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data), packet.kind == "chunk" {
                outgoing?.cancelSending()
            }
            return true
        })
        outgoing?.onStatus = { message, progress in if progress == nil && message.contains("取消") { cancelled = true } }
        defer { outgoing?.close(); incoming.close() }
        #expect(outgoing?.send([source], paste: false) == true)
        let deadline = Date().addingTimeInterval(5)
        while !cancelled && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cancelled)
        await incoming.waitForReceiving()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("received").path).isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor func nativePeersExchangeVideoControlAndAudio(highResolution: Bool) async throws {
        // Real local ICE/DTLS/SCTP/RTP, with synthetic frames; no screen/input permissions or account data.
        let config = DesktopConfiguration(iceServers: [], relayAvailable: false)
        let host = try DesktopRTC(configuration: config, host: true)
        let viewer = try DesktopRTC(configuration: config, host: false)
        defer { host.close(); viewer.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-rtc-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = Data((0..<(512 * 1024 + 7)).map { UInt8($0 % 251) })
        try contents.write(to: source.appendingPathComponent("payload.bin"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let incoming = DesktopFileTransfer(host: true, root: root.appendingPathComponent("received"), dropRoot: root.appendingPathComponent("drops"), allowed: { true }, send: { host.sendFile($0) })
        let outgoing = DesktopFileTransfer(host: false, root: root.appendingPathComponent("controller-downloads"), allowed: { true }, send: { viewer.sendFile($0) })
        defer { incoming.close(); outgoing.close() }
        host.onFile = { incoming.receive($0) }
        viewer.onFile = { outgoing.receive($0) }
        var receivedFiles: [URL] = [], pasteFiles = false, fileSendFinished = false
        var returnedFiles: [URL] = [], returnPhase: DesktopTransferState.Phase?
        incoming.onFiles = { receivedFiles = $0; pasteFiles = $1 }
        incoming.onState = { returnPhase = $0.phase }
        outgoing.onFiles = { urls, paste in
            #expect(!paste)
            returnedFiles = urls
        }
        outgoing.onStatus = { message, progress in if progress == nil && message.contains("文件已送达") { fileSendFinished = true } }
        var hostConnected = false, viewerConnected = false
        let hostClipboardBoard = NSPasteboard.withUniqueName(), viewerClipboardBoard = NSPasteboard.withUniqueName()
        hostClipboardBoard.setString("original remote", forType: .string)
        viewerClipboardBoard.setString("stale local", forType: .string)
        var clipboardPastes: [String] = []
        let hostClipboard = DesktopClipboard(host: true, board: hostClipboardBoard, allowed: { hostConnected },
            send: { host.sendClipboard($0) }, paste: { clipboardPastes.append(hostClipboardBoard.string(forType: .string) ?? "") })
        let viewerClipboard = DesktopClipboard(host: false, board: viewerClipboardBoard, allowed: { viewerConnected },
            send: { viewer.sendClipboard($0) }, paste: {})
        defer {
            hostClipboard.close(); viewerClipboard.close()
            hostClipboardBoard.releaseGlobally(); viewerClipboardBoard.releaseGlobally()
        }
        host.onClipboard = { hostClipboard.receive($0) }
        viewer.onClipboard = { viewerClipboard.receive($0) }
        viewer.onControlOpen = { viewerClipboard.open() }
        var receivedKey = false, receivedAudio = false
        var receivedSessionStates: [Bool] = []
        var receivedCursorStates: [Bool] = []
        var receivedPrivacyStates: [Bool] = []
        var unexpectedCursorInput = false
        var hostLatency: Double?, viewerLatency: Double?
        var remoteVideo: RTCVideoTrack?
        let width = highResolution ? 3840 : 320, height = highResolution ? 2160 : 180
        let renderer = FrameCounter(expectedSize: CGSize(width: width, height: height))
        host.onSignal = { type, payload in if type == "candidate" { viewer.addCandidate(payload) } }
        viewer.onSignal = { type, payload in if type == "candidate" { host.addCandidate(payload) } }
        host.onState = {
            hostConnected = $0 == .connected
            if hostConnected { host.sendSessionStatus(.init(locked: true, fileReturn: true)) }
        }
        viewer.onState = { viewerConnected = $0 == .connected }
        host.onLatency = { hostLatency = $0 }
        viewer.onLatency = { viewerLatency = $0 }
        host.onControlOpen = {
            hostClipboard.open()
            host.sendSessionStatus(.init(locked: true, fileReturn: true))
            host.sendCursor(.init(action: .status, showsCursor: true))
            host.sendPrivacy(.init(action: .status, enabled: false))
        }
        host.onSessionStatus = {
            incoming.reverseEnabled = $0.fileReturn == true
            incoming.supportsDirectories = $0.fileDirectories == true
        }
        host.onPrivacy = { value in
            #expect(value.action == .request)
            host.sendPrivacy(.init(action: .status, enabled: value.enabled, active: value.enabled))
        }
        viewer.onPrivacy = { value in
            #expect(value.action == .status)
            receivedPrivacyStates.append(value.active)
        }
        host.onCursor = { value in
            #expect(value.action == .request)
            host.sendCursor(.init(action: .status, showsCursor: value.showsCursor))
        }
        viewer.onCursor = { value in
            #expect(value.action == .status)
            receivedCursorStates.append(value.showsCursor)
        }
        viewer.onSessionStatus = {
            receivedSessionStates.append($0.locked)
            if $0.fileReturn == true {
                outgoing.reverseEnabled = true
                viewer.sendSessionStatus(.init(locked: false, fileDirectories: true, fileReturn: true))
            }
        }
        var receivedButtons: [Bool] = []
        var receivedTextEvents: [DesktopInput] = []
        host.onInput = {
            if $0.kind == "desktop-cursor.v1" || $0.kind == "desktop-privacy.v1" || $0.kind == "desktop-clipboard.v1" { unexpectedCursorInput = true }
            if $0.kind == "key", $0.key == 12, $0.down == true { receivedKey = true }
            if $0.kind == "button", let down = $0.down { receivedButtons.append(down) }
            if $0.kind == "release" || $0.kind == "clipboard" || ($0.kind == "key" && $0.key == 9) { receivedTextEvents.append($0) }
        }
        viewer.onAudio = { receivedAudio = $0 == Data(repeating: 1, count: 1920) }
        viewer.onVideo = { remoteVideo = $0; $0.add(renderer) }
        let offer = try await viewer.makeDescription(offer: true)
        try await host.setRemote(offer, offer: true)
        let answer = try await host.makeDescription(offer: false)
        try await viewer.setRemote(answer, offer: false)
        let capturer = RTCVideoCapturer(delegate: host.source)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                   [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let pixels = try #require(pixelBuffer)
        // Wide black/white/R/G/B bars exercise range and chroma through the real codec.
        let bars: [(UInt8, UInt8, UInt8)] = [(0, 128, 128), (255, 128, 128), (76, 85, 255), (150, 44, 21), (29, 255, 107)]
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 1)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            luma[y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + x] = bars[x / (width / 5)].0
        } }
        for y in 0..<(height / 2) { for x in stride(from: 0, to: width, by: 2) {
            let offset = y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + x
            chroma[offset] = bars[x / (width / 5)].1
            chroma[offset + 1] = bars[x / (width / 5)].2
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !(receivedKey && receivedButtons.count >= 2 && receivedAudio && renderer.count > 0 && hostLatency != nil && viewerLatency != nil && receivedSessionStates.contains(true)) {
            viewer.send(.init(kind: "key", down: true, key: 12))
            // Wait for a delivered probe: readyState can become .open between
            // two sends, otherwise this test can send only the initial mouse-up.
            if receivedKey && receivedButtons.isEmpty {
                viewer.send(.init(kind: "button", x: 0.5, y: 0.5, button: 0, down: true, clicks: 1))
                viewer.send(.init(kind: "button", x: 0.5, y: 0.5, button: 0, down: false, clicks: 1))
            }
            host.sendAudio(Data(repeating: 1, count: 1920))
            let timestamp = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            host.source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: timestamp))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(hostConnected && viewerConnected)
        #expect(receivedSessionStates.contains(true))
        let clipboardDeadline = Date().addingTimeInterval(3)
        while !viewerClipboard.supported && Date() < clipboardDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(viewerClipboard.supported)
        viewerClipboard.refresh()
        hostClipboardBoard.clearContents(); hostClipboardBoard.setString("fresh remote copy 👋", forType: .string)
        // Exercise the real ordered channel without waiting for the host poll.
        viewerClipboard.pasteUnified()
        let pasteDeadline = Date().addingTimeInterval(3)
        while (clipboardPastes.isEmpty || viewerClipboardBoard.string(forType: .string) != "fresh remote copy 👋") && Date() < pasteDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clipboardPastes == ["fresh remote copy 👋"])
        #expect(viewerClipboardBoard.string(forType: .string) == "fresh remote copy 👋")
        for input in try DesktopInput.textPaste("语音输入👋🏽\n第二行") { viewer.send(input) }
        let textDeadline = Date().addingTimeInterval(3)
        while receivedTextEvents.count < 4 && Date() < textDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(receivedTextEvents.map(\.kind) == ["release", "clipboard", "key", "key"])
        #expect(receivedTextEvents.first(where: { $0.kind == "clipboard" })?.text == "语音输入👋🏽\n第二行")
        #expect(receivedTextEvents.filter { $0.kind == "key" }.map(\.down) == [true, false])
        host.sendSessionStatus(.init(locked: false))
        let unlockDeadline = Date().addingTimeInterval(3)
        while receivedSessionStates.last != false && Date() < unlockDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(receivedSessionStates.last == false)
        #expect(viewer.sendCursor(.init(action: .request, showsCursor: false)))
        #expect(viewer.sendCursor(.init(action: .request, showsCursor: true)))
        let cursorDeadline = Date().addingTimeInterval(3)
        while Array(receivedCursorStates.suffix(2)) != [false, true] && Date() < cursorDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(receivedCursorStates.first == true)
        #expect(Array(receivedCursorStates.suffix(2)) == [false, true])
        #expect(!unexpectedCursorInput)
        #expect(viewer.sendPrivacy(.init(action: .request, enabled: true)))
        #expect(viewer.sendPrivacy(.init(action: .request, enabled: false)))
        let privacyDeadline = Date().addingTimeInterval(3)
        while Array(receivedPrivacyStates.suffix(2)) != [true, false] && Date() < privacyDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(receivedPrivacyStates.first == false)
        #expect(Array(receivedPrivacyStates.suffix(2)) == [true, false])
        #expect(!unexpectedCursorInput)
        #expect(hostConnected && viewerConnected)
        #expect(receivedKey)
        #expect(Array(receivedButtons.prefix(2)) == [true, false])
        #expect(receivedAudio)
        #expect(renderer.count > 0)
        let samples = renderer.colorSamples
        #expect(samples.count == bars.count)
        for (sample, expected) in zip(samples, bars) {
            #expect(abs(sample.0 - Int(expected.0)) <= 6)
            #expect(abs(sample.1 - Int(expected.1)) <= 6)
            #expect(abs(sample.2 - Int(expected.2)) <= 6)
        }
        #expect(try #require(hostLatency) >= 0)
        #expect(try #require(viewerLatency) >= 0)
        #expect(incoming.reverseEnabled)
        #expect(!incoming.send([source], paste: true))
        #expect(!incoming.send([source], paste: false, drop: .init(x: 0.5, y: 0.5)))
        #expect(incoming.send([source], paste: false))
        #expect(outgoing.send([source], paste: true))
        let fileDeadline = Date().addingTimeInterval(15)
        while (!fileSendFinished || returnPhase != .completed) && Date() < fileDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fileSendFinished)
        #expect(returnPhase == .completed)
        let returnedFolder = try #require(returnedFiles.first)
        #expect(returnedFolder.path.hasPrefix(root.appendingPathComponent("controller-downloads").path + "/"))
        #expect(try Data(contentsOf: returnedFolder.appendingPathComponent("payload.bin")) == contents)
        #expect(try Data(contentsOf: returnedFolder.appendingPathComponent("empty.txt")).isEmpty)
        #expect(pasteFiles)
        let folder = try #require(receivedFiles.first)
        #expect(try Data(contentsOf: folder.appendingPathComponent("payload.bin")) == contents)
        #expect(try Data(contentsOf: folder.appendingPathComponent("empty.txt")).isEmpty)
        fileSendFinished = false
        #expect(outgoing.send([source], paste: false))
        let secondDeadline = Date().addingTimeInterval(15)
        while !fileSendFinished && Date() < secondDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fileSendFinished && !pasteFiles)
        #expect(receivedFiles.first != folder)
        var dropPrepared = false
        var dropState: DesktopTransferState?
        incoming.onPrepareDrop = { point in dropPrepared = point == .init(x: 0.25, y: 0.75) }
        incoming.onDeliverDrop = { urls in
            #expect(dropPrepared)
            #expect(urls.first?.deletingLastPathComponent().deletingLastPathComponent() == root.appendingPathComponent("drops"))
            #expect((try? Data(contentsOf: urls[0].appendingPathComponent("payload.bin"))) == contents)
            return .init(message: "已请求插入路径", warning: false, paths: urls.map(\.path))
        }
        outgoing.onState = { dropState = $0 }
        #expect(outgoing.send([source], paste: false, drop: .init(x: 0.25, y: 0.75)))
        let dropDeadline = Date().addingTimeInterval(15)
        while dropState?.active == true && Date() < dropDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(dropState?.phase == .completed)
        #expect(dropState?.paths.count == 1)
        incoming.close()
        #expect(try Data(contentsOf: folder.appendingPathComponent("payload.bin")) == contents)
        remoteVideo?.remove(renderer)
        host.close(); viewer.close()
        #expect(host.closed && viewer.closed)
        #expect(hostLatency == nil && viewerLatency == nil)
        host.sendAudio(Data()); viewer.send(.init(kind: "release"))
    }
}

private struct DesktopTestSurface: NSViewRepresentable {
    let surface: DesktopVideoNSView
    func makeNSView(context: Context) -> DesktopVideoNSView { surface }
    func updateNSView(_ view: DesktopVideoNSView, context: Context) {}
}

@MainActor private final class DesktopNavigationProbe: NSView {
    var clicked: (() -> Void)?
    override func mouseDown(with event: NSEvent) { clicked?() }
}

@MainActor private final class DesktopFocusTestContent: NSView {
    var usesFlippedCoordinates = false
    override var isFlipped: Bool { usesFlippedCoordinates }
}

private final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSize: CGSize
    private var frames = 0
    private var samples: [(Int, Int, Int)] = []
    init(expectedSize: CGSize) { self.expectedSize = expectedSize }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var colorSamples: [(Int, Int, Int)] { lock.lock(); defer { lock.unlock() }; return samples }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let buffer = frame.buffer.toI420()
        lock.lock(); defer { lock.unlock() }
        frames += 1
        guard Int(buffer.width) == Int(expectedSize.width), Int(buffer.height) == Int(expectedSize.height) else { return }
        samples = (0..<5).map { index in
            let barWidth = Int(buffer.width) / 5
            let x = index * barWidth + barWidth / 2, y = Int(buffer.height) / 2
            return (Int(buffer.dataY[y * Int(buffer.strideY) + x]),
                    Int(buffer.dataU[(y / 2) * Int(buffer.strideU) + x / 2]),
                    Int(buffer.dataV[(y / 2) * Int(buffer.strideV) + x / 2]))
        }
    }
}
