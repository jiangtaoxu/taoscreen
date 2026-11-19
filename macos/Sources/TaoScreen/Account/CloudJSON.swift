import Foundation

// 服务数据的通用表示。主程序的服务引擎与注册了服务实体的插件共用这些类型，
// 服务端协议字段按原样保存，插件负责解释自己实体的字段。

public struct CloudError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum CloudJSON: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CloudJSON])
    case array([CloudJSON])
    case null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode([String: CloudJSON].self) {
            self = .object(v)
        } else {
            self = .array(try c.decode([CloudJSON].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var fields: [String: CloudJSON] {
        if case .object(let d) = self { return d }
        return [:]
    }
    public func string(_ key: String) throws -> String {
        guard case .string(let s) = fields[key] else { throw CloudError("服务字段 \(key) 无效。") }
        return s
    }
    public func id(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(key)) else { throw CloudError("服务标识 \(key) 无效。") }
        return id
    }
    public func optionalString(_ key: String) throws -> String? {
        if fields[key] == nil || fields[key] == .null { return nil }
        return try string(key)
    }
    public func optionalID(_ key: String) throws -> UUID? {
        if fields[key] == nil || fields[key] == .null { return nil }
        return try id(key)
    }
    public func int(_ key: String) throws -> Int {
        guard case .number(let n) = fields[key], n.isFinite, n.rounded() == n, n >= 0, n < Double(Int.max) else {
            throw CloudError("服务整数 \(key) 无效。")
        }
        return Int(n)
    }
    public func flag(_ key: String) throws -> Bool {
        guard case .bool(let b) = fields[key] else { throw CloudError("服务布尔值 \(key) 无效。") }
        return b
    }
    public func date(_ key: String) throws -> Date { try SyncCoding.date(string(key)) }
    public static func id(_ id: UUID) -> CloudJSON { .string(id.uuidString.lowercased()) }
    public static func optionalID(_ id: UUID?) -> CloudJSON { id.map(Self.id) ?? .null }
}

/// 服务数据的编码约定：JSON 键排序（便于比较与去重），时间使用带毫秒的 ISO 8601。
public enum SyncCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }
    public static func date(_ value: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: value) else { throw CloudError("服务器日期格式无效。") }
        return d
    }
    public static func timestamp(_ date: Date) -> CloudJSON {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(f.string(from: date))
    }
}
