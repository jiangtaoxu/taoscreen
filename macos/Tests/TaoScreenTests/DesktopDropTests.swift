import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TaoScreen

struct DesktopDropTests {
    @Test @MainActor func controllerAcceptsOnlyNegotiatedDownloadBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("return-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var replies: [DesktopFilePacket] = []
        let controller = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: {
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: $0) { replies.append(packet) }
            return true
        })
        defer { controller.close() }
        let begin = DesktopFilePacket(kind: "begin", id: UUID(), sequence: 1, bytes: 0, count: 1)
        controller.receive(try JSONEncoder().encode(begin))
        await controller.waitForReceiving()
        #expect(replies.isEmpty)

        controller.reverseEnabled = true
        var request = begin
        request.paste = true
        controller.receive(try JSONEncoder().encode(request))
        request.paste = nil
        request.drop = .init(x: 0.5, y: 0.5)
        controller.receive(try JSONEncoder().encode(request))
        await controller.waitForReceiving()
        #expect(replies.map(\.kind) == ["error", "error"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func nativeDragGeometryStaysOnTheSelectedDisplay() {
        for display in [CGRect(x: 0, y: 0, width: 1512, height: 982),
                        CGRect(x: -1920, y: -300, width: 1920, height: 1080)] {
            for point in [CGPoint(x: display.minX, y: display.minY),
                          CGPoint(x: display.maxX - 1, y: display.maxY - 1),
                          CGPoint(x: display.midX, y: display.midY)] {
                let layout = DesktopNativeDrag.geometry(at: point, display: display, appKitTop: 982)
                #expect(display.contains(layout.start))
                #expect(abs(layout.start.x - point.x) == 24)
                #expect(layout.start.y == point.y)
                #expect(layout.panel.midX == layout.start.x)
                #expect(layout.panel.midY == 982 - layout.start.y)
                // The bootstrap window must not cover the destination and flash
                // over the receiving input field before the system drag starts.
                #expect(!layout.panel.contains(CGPoint(x: point.x, y: 982 - point.y)))
            }
        }
    }

    @Test @MainActor func disabledNativeDropDoesNotTouchClipboardOrStartSession() async {
        let native = DesktopNativeDrag()
        let version = NSPasteboard.general.changeCount
        let outcome = await native.deliver([URL(fileURLWithPath: "/tmp/test.txt")], at: .zero,
                                          display: CGRect(x: 0, y: 0, width: 100, height: 100),
                                          allowed: { false }, validateTarget: { true })
        #expect(outcome == .unavailable)
        #expect(!native.isActive && NSPasteboard.general.changeCount == version)
    }

    @Test(arguments: [false, true]) @MainActor func cancelledDeliveryIgnoresLateCompletion(close: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-late-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("payload".utf8).write(to: file)
        var outgoing: DesktopFileTransfer?
        var state: DesktopTransferState?
        var completion: CheckedContinuation<DesktopDropResult, Never>?
        var saved: [URL] = []
        var finalResults: [DesktopFilePacket] = []
        let incoming = DesktopFileTransfer(host: true, root: root, dropRoot: root.appendingPathComponent("received"),
            allowed: { true }, send: { data in
                if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data), packet.kind == "ack", packet.message != nil { finalResults.append(packet) }
                outgoing?.receive(data); return true
            })
        incoming.onPrepareDrop = { _ in }
        incoming.onDeliverDrop = { urls in
            saved = urls
            return await withCheckedContinuation { completion = $0 }
        }
        outgoing = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: { incoming.receive($0); return true })
        outgoing?.onState = { state = $0 }
        defer { outgoing?.close(); incoming.close() }
        #expect(outgoing?.send([file], paste: false, drop: .init(x: 0.5, y: 0.5)) == true)
        let deadline = Date().addingTimeInterval(5)
        while completion == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let delayed = try #require(completion)
        #expect(state?.phase == .delivering && finalResults.isEmpty)
        if close { incoming.close() }
        outgoing?.cancelSending()
        while state?.active == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state?.phase == .cancelled)
        #expect(try Data(contentsOf: #require(saved.first)) == Data("payload".utf8))
        if !close {
            incoming.onDeliverDrop = { .init(message: "second batch", warning: false, paths: $0.map(\.path)) }
            #expect(outgoing?.send([file], paste: false, drop: .init(x: 0.6, y: 0.6)) == true)
            while state?.active == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(state?.phase == .completed)
        }
        delayed.resume(returning: .init(message: "stale result", warning: false, paths: saved.map(\.path)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(finalResults.count == (close ? 0 : 1))
        #expect(!finalResults.contains { $0.message == "stale result" })
    }

    @Test func quotedPathsRoundTripThroughMacShellsWithoutExecution() throws {
        let paths = ["/tmp/说明 文件.png", "/tmp/a'b$(echo unexpected)`echo bad`;*.txt", "/tmp/文件夹/"]
        let quoted = try #require(DesktopDropStorage.shellPaths(paths))
        #expect(!quoted.contains("\n"))
        for shell in ["/bin/zsh", "/bin/bash"] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-f", "-c", "printf '%s\\0' " + quoted]
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(String(decoding: output, as: UTF8.self).split(separator: "\0").map(String.init) == paths)
        }
        #expect(DesktopDropStorage.shellPaths(["/tmp/bad\ncommand"]) == nil)
        #expect(DesktopDropStorage.shellPaths(["/tmp/bad\u{1b}"]) == nil)
        #expect(DesktopDropStorage.shellPaths(["relative"]) == nil)
    }

    @Test func temporaryFilesExpireOnlyAfterRetentionAndIgnoreUnownedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let expired = root.appendingPathComponent("接收-\(UUID())")
        let recent = root.appendingPathComponent("接收-\(UUID())")
        let unrelated = root.appendingPathComponent("接收-other")
        for item in [expired, recent, unrelated] { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true) }
        for item in [expired, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-DesktopDropStorage.retention - 1)], ofItemAtPath: item.path)
        }
        DesktopDropStorage.prune(root: root, now: now)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test @MainActor func dropWaitsForPreparationAndDeliveryAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("图片 ' 测试.png")
        let contents = Data(repeating: 42, count: 128 * 1024 + 3)
        try contents.write(to: source)
        let drops = root.appendingPathComponent("drops"), downloads = root.appendingPathComponent("downloads")
        var outgoing: DesktopFileTransfer?
        var finalAck: Data?
        var prepared = false, delivered = false
        var states: [DesktopTransferState] = []
        let incoming = DesktopFileTransfer(host: true, root: downloads, dropRoot: drops, allowed: { true }, send: { data in
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data), packet.kind == "ack", packet.message != nil {
                finalAck = data // 故意延迟结果，不能提前显示成功。
            } else { outgoing?.receive(data) }
            return true
        })
        incoming.onPrepareDrop = { point in
            #expect(point == .init(x: 0.3, y: 0.7))
            try? await Task.sleep(for: .milliseconds(50))
            prepared = true
        }
        incoming.onDeliverDrop = { urls in
            #expect(prepared)
            #expect(urls.count == 1)
            #expect(urls[0].path.hasPrefix(drops.path + "/"))
            #expect((try? Data(contentsOf: urls[0])) == contents)
            delivered = true
            return .init(message: "目标已切换，文件保留", warning: true, paths: urls.map(\.path))
        }
        outgoing = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: { data in
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data), packet.kind == "begin" { #expect(prepared) }
            incoming.receive(data); return true
        })
        outgoing?.onState = { states.append($0) }
        defer { outgoing?.close(); incoming.close() }
        #expect(outgoing?.send([source], paste: false, drop: .init(x: 0.3, y: 0.7)) == true)
        #expect(states.first?.phase == .preparing) // 调用返回前即提供反馈。
        let deadline = Date().addingTimeInterval(5)
        while finalAck == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered)
        #expect(states.last?.phase == .delivering)
        outgoing?.receive(try #require(finalAck))
        while states.last?.active == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(states.last?.phase == .warning)
        #expect(states.last?.paths.count == 1)
        #expect(states.last?.bytes == Int64(contents.count))
        #expect(!FileManager.default.fileExists(atPath: downloads.path))
    }

    @Test @MainActor func cancellingDuringPreparationNeverSendsFilesOrDelivers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-drop-cancel-\(UUID())")
        var outgoing: DesktopFileTransfer?
        var state: DesktopTransferState?
        var packets: [String] = []
        let incoming = DesktopFileTransfer(host: true, root: root, dropRoot: root, allowed: { true }, send: { outgoing?.receive($0); return true })
        incoming.onPrepareDrop = { _ in
            outgoing?.cancelSending()
            try? await Task.sleep(for: .seconds(1))
        }
        incoming.onDeliverDrop = { _ in Issue.record("取消后不应投放"); return .init(message: "", warning: true, paths: []) }
        outgoing = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: { data in
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data) { packets.append(packet.kind) }
            incoming.receive(data); return true
        })
        outgoing?.onState = { state = $0 }
        defer { outgoing?.close(); incoming.close(); try? FileManager.default.removeItem(at: root) }
        #expect(outgoing?.send([root.appendingPathComponent("nonexistent")], paste: false, drop: .init(x: 0.5, y: 0.5)) == true)
        let deadline = Date().addingTimeInterval(3)
        while state?.active == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state?.phase == .cancelled)
        #expect(packets == ["prepare", "cancel"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test @MainActor func unknownTargetsDoNotWriteClipboardOrInjectEvents() async {
        let delivery = DesktopDropDelivery()
        var events = 0
        let input = DesktopInputReceiver(canPost: { true }, post: { _ in events += 1 })
        input.enabled = true
        let version = NSPasteboard.general.changeCount
        let result = await delivery.deliver([URL(fileURLWithPath: "/tmp/retained.txt")], input: input, allowed: { true })
        #expect(result.warning && result.paths == ["/tmp/retained.txt"])
        #expect(events == 0 && NSPasteboard.general.changeCount == version)
    }

    @Test func legacyStatusDoesNotAdvertiseDropSupport() throws {
        let status = try JSONDecoder().decode(DesktopSessionStatus.self, from: Data(#"{"kind":"desktop-session.v1","locked":false}"#.utf8))
        #expect(status.fileReturn == nil)
        #expect(status.isValid && status.fileDrop == nil && status.fileDirectories == nil)
        #expect(!DesktopDropPoint(x: .nan, y: 0).isValid)
        #expect(!DesktopDropPoint(x: 1.1, y: 0).isValid)
    }

    @Test @MainActor func negotiatedDirectoryTransferPreservesEmptyFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/资料")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录/更深"), withIntermediateDirectories: true)
        try Data("contents".utf8).write(to: source.appendingPathComponent("说明.txt"))
        let entries = try DesktopFileSources.collect([source], includeDirectories: true)
        #expect(entries.filter(\.isDirectory).count == 3)
        #expect(try DesktopFileSources.collect([source]).count == 1) // Legacy wire format stays unchanged.
        #expect(!DesktopFilePath.conflicts(["folder", "folder/file"], directories: ["folder"]))
        #expect(DesktopFilePath.conflicts(["folder", "folder/file"]))
        #expect(DesktopFilePath.conflicts(["Folder", "folder"], directories: ["Folder"]))
        var outgoing: DesktopFileTransfer?
        var state: DesktopTransferState?
        var received: [URL] = []
        let incoming = DesktopFileTransfer(host: true, root: root.appendingPathComponent("received"), allowed: { true }, send: { outgoing?.receive($0); return true })
        incoming.onFiles = { urls, _ in received = urls }
        outgoing = DesktopFileTransfer(host: false, root: root, allowed: { true }, send: { incoming.receive($0); return true })
        outgoing?.supportsDirectories = true
        outgoing?.onState = { state = $0 }
        defer { outgoing?.close(); incoming.close() }
        #expect(outgoing?.send([source], paste: false) == true)
        let deadline = Date().addingTimeInterval(5)
        while state?.active == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state?.phase == .completed)
        let folder = try #require(received.first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("空目录/更深").path))
        #expect(try String(contentsOf: folder.appendingPathComponent("说明.txt"), encoding: .utf8) == "contents")
    }

    @Test @MainActor func receiverRejectsUnpreparedOrMismatchedDropBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-drop-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var replies: [DesktopFilePacket] = []
        let incoming = DesktopFileTransfer(host: true, root: root, dropRoot: root, allowed: { true }, send: { data in
            if let packet = try? JSONDecoder().decode(DesktopFilePacket.self, from: data) { replies.append(packet) }
            return true
        })
        defer { incoming.close() }
        incoming.onPrepareDrop = { _ in }
        let id = UUID(), point = DesktopDropPoint(x: 0.4, y: 0.6)
        incoming.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "begin", id: id, sequence: 1, bytes: 0, count: 1, drop: point)))
        await incoming.waitForReceiving()
        #expect(replies.last?.kind == "error")
        incoming.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "prepare", id: id, sequence: 0, drop: point)))
        let deadline = Date().addingTimeInterval(1)
        while replies.last?.kind != "prepared" && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies.last?.kind == "prepared")
        incoming.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "begin", id: id, sequence: 1, bytes: 0, count: 1, drop: .init(x: 0.8, y: 0.6))))
        await incoming.waitForReceiving()
        #expect(replies.last?.kind == "error")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        var preparations = 0
        incoming.onPrepareDrop = { _ in preparations += 1 }
        incoming.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "prepare", id: id, sequence: 0, drop: point)))
        incoming.receive(try JSONEncoder().encode(DesktopFilePacket(kind: "cancel", id: id, sequence: 0)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(preparations == 0) // 尚未执行的目标点击不能在取消后发生。
    }

    @Test @MainActor func transferHUDPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAOSCREEN_DROP_PREVIEW"] else { return }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for phase in [DesktopTransferState.Phase.preparing, .sending, .delivering, .completed, .warning, .failed] {
            let state = DesktopTransferState(phase: phase, message: phase == .sending ? "设计资源/首页 插图.png" : phase == .warning ? "目标已变化，文件已保存，未自动粘贴。" : "正在处理远端文件…", bytes: 27_000_000, total: 80_000_000, fileIndex: 2, fileCount: 5, startedAt: Date().addingTimeInterval(-8), paths: phase == .completed || phase == .warning ? ["/tmp/illustration.png"] : [])
            let renderer = ImageRenderer(content: DesktopTransferHUD(state: state, cancel: {}, dismiss: {}).padding(24).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(phase.rawValue).png"))
        }
    }
}
