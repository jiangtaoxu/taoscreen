import AppKit
import CryptoKit
import Foundation

/// 独立可靠 DataChannel 上的有界文件协议；一次发送一批，每 128 KB 等待落盘确认。
struct DesktopFilePacket: Codable {
    var kind: String
    var id: UUID
    var sequence: Int
    var path: String?
    var bytes: Int64?
    var count: Int?
    var offset: Int64?
    var data: Data?
    var digest: String?
    var paste: Bool?
    var message: String?
    var drop: DesktopDropPoint?
    var warning: Bool?
    var paths: [String]?
    static let chunkSize = 16 * 1024
    static let maxPacketSize = 32 * 1024
}

/// 接收内容先写到独占暂存目录，完整校验后才放入下载目录；失败或断线删除整批暂存。
final class DesktopFileReceiver {
    private let root: URL
    private let dropRoot: URL?
    private var batchRoot: URL?
    private(set) var id: UUID?
    private var staging: URL?
    private var handle: FileHandle?
    private var hash = SHA256()
    private var sequence = 0
    private var expectedCount = 0
    private var expectedBytes: Int64 = 0
    private var completedCount = 0
    private var receivedBytes: Int64 = 0
    private var fileBytes: Int64 = 0
    private var fileReceived: Int64 = 0
    private var paths: [String] = []
    private var directories = Set<String>()
    private var shouldPaste = false
    private var lastProgress = Date.distantPast
    var onProgress: ((Double) -> Void)?
    var onFinish: (([URL], Bool) -> Void)?

    init(root: URL, dropRoot: URL? = nil) { self.root = root; self.dropRoot = dropRoot }

    func receive(_ packet: DesktopFilePacket) throws {
        if packet.kind == "cancel" {
            if packet.id == id { cancel() }
            return
        }
        if packet.kind == "begin" {
            guard id == nil, packet.sequence == 1, let count = packet.count, (1...1000).contains(count),
                  let bytes = packet.bytes, (0...DesktopFileLimits.maxTotalBytes).contains(bytes) else {
                throw DesktopFileFailure.badRequest(L10n.text("文件批次无效或已有传输正在进行。"))
            }
            guard packet.drop == nil || (packet.drop?.isValid == true && dropRoot != nil) else { throw DesktopFileFailure.badRequest(L10n.text("拖放目标无效。")) }
            let destinationRoot = packet.drop == nil ? root : dropRoot!
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            if packet.drop != nil { DesktopDropStorage.prune(root: destinationRoot) }
            guard DesktopFileUtilities.availableSpace(destinationRoot) >= bytes + DesktopFileUtilities.spaceMargin else { throw DesktopFileFailure.insufficientSpace }
            let folder = destinationRoot.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            staging = folder; batchRoot = destinationRoot; id = packet.id; sequence = 1
            expectedCount = count; expectedBytes = bytes; shouldPaste = packet.paste == true
            onProgress?(0)
            return
        }
        guard packet.id == id, packet.sequence == sequence + 1, let staging else {
            throw DesktopFileFailure.badRequest(L10n.text("文件传输顺序无效。"))
        }
        switch packet.kind {
        case "file", "directory":
            let directory = packet.kind == "directory"
            let nextDirectories = directory ? directories.union([packet.path ?? ""]) : directories
            guard handle == nil, completedCount < expectedCount, let path = packet.path, DesktopFilePath.isValid(path),
                  !DesktopFilePath.conflicts(paths + [path], directories: nextDirectories), let bytes = packet.bytes,
                  !directory || bytes == 0,
                  bytes >= 0, bytes <= expectedBytes - receivedBytes else { throw DesktopFileFailure.badRequest(L10n.text("文件路径或大小无效。")) }
            let target = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 目录由本批次创建；仍拒绝被本机其他进程替换成符号链接的路径。
            var ancestor = target.deletingLastPathComponent()
            while ancestor.path.hasPrefix(staging.path) {
                guard try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw DesktopFileFailure.badRequest(L10n.text("接收路径包含符号链接。")) }
                if ancestor == staging { break }
                ancestor.deleteLastPathComponent()
            }
            if directory {
                // Parent entries may arrive after a child; existing directories
                // are accepted only if they are real directories in this batch.
                if FileManager.default.fileExists(atPath: target.path) {
                    let info = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isDirectory == true, info.isSymbolicLink != true else { throw DesktopFileFailure.badRequest(L10n.text("目录路径冲突。")) }
                } else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                paths.append(path); directories = nextDirectories; completedCount += 1
                break
            }
            guard !FileManager.default.fileExists(atPath: target.path), FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw DesktopFileFailure.badRequest(L10n.text("无法创建接收文件。"))
            }
            handle = try FileHandle(forWritingTo: target)
            paths.append(path); fileBytes = bytes; fileReceived = 0; hash = SHA256()
        case "chunk":
            guard let handle, let data = packet.data, !data.isEmpty, data.count <= DesktopFilePacket.chunkSize,
                  packet.offset == fileReceived, Int64(data.count) <= fileBytes - fileReceived else {
                throw DesktopFileFailure.badRequest(L10n.text("文件数据超出声明大小或顺序无效。"))
            }
            try handle.write(contentsOf: data)
            hash.update(data: data); fileReceived += Int64(data.count); receivedBytes += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = Date()
                onProgress?(expectedBytes > 0 ? Double(receivedBytes) / Double(expectedBytes) : 0)
            }
        case "endFile":
            guard let handle, fileReceived == fileBytes, packet.digest == DesktopFileUtilities.hex(hash.finalize()) else {
                throw DesktopFileFailure.badRequest(L10n.text("文件不完整或校验失败。"))
            }
            try handle.synchronize(); try handle.close(); self.handle = nil; completedCount += 1
        case "finish":
            guard handle == nil, completedCount == expectedCount, receivedBytes == expectedBytes else {
                throw DesktopFileFailure.badRequest(L10n.text("文件批次尚未完整接收。"))
            }
            let destination = (batchRoot ?? root).appendingPathComponent("接收-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            let names = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) }).sorted()
            let urls = names.map { destination.appendingPathComponent($0) }
            let paste = shouldPaste
            self.staging = nil
            cancel()
            onFinish?(urls, paste)
            return
        default: throw DesktopFileFailure.badRequest(L10n.text("未知文件传输消息。"))
        }
        sequence = packet.sequence
    }

    func cancel() {
        try? handle?.close(); handle = nil
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil; batchRoot = nil; id = nil; paths = []; directories = []; sequence = 0; completedCount = 0; receivedBytes = 0
    }
    deinit { cancel() }
}

