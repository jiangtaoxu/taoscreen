import Foundation

enum DesktopVideoPreset: String, Codable, CaseIterable {
    case economy, standard, smooth, high, ultra

    var title: String {
        switch self {
        case .economy: "节省流量 · 720p · 15 帧"
        case .standard: "标准 · 1080p · 30 帧"
        case .smooth: "流畅优先 · 1080p · 60 帧"
        case .high: "高清 · 1440p · 30 帧"
        case .ultra: "超清 · 4K · 30 帧"
        }
    }

    var framesPerSecond: Int { self == .economy ? 15 : self == .smooth ? 60 : 30 }
    var maximumLongEdge: Int {
        switch self {
        case .economy: 1280
        case .standard, .smooth: 1920
        case .high: 2560
        case .ultra: 3840
        }
    }
    var maximumPixels: Int { maximumLongEdge * maximumLongEdge / 16 * 9 }
    var initialBitrate: Int {
        switch self {
        case .economy: 2_000_000
        case .standard: 4_000_000
        case .smooth, .ultra: 8_000_000
        case .high: 6_000_000
        }
    }
    var maximumBitrate: Int {
        switch self {
        case .economy: 4_000_000
        case .standard: 8_000_000
        case .smooth, .high: 16_000_000
        case .ultra: 24_000_000
        }
    }
}

/// 被控端确认的采集配置；不是接收端测得的实时分辨率或帧率。
struct DesktopVideoFormat: Equatable {
    let preset: DesktopVideoPreset
    let width: Int
    let height: Int

    var isValid: Bool {
        width >= 2 && height >= 2 && width % 2 == 0 && height % 2 == 0
            && width <= preset.maximumLongEdge && height <= preset.maximumLongEdge
            && width * height <= preset.maximumPixels
    }
    var description: String { "采集 \(width)×\(height) · 帧率上限 \(preset.framesPerSecond) 帧/秒" }
}

/// 独立类型防止旧版把画面协商误当作键鼠输入。请求 ID 对应唯一一次应用结果。
struct DesktopVideoMessage: Codable, Equatable {
    enum Action: String, Codable { case request, status }
    var kind = "desktop-video.v1"
    var action: Action
    var requestID: UUID? = nil
    var preset: DesktopVideoPreset
    var width: Int? = nil
    var height: Int? = nil
    var failure: String? = nil

    var format: DesktopVideoFormat? {
        guard let width, let height else { return nil }
        let format = DesktopVideoFormat(preset: preset, width: width, height: height)
        return format.isValid ? format : nil
    }
    var isValid: Bool {
        guard kind == "desktop-video.v1", failure.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else { return false }
        switch action {
        case .request: return requestID != nil && width == nil && height == nil && failure == nil
        case .status:
            return format != nil || (width == nil && height == nil && failure != nil)
        }
    }
}

/// 只保存成功确认的选择；超时保留请求 ID，迟到的回执仍能确认真实结果。
struct DesktopVideoSelection {
    var preference = DesktopVideoPreset.ultra
    private(set) var supported = false
    private(set) var confirmed: DesktopVideoFormat?
    private(set) var request: DesktopVideoMessage?
    private(set) var changing = false
    private(set) var failure: String?
    private(set) var retryPreset: DesktopVideoPreset?

    var selectedPreset: DesktopVideoPreset { request?.preset ?? confirmed?.preset ?? preference }
    var statusText: String {
        if !supported { return "对方尚未声明支持画面设置，请确认被控端已升级。" }
        if changing { return "正在应用画面设置…" }
        if let failure { return failure }
        return confirmed?.description ?? "画面设置状态未确认。"
    }

    mutating func begin(_ preset: DesktopVideoPreset) -> DesktopVideoMessage? {
        guard supported, !changing else { return nil }
        let value = DesktopVideoMessage(action: .request, requestID: UUID(), preset: preset)
        request = value; changing = true; failure = nil; retryPreset = preset
        return value
    }

    @discardableResult
    mutating func receive(_ value: DesktopVideoMessage) -> Bool {
        guard value.isValid, value.action == .status else { return false }
        if let requestID = value.requestID {
            guard let request, request.requestID == requestID,
                  value.failure != nil || value.preset == request.preset else { return false }
            if value.failure == nil { preference = value.preset; retryPreset = nil }
            self.request = nil; changing = false
        }
        supported = true
        confirmed = value.format
        // 采集重建的主动状态不能把尚未完成的请求标记为成功。
        if request == nil { failure = value.failure }
        return true
    }

    mutating func expire(_ requestID: UUID) {
        guard request?.requestID == requestID else { return }
        changing = false; confirmed = nil
        failure = "尚未收到画面切换结果，当前设置状态未确认，请重试。"
    }

    mutating func sendFailed(_ requestID: UUID) {
        guard request?.requestID == requestID else { return }
        request = nil; changing = false
        failure = "画面设置未能发送，请检查连接后重试。"
    }
}

enum DesktopVideoUpdateFailure: LocalizedError {
    case restored(String), unknown(String)
    var errorDescription: String? {
        switch self {
        case .restored(let reason): "画面切换失败，已恢复原配置：\(reason)"
        case .unknown(let reason): "画面切换失败且无法确认原配置，共享已停止：\(reason)"
        }
    }
}

enum DesktopVideoUpdate {
    /// 两项配置都成功才确认；失败显式恢复原值，恢复不成功则不得继续宣称配置已确认。
    @MainActor static func apply(_ preset: DesktopVideoPreset, previous: DesktopVideoPreset,
                                encoder: (DesktopVideoPreset) throws -> Void,
                                capture: (DesktopVideoPreset) async throws -> Void) async throws {
        do {
            try encoder(preset)
            try await capture(preset)
        } catch {
            let reason = error.localizedDescription
            do {
                try await capture(previous)
                try encoder(previous)
            } catch {
                throw DesktopVideoUpdateFailure.unknown("\(reason)；恢复失败：\(error.localizedDescription)")
            }
            throw DesktopVideoUpdateFailure.restored(reason)
        }
    }
}
