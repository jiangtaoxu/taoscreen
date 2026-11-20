import AppKit

/// Separate discriminator keeps clipboard negotiation invisible to older peers.
struct DesktopClipboardMessage: Codable {
    enum Action: String, Codable { case status, watch, ready, changed, write, paste, files, failure }
    var kind = "desktop-clipboard.v1"
    var action: Action
    var revision: UInt64 = 0
    var enabled: Bool = false
    var local: Bool = false
    var text: String?
    var request: UUID?

    var isValid: Bool {
        guard kind == "desktop-clipboard.v1", (text?.utf8.count ?? 0) <= 16 * 1024,
              let data = try? JSONEncoder().encode(self), data.count <= 32 * 1024 else { return false }
        switch action {
        case .status, .watch, .ready: return text == nil && request == nil && !local
        case .changed: return request == nil && !local
        case .write: return text != nil && request == nil && !local
        case .paste: return local ? (text != nil) != (request != nil) : text == nil && request == nil
        case .files: return request != nil && text == nil && !local
        case .failure: return text != nil && request == nil && !local
        }
    }
}

/// One instance per RTC session. Only the active viewer subscribes; clipboard
/// writes from this bridge never become fresh copies and bounce back to its peer.
@MainActor
final class DesktopClipboard {
    private static let sourceType = NSPasteboard.PasteboardType("com.xujiangtao.taoscreen.desktop.clipboard-source")
    private let host: Bool
    private let board: NSPasteboard
    private let allowed: () -> Bool
    private let transientAllowed: () -> Bool
    private let send: (DesktopClipboardMessage) -> Bool
    private let paste: () -> Void
    private let pasteFiles: ([URL]) -> Void
    private let failure: (String) -> Void
    var onSupport: (() -> Void)?
    private(set) var supported = false
    private var watching = false
    private var waitingForWatch = false
    private var pendingPaste = false
    private var task: Task<Void, Never>?
    private var closed = false
    private var observedCount: Int
    private var revision: UInt64 = 0
    private var localSource = true
    private var pendingFiles: (id: UUID, urls: [URL], count: Int, deadline: TimeInterval)?
    private var preserved: Snapshot?
    private var transientPastePending = false
    private var rejectedTransientPaste = false

    init(host: Bool, board: NSPasteboard = .general, allowed: @escaping () -> Bool, transientAllowed: (() -> Bool)? = nil,
         send: @escaping (DesktopClipboardMessage) -> Bool, paste: @escaping () -> Void,
         pasteFiles: @escaping ([URL]) -> Void = { _ in }, failure: @escaping (String) -> Void = { _ in }) {
        self.host = host; self.board = board; self.allowed = allowed; self.send = send
        self.transientAllowed = transientAllowed ?? allowed
        self.paste = paste; self.pasteFiles = pasteFiles; self.failure = failure
        observedCount = board.changeCount
        localSource = board.string(forType: Self.sourceType) == nil
    }

    func open() {
        guard !closed else { return }
        if host { _ = send(.init(action: .status)) }
        refresh()
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !closed else { return }
        let active = allowed()
        if !host, supported, watching != active {
            let sent = send(.init(action: .watch, enabled: active))
            if sent || !active {
                watching = active; waitingForWatch = active
            }
        }
        if !active { pendingFiles = nil; pendingPaste = false; return }
        if let pendingFiles, ProcessInfo.processInfo.systemUptime >= pendingFiles.deadline {
            self.pendingFiles = nil
            failure(L10n.text("粘贴确认超时，请重试。"))
        }
        guard watching else { return }
        if host { pollHost() } else if !waitingForWatch { pollViewer() }
    }

    func receive(_ value: DesktopClipboardMessage) {
        guard !closed, value.isValid else { return }
        if !host, value.action == .status {
            supported = true; onSupport?(); refresh(); return
        }
        if !host, value.action == .failure { failure(value.text!); return }
        if host, value.action == .watch {
            watching = value.enabled
            if watching, allowed() {
                pollHost()
                if revision > 0 { sendCurrent() }
            }
            if watching { _ = send(.init(action: .ready, revision: revision)) }
            return
        }
        guard allowed(), watching else { return }
        if !host, value.action == .ready {
            revision = max(revision, value.revision)
            waitingForWatch = false
            pollViewer()
            if pendingPaste { pendingPaste = false; pasteUnified() }
            return
        }
        if host {
            guard value.action == .write || value.action == .paste else { return }
            // Recheck immediately, rather than trusting the polling interval or
            // a notification that may still be in flight in the other direction.
            pollHost()
            if value.action == .write {
                if value.revision == revision { write(value.text!) }
                else { sendCurrent() }
            } else if value.local, value.revision == revision {
                if let request = value.request { _ = send(.init(action: .files, request: request)) }
                else { write(value.text!); paste() }
            } else {
                if value.revision != revision { sendCurrent() }
                restorePreserved()
                paste()
            }
        } else if value.action == .changed, value.revision > revision {
            revision = value.revision
            pendingFiles = nil
            // A local copy made since the last poll must not be erased by a
            // delayed remote notification. Publish it against the new revision.
            if board.changeCount != observedCount, board.string(forType: Self.sourceType) == nil { pollViewer(); return }
            localSource = false
            observedCount = board.changeCount
            if let text = value.text {
                board.clearContents(); board.setString(text, forType: .string)
                board.setString("remote", forType: Self.sourceType)
                observedCount = board.changeCount
            }
        } else if value.action == .files, let pending = pendingFiles, value.request == pending.id {
            pendingFiles = nil
            guard board.changeCount == pending.count else { return }
            pasteFiles(pending.urls)
        }
    }