/// Disk access and hashing stay on this actor; the main actor only owns protocol/UI state.
actor DesktopFileIO {
    struct Receipt {
        var id: UUID?
        var progress: Double?
        var files: [URL]?
        var paste = false
    }
    private let receiver: DesktopFileReceiver
    private var stopped = false
    private var source: FileHandle?
    private var hash = SHA256()

    init(root: URL, dropRoot: URL?) { receiver = DesktopFileReceiver(root: root, dropRoot: dropRoot) }

    func receive(_ packet: DesktopFilePacket) throws -> Receipt {
        guard !stopped else { throw CancellationError() }
        var receipt = Receipt()
        receiver.onProgress = { receipt.progress = $0 }
        receiver.onFinish = { receipt.files = $0; receipt.paste = $1 }
        defer { receiver.onProgress = nil; receiver.onFinish = nil }
        try receiver.receive(packet)
        receipt.id = receiver.id
        return receipt
    }
    func cancelReceiving() { receiver.cancel() }
    func open(_ url: URL) throws {
        guard !stopped else { throw CancellationError() }
        try source?.close()
        source = try FileHandle(forReadingFrom: url); hash = SHA256()
    }
    func read(_ count: Int) throws -> Data {
        guard !stopped, let source else { throw CancellationError() }
        guard let data = try source.read(upToCount: count), !data.isEmpty else {
            throw DesktopFileFailure.badRequest(L10n.text("文件读取不完整。"))
        }
        hash.update(data: data)
        return data
    }
    func finishReading() throws -> String {
        let digest = DesktopFileUtilities.hex(hash.finalize())
        try source?.close(); source = nil
        return digest
    }
    func cancelReading() { try? source?.close(); source = nil }
    func close() { stopped = true; cancelReading(); receiver.cancel() }
}

