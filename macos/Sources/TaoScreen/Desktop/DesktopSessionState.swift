import AppKit
import IOKit.pwr_mgt
import OSLog
import ScreenCaptureKit

/// 会话时长使用单调时钟，系统校时和同一会话的网络恢复不会重置计时。
struct DesktopConnectionTiming {
    private(set) var startedAt: Date?
    private var startedUptime: TimeInterval?

    mutating func start(date: Date = .now, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard startedUptime == nil else { return }
        startedAt = date; startedUptime = uptime
    }

    func elapsed(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        startedUptime.map { max(0, uptime - $0) }
    }

    static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds, Double(Int.max / 2)))
        return String(format: "%02ld:%02ld:%02ld", total / 3600, total / 60 % 60, total % 60)
    }
}

/// 锁屏仍属于已登录的用户；切换用户、退出登录和睡眠不能当作锁屏处理。
struct DesktopLocalSession: Equatable {
    let onConsole: Bool
    let loggedIn: Bool
    let locked: Bool

    static var current: Self {
        from(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func from(_ info: [String: Any]?) -> Self {
        Self(onConsole: info?[kCGSessionOnConsoleKey as String] as? Bool == true,
             loggedIn: info?[kCGSessionLoginDoneKey as String] as? Bool == true,
             locked: info?["CGSSessionScreenIsLocked"] as? Bool == true)
    }

    var canHost: Bool { onConsole && loggedIn }
    func canStart(unattended: Bool) -> Bool { canHost && (!locked || unattended) }
    func withLockState(_ value: Bool) -> Self {
        Self(onConsole: onConsole, loggedIn: loggedIn, locked: value)
    }
}

struct DesktopSessionStatus: Codable, Equatable {
    var kind = "desktop-session.v1"
    let locked: Bool
    var fileDrop: Bool? = nil
    var fileDirectories: Bool? = nil
    var fileReturn: Bool? = nil
    var isValid: Bool { kind == "desktop-session.v1" }
}

/// 使用单调时钟；反复握手成功也不能延长离线授权宽限期。
struct DesktopSignalRecovery {
    static let grace: TimeInterval = 60
    private(set) var deadline: TimeInterval?
    private(set) var token: UUID?
    var isRecovering: Bool { deadline != nil }

    mutating func begin(now: TimeInterval) -> Bool {
        if deadline == nil { deadline = now + Self.grace; token = UUID() }
        return now < deadline!
    }
    mutating func confirm(_ token: UUID?, now: TimeInterval) -> Bool {
        guard let deadline, now < deadline, let token, token == self.token else { return false }
        reset()
        return true
    }
    mutating func reset() { deadline = nil; token = nil }

    static func retryDelay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        min(10, pow(2, Double(min(4, max(0, attempt)))) * min(1.2, max(0.8, jitter)))
    }
}

enum DesktopSignalFailure: Equatable {
    case authentication, occupied, endpointUnavailable, invalidMessage, network

    static func classify(_ error: Error, httpStatus: Int?, closeCode: Int?) -> Self {
        let code = (error as? CloudAPIError)?.code
        let httpStatus = httpStatus ?? (error as? CloudHTTPError)?.statusCode
        if closeCode == 4001 || httpStatus == 401 || httpStatus == 403 ||
            code == "unauthorized" || code == "refresh_replayed" || code == "session_revoked" { return .authentication }
        if httpStatus == 409 || code == "already_connected" { return .occupied }
        if httpStatus == 404 { return .endpointUnavailable }
        if error is DecodingError { return .invalidMessage }
        return .network
    }
    var endsSession: Bool { self == .authentication || self == .invalidMessage }
    var message: String {
        switch self {
        case .authentication: return "登录已失效或服务器拒绝访问，请重新登录或检查服务设置。"
        case .occupied: return "此设备的信令连接仍被占用，正在等待释放；请检查是否重复运行 TaoScreen。"
        case .endpointUnavailable: return "远程桌面接口返回 HTTP 404，正在重新连接；请检查服务地址或服务器路由。"
        case .invalidMessage: return "收到无效的桌面信令，连接已停止。"
        case .network: return "信令暂时不可用，正在重新连接…"
        }
    }
}

enum DesktopSessionLog {
    private static let logger = Logger(subsystem: "com.xujiangtao.taoscreen", category: "session")
    static func record(_ message: String) { logger.notice("\(message, privacy: .public)") }
}

/// 只对系统明确停止的采集流重建一次；拒绝授权、用户停止和未知错误不能重试。
struct DesktopCaptureRecovery {
    private var available = true
    mutating func sessionChanged() { available = true }
    mutating func consume(_ error: NSError) -> Bool {
        guard available, error.domain == SCStreamErrorDomain else { return false }
        if #available(macOS 15, *), error.code == SCStreamError.systemStoppedStream.rawValue {
            available = false
            return true
        }
        return false
    }
}

/// 只在已授权的共享会话中保持显示器可采集，结束时释放；不修改系统锁屏设置。
@MainActor
final class DesktopDisplayActivity {
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0

    func start() throws {
        if displayAssertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "TaoScreen会话" as CFString, &displayAssertion)
            guard result == kIOReturnSuccess else { throw CloudError("无法保持共享屏幕唤醒（\(result)）。") }
        }
        let result = IOPMAssertionDeclareUserActivity("TaoScreen 远程连接" as CFString,
            kIOPMUserActiveRemote, &activityAssertion)
        guard result == kIOReturnSuccess else {
            stop()
            throw CloudError("无法唤醒共享屏幕（\(result)）。")
        }
    }

    func stop() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion); activityAssertion = 0 }
    }
}
