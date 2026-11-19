import AppKit
import Testing
@testable import TaoScreen

struct DesktopClipboardTests {
    @MainActor private final class Link {
        let hostBoard = NSPasteboard.withUniqueName()
        let viewerBoard: NSPasteboard
        var hostAllowed = true
        var viewerAllowed = true
        var viewerWritable = true
        var queue: [(Bool, DesktopClipboardMessage)] = []
        var sent: [DesktopClipboardMessage] = []
        var pasted: [String?] = []
        var files: [[URL]] = []
        var failures: [String] = []
        lazy var host = DesktopClipboard(host: true, board: hostBoard, allowed: { [unowned self] in hostAllowed },
            send: { [unowned self] in sent.append($0); queue.append((false, $0)); return true },
            paste: { [unowned self] in pasted.append(hostBoard.string(forType: .string)) })
        lazy var viewer = DesktopClipboard(host: false, board: viewerBoard, allowed: { [unowned self] in viewerAllowed },
            send: { [unowned self] in
                guard viewerWritable else { return false }
                sent.append($0); queue.append((true, $0)); return true
            },
            paste: { [unowned self] in pasted.append(hostBoard.string(forType: .string)) },
            pasteFiles: { [unowned self] in files.append($0) }, failure: { [unowned self] in failures.append($0) })

        init(viewerBoard: NSPasteboard? = nil) {
            self.viewerBoard = viewerBoard ?? .withUniqueName()
            Self.copy("old remote", to: hostBoard)
            if viewerBoard == nil { Self.copy("old local", to: self.viewerBoard) }
        }
        static func copy(_ text: String, to board: NSPasteboard) {
            board.clearContents(); board.setString(text, forType: .string)
        }
        func start() { host.open(); viewer.open(); pump() }
        func pump() {
            var count = 0
            while !queue.isEmpty, count < 100 {
                count += 1
                let (toHost, message) = queue.removeFirst()
                if toHost { host.receive(message) } else { viewer.receive(message) }
            }
            #expect(queue.isEmpty, "Clipboard synchronization must not echo indefinitely")
        }
        func close(releaseViewer: Bool = true) {
            host.close(); viewer.close()
            hostBoard.releaseGlobally()
            if releaseViewer { viewerBoard.releaseGlobally() }
        }
    }