@MainActor
final class DesktopFileTransfer {
    private let io: DesktopFileIO
    private var incomingID: UUID?
    private var receiving: Task<Void, Never>?
    private var incoming: [(DesktopFilePacket, Int)] = []
    private var incomingBytes = 0
    private var cancelledIncoming = Set<UUID>()
    private let isHost: Bool
    private let sendData: (Data) -> Bool
    private let allowed: () -> Bool
    private lazy var replies = DesktopReliableSender(limit: 64 * 1024, timeout: 5, send: { [weak self] data in
        guard let self, !self.stopped else { return false }
        return self.sendData(data)
    }, failed: { [weak self] in
        self?.onReceiveStatus?(L10n.text("文件通道持续拥塞，请重新连接。"), nil)
        if self?.state?.active == true { self?.update(.failed, L10n.text("文件通道持续拥塞，请重新连接。")) }
        self?.close()
    })
    private var sending: Task<Void, Never>?
    private var outgoingID: UUID?
    private var acknowledged = 0
    private var lastSequence = 0
    private var remoteError: String?
    private var stopped = false
    private var preparation: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var deliveryToken: UUID?
    private var preparedID: UUID?
    private var preparedPoint: DesktopDropPoint?
    private var preparedReply = false
    private var dropFiles: [URL]?
    private var result: DesktopDropResult?
    private var state: DesktopTransferState?
    var supportsDirectories = false
    var reverseEnabled = false
    var canSend: Bool { !stopped && allowed() && (!isHost || reverseEnabled) && sending == nil }
    var onStatus: ((String, Double?) -> Void)?
    var onReceiveStatus: ((String, Double?) -> Void)?
    var onFiles: (([URL], Bool) -> Void)?
    var onState: ((DesktopTransferState) -> Void)?
    var onPrepareDrop: ((DesktopDropPoint) async -> Void)?
    var onDropDescription: (() -> String)?
    var onDeliverDrop: (([URL]) async -> DesktopDropResult)?
    var onCancelDrop: (() -> Void)?

    init(host: Bool, root: URL, dropRoot: URL? = nil, allowed: @escaping () -> Bool, send: @escaping (Data) -> Bool) {
        isHost = host; io = DesktopFileIO(root: root, dropRoot: dropRoot); self.allowed = allowed; sendData = send
    }

