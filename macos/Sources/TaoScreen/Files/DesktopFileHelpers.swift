import CryptoKit
import Foundation

enum DesktopFileLimits {
    static let maxItems = 1000
    static let maxTotalBytes: Int64 = 50 << 30
    static let maxPathBytes = 1024
    static let maxPathDepth = 32
}
struct DesktopFileFailure: Error, LocalizedError, Equatable, Sendable {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }

    static func badRequest(_ message: String) -> DesktopFileFailure { .init(status: 400, code: "bad_request", message: message) }
    static let unauthorized = DesktopFileFailure(status: 401, code: "unauthorized", message: L10n.text("对方不是同一账户的设备。"))
    static let notFound = DesktopFileFailure(status: 404, code: "not_found", message: L10n.text("传输不存在或已取消。"))
    static func conflict(_ message: String) -> DesktopFileFailure { .init(status: 409, code: "conflict", message: message) }
    static let tooLarge = DesktopFileFailure(status: 413, code: "too_large", message: L10n.text("文件数量或总大小超过上限。"))
    static let insufficientSpace = DesktopFileFailure(status: 507, code: "insufficient_space", message: L10n.text("对方磁盘空间不足。"))
    static let busy = DesktopFileFailure(status: 503, code: "busy", message: L10n.text("对方同时进行的传输过多，请稍后重试。"))
    static func `internal`(_ message: String) -> DesktopFileFailure { .init(status: 500, code: "internal", message: message) }

    struct Envelope: Codable {
        struct Body: Codable { let code: String; let message: String }
        let error: Body
    }
}

// MARK: - 路径

enum DesktopFilePath {
    /// 接收方校验相对路径：逐段拒绝空段、`.`、`..`、控制字符、`\` 与 `:`，不做猜测性修正。
    static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= DesktopFileLimits.maxPathBytes else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= DesktopFileLimits.maxPathDepth else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 255
                && !part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == "\\" || $0 == ":" }
        }
    }

    /// 发送方把本地文件名转成协议允许的一段：替换不允许的字符，`.`、`..` 与空名改为下划线。
    static func component(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar.value == 0x7f || scalar == "\\" || scalar == ":" || scalar == "/" ? "_" : scalar)
        }
        var text = String(scalars)
        if text.isEmpty || text == "." || text == ".." { text = "_" }
        while text.utf8.count > 255 { text.removeLast() }
        return text
    }

    /// 同一批里不能有大小写或 Unicode 规范化后相同的路径，也不能有文件挡在另一个文件的目录位置上。
    static func conflicts(_ paths: [String], directories: Set<String> = []) -> Bool {
        let keys = paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let directoryKeys = Set(directories.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let files = Set(keys)
        guard files.count == keys.count else { return true }
        for key in keys {
            var prefix = ""
            for part in key.split(separator: "/").dropLast() {
                prefix += prefix.isEmpty ? String(part) : "/" + part
                if files.contains(prefix), !directoryKeys.contains(prefix) { return true }
            }
        }
        return false
    }
}

// MARK: - 本地记录

/// 一批传输（收或发）在本机的记录。只存在本机数据库，不参与云同步。

enum DesktopFileSources {
    struct Source: Sendable, Equatable {
        let path: String
        let url: URL
        let bytes: Int64
        var isDirectory = false
    }

    static func collect(_ urls: [URL], includeDirectories: Bool = false) throws -> [Source] {
        var sources: [Source] = []
        var topNames = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for original in urls {
            try Task.checkCancellation()
            let url = original.resolvingSymlinksInPath()
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                throw DesktopFileFailure.badRequest(L10n.text("无法读取「\(original.lastPathComponent)」，文件可能已被移走。"))
            }
            let top = uniqueName(DesktopFilePath.component(original.lastPathComponent), taken: &topNames)
            if values.isRegularFile == true {
                sources.append(Source(path: top, url: url, bytes: Int64(values.fileSize ?? 0)))
            } else if values.isDirectory == true {
                if includeDirectories { sources.append(Source(path: top, url: url, bytes: 0, isDirectory: true)) }
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
                var files: [Source] = []
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    let info = try file.resourceValues(forKeys: Set(keys))
                    guard info.isSymbolicLink != true, info.isRegularFile == true || (includeDirectories && info.isDirectory == true), file.lastPathComponent != ".DS_Store" else { continue }
                    let relative = file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count)
                        .split(separator: "/").map { DesktopFilePath.component(String($0)) }
                    files.append(Source(path: ([top] + relative).joined(separator: "/"), url: file,
                                        bytes: info.isDirectory == true ? 0 : Int64(info.fileSize ?? 0), isDirectory: info.isDirectory == true))
                }
                sources += files.sorted { $0.path < $1.path }
            }
            guard sources.count <= DesktopFileLimits.maxItems else {
                throw DesktopFileFailure.badRequest(L10n.text("一次最多发送 \(DesktopFileLimits.maxItems) 个文件，可先压缩文件夹再发送。"))
            }
        }
        guard !sources.isEmpty else { throw DesktopFileFailure.badRequest(L10n.text("没有可发送的文件（空文件夹或不支持的类型）。")) }
        guard sources.reduce(0, { $0 + $1.bytes }) <= DesktopFileLimits.maxTotalBytes else { throw DesktopFileFailure.tooLarge }
        guard sources.allSatisfy({ DesktopFilePath.isValid($0.path) }),
              !DesktopFilePath.conflicts(sources.map(\.path), directories: Set(sources.filter(\.isDirectory).map(\.path))) else {
            throw DesktopFileFailure.badRequest(L10n.text("文件名过长、层级过深或在不区分大小写时重名。"))
        }
        return sources
    }

    private static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var number = 2
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

enum DesktopFileUtilities {
    static let spaceMargin: Int64 = 256 << 20
    static func availableSpace(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func sha256(of url: URL, limit: Int64? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: Int(min(Int64(1 << 20), remaining)))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        if limit != nil, remaining > 0 { return nil }
        return hex(hasher.finalize())
    }

    /// 与隔空投送一致加隔离标记，收到的可执行文件首次打开时由门禁检查。
    static func quarantine(_ url: URL) {
        let value = String(format: "0083;%08x;TaoScreen;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { pointer in
            setxattr(url.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
        }
    }
}