    /// Called for the normal Command-V action. Explicit "paste local" remains
    /// available independently, including when connected to an older peer.
    func pasteUnified() {
        guard !closed, !host, allowed() else { return }
        refresh()
        guard supported else { paste(); return }
        if waitingForWatch { pendingPaste = true; return }
        pollViewer()
        var value = DesktopClipboardMessage(action: .paste, revision: revision, local: localSource)
        if localSource {
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                guard pendingFiles == nil else { return }
                let id = UUID()
                value.request = id
                pendingFiles = (id, urls, board.changeCount, ProcessInfo.processInfo.systemUptime + 5)
            } else if let text = board.string(forType: .string) {
                value.text = text
            } else {
                failure(L10n.text("当前支持粘贴本机文本、文件和文件夹。"))
                return
            }
        }
        guard value.isValid else { failure(L10n.text("粘贴文本超过 16 KB 或编码后过大，请缩短后重试。")); return }
        if !send(value) { pendingFiles = nil; failure(L10n.text("剪贴板通道尚未就绪，请重试。")) }
    }

    private func pollViewer() {
        guard board.changeCount != observedCount else { return }
        observedCount = board.changeCount
        pendingFiles = nil
        // A different remote tab may have mirrored its clipboard while this
        // one was inactive. That is not a fresh user copy for this connection.
        guard board.string(forType: Self.sourceType) == nil else { localSource = false; return }
        localSource = true
        if let text = transferableText() {
            _ = send(.init(action: .write, revision: revision, text: text))
        }
    }

    private func pollHost() {
        guard board.changeCount != observedCount else { return }
        observedCount = board.changeCount
        preserved = nil
        revision += 1
        sendCurrent()
    }

    private func sendCurrent() {
        guard watching else { return }
        let text = preserved.map { $0.text } ?? transferableText()
        _ = send(.init(action: .changed, revision: revision, text: text))
    }

    private func transferableText() -> String? {
        // File paths are not file contents. Keep remote files and other native
        // formats on their source computer and forward only their paste action.
        guard board.types?.contains(.fileURL) != true, let text = board.string(forType: .string),
              DesktopDirectCode(text) == nil,
              DesktopClipboardMessage(action: .changed, revision: UInt64.max, text: text).isValid else { return nil }
        return text
    }

    private func write(_ text: String) {
        preserved = nil
        board.clearContents(); board.setString(text, forType: .string)
        observedCount = board.changeCount
    }

    /// IME/voice commits use the legacy clipboard + Command-V protocol. Keep
    /// their temporary clipboard out of copy synchronization and preserve the
    /// original native representations for the next ordinary remote paste.
    @discardableResult
    func beforeTransientWrite() -> Bool {
        guard host, !closed else { return false }
        guard transientAllowed() else { rejectedTransientPaste = true; return false }
        pollHost()
        if preserved == nil { preserved = Snapshot(board: board, text: transferableText()) }
        guard preserved != nil else {
            rejectedTransientPaste = true
            _ = send(.init(action: .failure, text: L10n.text("远端剪贴板超过 32 MB，无法保留原内容。请切换为远端输入法后重试。")))
            return false
        }
        rejectedTransientPaste = false
        transientPastePending = true
        return true
    }

    @discardableResult
    func beforeKey(_ value: DesktopInput) -> Bool {
        guard host, !closed, value.kind == "key", value.key == 9 else { return true }
        if rejectedTransientPaste {
            if value.down == false { rejectedTransientPaste = false }
            return false
        }
        guard transientAllowed(), value.down == true,
              CGEventFlags(rawValue: value.flags ?? 0).contains(.maskCommand) else { return true }
        if transientPastePending { transientPastePending = false }
        else { pollHost(); restorePreserved() }
        return true
    }

    func useLocalSource() { localSource = true }

    func didWriteClipboard() { observedCount = board.changeCount }

    func didWriteSharedClipboard() {
        preserved = nil; transientPastePending = false; rejectedTransientPaste = false
        didWriteClipboard()
    }

    private func restorePreserved() {
        guard let snapshot = preserved else { return }
        preserved = nil
        board.clearContents()
        let items = snapshot.items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
        observedCount = board.changeCount
    }

    func close() {
        guard !closed else { return }
        if host, transientAllowed(), board.changeCount == observedCount { restorePreserved() }
        // No system clipboard reads/writes after a session has ended.
        closed = true; task?.cancel(); task = nil
        pendingFiles = nil; pendingPaste = false; preserved = nil; watching = false
    }

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let text: String?
        init?(board: NSPasteboard, text: String?) {
            var items: [[NSPasteboard.PasteboardType: Data]] = []
            var bytes = 0
            for item in board.pasteboardItems ?? [] {
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { continue }
                    bytes += data.count
                    guard bytes <= 32 * 1024 * 1024 else { return nil }
                    values[type] = data
                }
                items.append(values)
            }
            self.items = items; self.text = text
        }
    }
}