    func receive(_ data: Data) {
        guard !stopped, data.count <= DesktopFilePacket.maxPacketSize,
              let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data) else { return }
        if ["prepared", "ack", "error"].contains(packet.kind) {
            guard packet.id == outgoingID else { return }
            if packet.kind == "prepared" { preparedReply = true; state?.destinationHint = packet.message }
            if packet.kind == "ack", packet.sequence <= lastSequence {
                acknowledged = max(acknowledged, packet.sequence)
                if let message = packet.message { result = .init(message: message, warning: packet.warning == true, paths: packet.paths ?? []) }
            }
            if packet.kind == "error" { remoteError = packet.message ?? L10n.text("远端接收失败。") }
            return
        }
        guard isHost || reverseEnabled else { return }
        if packet.kind == "cancel" {
            guard cancelledIncoming.count < 64 else { close(); return }
            cancelledIncoming.insert(packet.id)
            if preparedID == packet.id { resetDrop() }
        }
        // The sender waits every eight chunks. Bound even malformed/over-eager peers.
        guard incomingBytes + data.count <= 512 * 1024, incoming.count < 64 else {
            reply(.init(kind: "error", id: packet.id, sequence: packet.sequence, message: L10n.text("文件接收队列已满，请重新连接。")))
            onReceiveStatus?(L10n.text("文件接收队列已满，请重新连接。"), nil)
            if state?.active == true { update(.failed, L10n.text("文件接收队列已满，请重新连接。")) }
            close()
            return
        }
        incoming.append((packet, data.count)); incomingBytes += data.count
        guard receiving == nil else { return }
        receiving = Task { [weak self] in
            guard let self else { return }
            defer { self.receiving = nil }
            while !self.stopped, !Task.isCancelled, !self.incoming.isEmpty {
                let (next, bytes) = self.incoming.removeFirst()
                self.incomingBytes -= bytes
                await self.process(next)
            }
        }
    }

    private func process(_ packet: DesktopFilePacket) async {
        // Cancellation can arrive while disk work is suspended. Never prepare/paste/drop afterwards.
        if packet.kind != "cancel", cancelledIncoming.contains(packet.id) { return }
        defer { if packet.kind == "cancel" { cancelledIncoming.remove(packet.id) } }
        if packet.kind == "cancel", packet.id != incomingID, packet.id != preparedID { return }
        if !isHost, packet.kind == "prepare" || packet.drop != nil || packet.paste == true {
            reply(.init(kind: "error", id: packet.id, sequence: packet.sequence, message: L10n.text("控制端仅接收保存到下载目录的文件。")))
            return
        }
        if let incomingID, incomingID != packet.id {
            reply(.init(kind: "error", id: packet.id, sequence: packet.sequence, message: L10n.text("上一批文件正在接收。")))
            return
        }
        do {
            guard allowed() else { throw DesktopFileFailure.badRequest(L10n.text("当前连接未允许文件传输。")) }
            if delivery != nil {
                if packet.kind == "cancel", packet.id == preparedID {
                    resetDrop(); onReceiveStatus?(L10n.text("文件已保存，自动投放已取消。"), nil)
                    reply(.init(kind: "ack", id: packet.id, sequence: packet.sequence))
                } else if packet.id != preparedID {
                    reply(.init(kind: "error", id: packet.id, sequence: packet.sequence, message: L10n.text("上一批文件正在投放。")))
                }
                // Repeated finish packets cannot inject the same files again.
                return
            }
            if packet.kind == "prepare" {
                guard packet.sequence == 0, let point = packet.drop, point.isValid, incomingID == nil,
                      preparedID == nil, onPrepareDrop != nil else { throw DesktopFileFailure.badRequest(L10n.text("无法准备拖放目标。")) }
                preparedID = packet.id; preparedPoint = point
                preparation = Task { [weak self] in
                    guard let self, !Task.isCancelled, !self.stopped, self.allowed(), self.preparedID == packet.id else { return }
                    await self.onPrepareDrop?(point)
                    guard !Task.isCancelled, !self.stopped, self.allowed(), self.preparedID == packet.id else { return }
                    self.reply(.init(kind: "prepared", id: packet.id, sequence: 0, message: self.onDropDescription?()))
                }
                return
            }
            if packet.kind == "begin" {
                guard (packet.drop == nil && preparedID == nil) || (packet.drop != nil && preparedID == packet.id && preparedPoint == packet.drop) else {
                    throw DesktopFileFailure.badRequest(L10n.text("拖放批次与目标不匹配。"))
                }
            }
            let receipt = try await io.receive(packet)
            guard !stopped, !Task.isCancelled else { return }
            incomingID = receipt.id
            if packet.kind != "cancel", cancelledIncoming.contains(packet.id) { return }
            guard allowed() else { throw DesktopFileFailure.badRequest(L10n.text("当前连接未允许文件传输。")) }
            if let progress = receipt.progress { onReceiveStatus?(L10n.text("正在接收文件…"), progress) }
            if let urls = receipt.files {
                if preparedID != nil { dropFiles = urls }
                else {
                    onReceiveStatus?(L10n.text("已收到 \(urls.count) 项，保存在下载 / TaoScreen。"), nil)
                    onFiles?(urls, receipt.paste)
                    if !isHost {
                        reply(.init(kind: "ack", id: packet.id, sequence: packet.sequence,
                                    message: L10n.text("已发送 \(urls.count) 项到控制端的下载 / TaoScreen。")))
                        return
                    }
                }
            }
            if packet.kind == "finish", let urls = dropFiles {
                dropFiles = nil
                let token = UUID(); deliveryToken = token
                delivery = Task { [weak self] in
                    guard let self, !Task.isCancelled, !self.stopped, self.deliveryToken == token else { return }
                    let fallback = DesktopDropResult(message: L10n.text("文件已保存到远端暂存目录，未自动投放。"), warning: true, paths: urls.map(\.path))
                    let outcome = self.allowed() ? (await self.onDeliverDrop?(urls) ?? fallback) : fallback
                    guard !Task.isCancelled, !self.stopped, self.deliveryToken == token else { return }
                    self.delivery = nil; self.deliveryToken = nil
                    self.resetDrop()
                    let paths = outcome.paths.joined().utf8.count < 12 * 1024 ? outcome.paths : [urls[0].deletingLastPathComponent().path]
                    self.reply(.init(kind: "ack", id: packet.id, sequence: packet.sequence, message: outcome.message, warning: outcome.warning, paths: paths))
                    self.onReceiveStatus?(outcome.message, nil)
                }
                return
            }
            reply(.init(kind: "ack", id: packet.id, sequence: packet.sequence))
            if packet.kind == "cancel", preparedID == nil || preparedID == packet.id { resetDrop(); onReceiveStatus?(L10n.text("文件传输已取消。"), nil) }
        } catch {
            await io.cancelReceiving()
            guard !stopped, !Task.isCancelled else { return }
            incomingID = nil
            resetDrop()
            reply(.init(kind: "error", id: packet.id, sequence: packet.sequence, message: error.localizedDescription))
            onReceiveStatus?(error.localizedDescription, nil)
        }
    }

    @discardableResult
    func send(_ urls: [URL], paste: Bool, drop: DesktopDropPoint? = nil) -> Bool {
        guard canSend, !urls.isEmpty, urls.allSatisfy(\.isFileURL), drop?.isValid != false,
              !isHost || (!paste && drop == nil) else { return false }
        let id = UUID()
        outgoingID = id; acknowledged = 0; lastSequence = 0; remoteError = nil; preparedReply = false; result = nil
        state = .init(phase: .preparing, message: drop == nil ? L10n.text("正在整理文件…") : L10n.text("正在确认远端投放位置…"))
        publish()
        sending = Task { [weak self] in
            guard let self else { return }
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() }; self.sending = nil; self.outgoingID = nil }
            do {
                try self.checkActive()
                if let drop {
                    let data = try JSONEncoder().encode(DesktopFilePacket(kind: "prepare", id: id, sequence: 0, drop: drop))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                    while !self.sendData(data) {
                        try self.checkActive()
                        guard ContinuousClock.now < deadline else { throw CloudError(L10n.text("文件通道尚未就绪，请重试。")) }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    while !self.preparedReply {
                        try self.checkActive()
                        guard ContinuousClock.now < deadline else { throw CloudError(L10n.text("等待远端确认投放位置超时。")) }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                self.update(.preparing, L10n.text("正在整理文件…"))
                let includeDirectories = self.supportsDirectories
                let collection = Task.detached { try DesktopFileSources.collect(urls, includeDirectories: includeDirectories) }
                let sources = try await withTaskCancellationHandler(operation: { try await collection.value }, onCancel: { collection.cancel() })
                try self.checkActive()
                let total = sources.reduce(Int64(0)) { $0 + $1.bytes }
                self.state?.total = total; self.state?.fileCount = sources.count
                self.update(.sending, L10n.text("等待远端接收…"))
                try await self.transmit(.init(kind: "begin", id: id, sequence: 0, bytes: total, count: sources.count, paste: paste, drop: drop), wait: true)
                var done: Int64 = 0
                var lastProgress = Date.distantPast
                for source in sources {
                    self.state?.fileIndex += 1
                    self.update(.sending, source.path)
                    if source.isDirectory {
                        try await self.transmit(.init(kind: "directory", id: id, sequence: 0, path: source.path, bytes: 0), wait: true)
                        continue
                    }
                    try await self.transmit(.init(kind: "file", id: id, sequence: 0, path: source.path, bytes: source.bytes), wait: true)
                    try await self.io.open(source.url)
                    var offset: Int64 = 0
                    while offset < source.bytes {
                        try self.checkActive()
                        let chunk = try await self.io.read(Int(min(Int64(DesktopFilePacket.chunkSize), source.bytes - offset)))
                        try await self.transmit(.init(kind: "chunk", id: id, sequence: 0, offset: offset, data: chunk), wait: self.lastSequence % 8 == 0)
                        offset += Int64(chunk.count); done += Int64(chunk.count)
                        if Date().timeIntervalSince(lastProgress) >= 0.1 {
                            lastProgress = Date()
                            self.state?.bytes = done
                            self.update(.sending, source.path)
                        }
                    }
                    let digest = try await self.io.finishReading()
                    try await self.transmit(.init(kind: "endFile", id: id, sequence: 0, digest: digest), wait: true)
                }
                self.state?.bytes = total
                self.update(.delivering, drop == nil ? L10n.text("等待远端校验并确认保存…") : L10n.text("传输完成，正在投放到远端目标…"))
                try await self.transmit(.init(kind: "finish", id: id, sequence: 0), wait: true)
                if let result = self.result {
                    self.state?.paths = result.paths
                    self.update(result.warning ? .warning : .completed, result.message)
                } else if self.isHost {
                    self.update(.warning, L10n.text("传输结束，请在控制端的下载 / TaoScreen 确认文件。"))
                } else {
                    self.update(drop == nil ? .completed : .warning, drop != nil ? L10n.text("文件已传输，但未收到投放结果，请检查远端。") : paste ? L10n.text("文件已送达，并已请求在远端粘贴。") : L10n.text("文件已送达远端下载 / TaoScreen。"))
                }
            } catch {
                await self.io.cancelReading()
                self.reply(.init(kind: "cancel", id: id, sequence: 0))
                if !self.stopped { self.update(error is CancellationError ? .cancelled : .failed, error is CancellationError ? L10n.text("文件传输已取消。") : error.localizedDescription) }
            }
        }
        return true
    }

    private func update(_ phase: DesktopTransferState.Phase, _ message: String) {
        state?.phase = phase; state?.message = message; state?.updatedAt = .now; publish()
    }
    private func publish() {
        guard let state else { return }
        onState?(state)
        onStatus?(state.message, state.active ? (state.progress ?? (state.phase == .delivering ? 1 : 0)) : nil)
    }
    private func resetDrop() {
        delivery?.cancel(); delivery = nil; deliveryToken = nil
        preparation?.cancel(); preparation = nil; preparedID = nil; preparedPoint = nil; dropFiles = nil; onCancelDrop?()
    }

    private func transmit(_ packet: DesktopFilePacket, wait: Bool) async throws {
        try checkActive()
        lastSequence += 1
        var packet = packet; packet.sequence = lastSequence
        let data = try JSONEncoder().encode(packet)
        guard data.count <= DesktopFilePacket.maxPacketSize else { throw DesktopFileFailure.tooLarge }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !sendData(data) {
            try checkActive()
            guard ContinuousClock.now < deadline else { throw CloudError(L10n.text("文件通道无法发送，请重新连接。")) }
            try await Task.sleep(for: .milliseconds(10))
        }
        if wait {
            while acknowledged < packet.sequence {
                try checkActive()
                guard ContinuousClock.now < deadline else { throw CloudError(L10n.text("等待远端接收文件超时。")) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped, allowed() else { throw CancellationError() }
        if let remoteError { throw CloudError(remoteError) }
    }
    private func reply(_ packet: DesktopFilePacket) {
        var packet = packet
        guard var data = try? JSONEncoder().encode(packet) else { return }
        if data.count > DesktopFilePacket.maxPacketSize {
            packet.paths = packet.paths?.first.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] }
            packet.message = packet.message.map { String($0.prefix(2000)) }
            guard let reduced = try? JSONEncoder().encode(packet), reduced.count <= DesktopFilePacket.maxPacketSize else { return }
            data = reduced
        }
        replies.send(data)
    }
    func cancelSending() {
        guard sending != nil else { return }
        state?.message = L10n.text("正在取消传输…"); publish(); sending?.cancel()
    }
    func close() {
        guard !stopped else { return }
        stopped = true; sending?.cancel(); receiving?.cancel(); replies.close()
        incoming.removeAll(); incomingBytes = 0; incomingID = nil; cancelledIncoming.removeAll()
        resetDrop()
        Task { await io.close() }
    }

    /// Wait for accepted disk work/cleanup; useful for shutdown verification without blocking the UI.
    func waitForReceiving() async {
        await receiving?.value
        if stopped { await io.close() }
    }
}