    @Test @MainActor func remoteCopyImmediatelyBeforePasteWinsOverStaleLocalContent() {
        let link = Link(); defer { link.close() }; link.start()
        // Represents a native context-menu copy; no keyboard interception and
        // no polling/notification have run before the viewer presses Command-V.
        Link.copy("new remote selection", to: link.hostBoard)
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted == ["new remote selection"])
        #expect(link.hostBoard.string(forType: .string) == "new remote selection")
        #expect(link.viewerBoard.string(forType: .string) == "new remote selection")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted == ["new remote selection", "new remote selection"])
    }

    @Test @MainActor func allAppKitPasteEntrypointsUseTheUnifiedClipboard() throws {
        let link = Link(); defer { link.close() }; link.start()
        _ = NSApplication.shared
        let view = DesktopVideoNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view; view.canControl = true; view.shortcutDestination = .remote; view.layout()
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 320, y: 180), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        var sent: [DesktopInput] = []
        view.send = { sent.append($0) }
        view.pasteClipboard = { link.viewer.pasteUnified() }
        func event(_ type: NSEvent.EventType, key: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key == 8 ? "c" : "v",
                charactersIgnoringModifiers: key == 8 ? "c" : "v", isARepeat: false, keyCode: key))
        }
        #expect(view.handleCapturedKey(try event(.keyDown, key: 8)))
        #expect(view.handleCapturedKey(try event(.keyUp, key: 8)))
        #expect(sent.map(\.key) == [8, 8])
        Link.copy("copied remotely", to: link.hostBoard)
        sent.removeAll()
        #expect(view.handleCapturedKey(try event(.keyDown, key: 9)))
        #expect(view.handleCapturedKey(try event(.keyUp, key: 9)))
        link.pump()
        #expect(view.performKeyEquivalent(with: try event(.keyDown, key: 9)))
        view.keyUp(with: try event(.keyUp, key: 9)); link.pump()
        view.paste(nil); link.pump()
        #expect(link.pasted == Array(repeating: "copied remotely", count: 3))
        #expect(sent.isEmpty) // No duplicate raw V or orphaned key-up.
    }

    @Test @MainActor func textCopiesSynchronizeBothDirectionsWithoutEchoes() {
        let link = Link(); defer { link.close() }; link.start()
        #expect(link.viewer.supported)
        // Connecting alone must not erase either computer's existing clipboard.
        #expect(link.hostBoard.string(forType: .string) == "old remote")
        #expect(link.viewerBoard.string(forType: .string) == "old local")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted == ["old local"])
        Link.copy("远端复制 👋", to: link.hostBoard)
        link.host.refresh(); link.pump()
        #expect(link.viewerBoard.string(forType: .string) == "远端复制 👋")
        let before = link.sent.count
        link.viewer.refresh(); link.host.refresh(); link.pump()
        #expect(link.sent.count == before)
        Link.copy("new local copy", to: link.viewerBoard)
        link.viewer.refresh(); link.pump()
        #expect(link.hostBoard.string(forType: .string) == "new local copy")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted.last == "new local copy")
    }

    @Test @MainActor func delayedRemoteNoticeDoesNotEraseAnUnobservedNewLocalCopy() {
        let link = Link(); defer { link.close() }; link.start()
        Link.copy("remote", to: link.hostBoard)
        link.host.refresh() // Remote notice is queued but not delivered yet.
        Link.copy("newer local", to: link.viewerBoard)
        link.pump()
        #expect(link.viewerBoard.string(forType: .string) == "newer local")
        #expect(link.hostBoard.string(forType: .string) == "newer local")
    }

    @Test @MainActor func directConnectionCodesDoNotAutomaticallySyncAcrossSessions() {
        let link = Link(); defer { link.close() }; link.start()
        let code = DesktopDirectCode(fingerprint: Data(repeating: 0, count: 32)).text
        Link.copy(code, to: link.hostBoard)
        link.host.refresh(); link.pump()
        #expect(link.viewerBoard.string(forType: .string) != code)
        Link.copy(code, to: link.viewerBoard)
        link.viewer.refresh(); link.pump()
        #expect(!link.sent.contains { $0.text == code })
    }

    @Test @MainActor func unattendedTypingPreservesClipboardWithoutSyncingIt() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        Link.copy("existing clipboard", to: board)
        var sent: [DesktopClipboardMessage] = []
        let host = DesktopClipboard(host: true, board: board, allowed: { false }, transientAllowed: { true },
                                    send: { sent.append($0); return true }, paste: {})
        #expect(host.beforeTransientWrite())
        Link.copy("typed text", to: board)
        host.didWriteClipboard()
        #expect(host.beforeKey(.init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue)))
        host.close()
        #expect(board.string(forType: .string) == "existing clipboard")
        #expect(sent.isEmpty)
    }

    @Test @MainActor func staleLocalWriteAndPasteCannotOverwriteANewerRemoteCopy() {
        let link = Link(); defer { link.close() }; link.start()
        Link.copy("local copy", to: link.viewerBoard)
        link.viewer.refresh() // A write with the previous remote revision.
        Link.copy("newer remote", to: link.hostBoard)
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted == ["newer remote"])
        #expect(link.hostBoard.string(forType: .string) == "newer remote")
    }

    @Test @MainActor func remoteNativeFormatsAndOversizedTextUseRemotePaste() {
        let link = Link(); defer { link.close() }; link.start()
        let url = URL(fileURLWithPath: "/tmp/remote-native-file")
        link.hostBoard.clearContents(); link.hostBoard.writeObjects([url as NSURL])
        link.host.refresh(); link.pump()
        // A native file copy changes ownership without copying a remote path as
        // if it were a usable local file or uploading the old local clipboard.
        #expect(link.viewerBoard.string(forType: .string) == "old local")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted.count == 1 && link.files.isEmpty)
        #expect((link.hostBoard.readObjects(forClasses: [NSURL.self]) as? [URL]) == [url])
        let large = String(repeating: "中", count: 6000)
        Link.copy(large, to: link.hostBoard)
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted.last == large)
    }

    @Test @MainActor func localFilesWaitForHostArbitrationAndRejectStaleApprovals() throws {
        let link = Link(); defer { link.close() }; link.start()
        let url = URL(fileURLWithPath: "/tmp/local-file")
        link.viewerBoard.clearContents(); link.viewerBoard.writeObjects([url as NSURL])
        link.viewer.pasteUnified(); link.pump()
        #expect(link.files == [[url]])
        link.files.removeAll()
        link.viewer.pasteUnified()
        let request = try #require(link.queue.first?.1)
        link.queue.removeAll(); link.host.receive(request) // Approval is in flight.
        Link.copy("different local copy", to: link.viewerBoard)
        link.pump()
        #expect(link.files.isEmpty)
        link.viewerBoard.clearContents(); link.viewerBoard.writeObjects([url as NSURL])
        link.viewer.pasteUnified()
        Link.copy("remote copy before upload", to: link.hostBoard)
        link.pump()
        #expect(link.files.isEmpty)
        #expect(link.pasted.last == "remote copy before upload")
    }

    @Test @MainActor func inactiveViewOnlyDisabledAndClosedSessionsDoNotSynchronize() {
        let link = Link(); defer { link.close() }; link.start()
        link.viewerAllowed = false; link.viewer.refresh(); link.pump()
        Link.copy("inactive remote", to: link.hostBoard)
        link.host.refresh(); link.pump()
        #expect(link.viewerBoard.string(forType: .string) == "old local")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted.isEmpty)
        link.viewerAllowed = true; link.viewer.refresh(); link.pump()
        #expect(link.viewerBoard.string(forType: .string) == "inactive remote")
        link.hostAllowed = false
        Link.copy("view only secret", to: link.hostBoard)
        link.host.refresh(); link.pump()
        link.host.receive(.init(action: .write, text: "unapproved write"))
        link.host.receive(.init(action: .paste))
        #expect(link.hostBoard.string(forType: .string) == "view only secret")
        #expect(link.viewerBoard.string(forType: .string) == "inactive remote")
        #expect(link.pasted.isEmpty)
        link.host.close(); link.viewer.close()
        let count = link.sent.count
        link.hostAllowed = true
        link.host.refresh(); link.viewer.refresh()
        link.viewer.receive(.init(action: .changed, revision: 100, text: "late callback"))
        #expect(link.sent.count == count)
        #expect(link.viewerBoard.string(forType: .string) == "inactive remote")
    }

    @Test @MainActor func switchingTabsDoesNotExportAnotherRemoteComputersClipboard() {
        let first = Link(), second = Link(viewerBoard: first.viewerBoard)
        defer { second.close(releaseViewer: false); first.close() }
        second.viewerAllowed = false; second.start()
        first.start()
        Link.copy("first computer secret", to: first.hostBoard)
        first.host.refresh(); first.pump()
        first.viewerAllowed = false; first.viewer.refresh(); first.pump()
        second.viewerAllowed = true; second.viewer.refresh(); second.pump()
        #expect(second.hostBoard.string(forType: .string) == "old remote")
        second.viewer.pasteUnified(); second.pump()
        #expect(second.hostBoard.string(forType: .string) == "old remote")
        #expect(second.pasted == ["old remote"])
    }

    @Test @MainActor func resumeNegotiatesRemoteRevisionBeforePublishingANewLocalCopy() {
        let link = Link(); defer { link.close() }; link.start()
        link.viewerAllowed = false; link.viewer.refresh(); link.pump()
        Link.copy("copy while remote was in background", to: link.hostBoard)
        Link.copy("new local copy before returning", to: link.viewerBoard)
        link.viewerAllowed = true
        link.viewer.refresh()
        // Pressing paste during the watch handshake also waits for arbitration.
        link.viewer.pasteUnified(); link.pump()
        #expect(link.hostBoard.string(forType: .string) == "new local copy before returning")
        #expect(link.pasted == ["new local copy before returning"])
    }

    @Test @MainActor func unavailableChannelDuringDeactivationStillRenegotiatesOnResume() {
        let link = Link(); defer { link.close() }; link.start()
        link.viewerAllowed = false; link.viewerWritable = false; link.viewer.refresh()
        Link.copy("remote copy during interruption", to: link.hostBoard)
        link.host.refresh()
        Link.copy("new local copy", to: link.viewerBoard)
        link.viewerWritable = true; link.viewerAllowed = true; link.viewer.refresh()
        link.viewer.pasteUnified(); link.pump()
        #expect(link.hostBoard.string(forType: .string) == "new local copy")
        #expect(link.pasted == ["new local copy"])
    }

    @Test @MainActor func inputMethodClipboardIsTemporaryAndPreservesNativeCopiedData() {
        let link = Link(); defer { link.close() }; link.start()
        Link.copy("copied selection", to: link.hostBoard)
        let nativeType = NSPasteboard.PasteboardType("com.xujiangtao.taoscreen.tests.native")
        link.hostBoard.setData(Data([1, 2, 3]), forType: nativeType)
        link.host.refresh(); link.pump()
        link.host.beforeTransientWrite()
        Link.copy("中文或语音输入", to: link.hostBoard)
        link.host.didWriteClipboard()
        let pasteKey = DesktopInput(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue)
        link.host.beforeKey(pasteKey) // The IME's own paste must see its text.
        #expect(link.hostBoard.string(forType: .string) == "中文或语音输入")
        link.host.refresh(); link.pump()
        #expect(link.viewerBoard.string(forType: .string) == "copied selection")
        link.viewer.pasteUnified(); link.pump()
        #expect(link.pasted == ["copied selection"])
        #expect(link.hostBoard.data(forType: nativeType) == Data([1, 2, 3]))
        // The same preservation also works with raw remote paste when sync is off.
        link.host.receive(.init(action: .watch, enabled: false))
        link.host.beforeTransientWrite()
        Link.copy("second input", to: link.hostBoard); link.host.didWriteClipboard()
        link.host.beforeKey(pasteKey)
        link.host.beforeKey(pasteKey)
        #expect(link.hostBoard.string(forType: .string) == "copied selection")
        link.host.beforeTransientWrite()
        Link.copy("third input", to: link.hostBoard); link.host.didWriteClipboard()
        link.host.beforeKey(pasteKey)
        Link.copy("new real copy", to: link.hostBoard)
        link.host.beforeKey(pasteKey)
        #expect(link.hostBoard.string(forType: .string) == "new real copy")
    }

    @Test @MainActor func oversizedNativeClipboardOrLockRejectsTheEntireTransientPaste() {
        let link = Link(); defer { link.close() }; link.start()
        let type = NSPasteboard.PasteboardType("com.xujiangtao.taoscreen.tests.large-native")
        link.hostBoard.clearContents()
        link.hostBoard.setData(Data(repeating: 1, count: 32 * 1024 * 1024 + 1), forType: type)
        let count = link.hostBoard.changeCount
        #expect(!link.host.beforeTransientWrite())
        let down = DesktopInput(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue)
        let up = DesktopInput(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue)
        #expect(!link.host.beforeKey(down))
        #expect(!link.host.beforeKey(up))
        #expect(link.hostBoard.changeCount == count)
        link.pump()
        #expect(link.failures.count == 1)
        link.hostAllowed = false
        #expect(!link.host.beforeTransientWrite())
        #expect(!link.host.beforeKey(down))
        #expect(!link.host.beforeKey(up))
        #expect(link.hostBoard.changeCount == count)
    }

    @Test @MainActor func legacyPeersPasteRemotelyAndLargeLocalCopiesAreRejected() {
        let link = Link(); defer { link.close() }
        // A peer that never announces the new protocol must never have its
        // clipboard overwritten by the default Command-V route.
        link.viewer.pasteUnified()
        #expect(link.pasted == ["old remote"] && link.queue.isEmpty)
        link.start()
        Link.copy(String(repeating: "中", count: 6000), to: link.viewerBoard)
        link.viewer.pasteUnified(); link.pump()
        #expect(link.failures.count == 1)
        #expect(link.hostBoard.string(forType: .string) == "old remote")
    }

    @Test func clipboardProtocolRejectsAmbiguousActionsAndOversizedEncodedText() throws {
        #expect(DesktopClipboardMessage(action: .status).isValid)
        #expect(!DesktopClipboardMessage(action: .paste, local: true).isValid)
        #expect(!DesktopClipboardMessage(action: .paste, local: true, text: "text", request: UUID()).isValid)
        #expect(!DesktopClipboardMessage(action: .changed, text: String(repeating: "中", count: 6000)).isValid)
        #expect(!DesktopClipboardMessage(action: .changed, text: String(repeating: "\u{01}", count: 16_000)).isValid)
        #expect(!DesktopClipboardMessage(action: .files).isValid)
        let message = DesktopClipboardMessage(action: .changed, revision: 12, text: "hello")
        let input = try JSONDecoder().decode(DesktopInput.self, from: JSONEncoder().encode(message))
        #expect(!input.isValid)
        let ime = try DesktopInput.textPaste("输入法", transient: true)
        #expect(ime[1].transient == true)
        #expect(ime.map(\.kind) == ["release", "clipboard", "key", "key"])
    }
}
