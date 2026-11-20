import AppKit
import Foundation
import Darwin

enum DesktopShortcutDestination: String, Codable, CaseIterable {
    case local, remote
    var title: String { self == .local ? L10n.text("控制端（此电脑）") : L10n.text("被控电脑") }

    func forwards(_ flags: NSEvent.ModifierFlags) -> Bool {
        self == .remote || flags.intersection([.command, .control]).isEmpty
    }
}

/// 连接质量只按当前链路的实际 RTT 分档，不将它描述为 Wi-Fi 信号强度。
enum DesktopConnectionQuality: String {
    case unknown = "测量中", good = "良好", fair = "一般", poor = "较差"
    var title: String { L10n.value(rawValue) }
    init(milliseconds: Double?) {
        guard let value = milliseconds, value.isFinite, value >= 0 else { self = .unknown; return }
        self = value < 80 ? .good : value < 200 ? .fair : .poor
    }
    var symbol: String {
        switch self {
        case .unknown: "antenna.radiowaves.left.and.right.slash"
        case .good: "wifi"
        case .fair: "wifi.exclamationmark"
        case .poor: "exclamationmark.triangle"
        }
    }
}

enum DesktopCursorMode: String, Codable, CaseIterable {
    case local, remote

    var title: String { self == .local ? L10n.text("本机优先") : L10n.text("远端原样") }

    func showsRemoteCursor(canControl: Bool, windowActive: Bool) -> Bool {
        self != .local || !canControl || !windowActive
    }
}

/// 控制端本机偏好，按服务器、账号和稳定设备 ID 隔离，不随账号同步。
struct DesktopViewerPreferences: Codable, Equatable {
    var viewerControlEnabled = true
    var shortcutDestination = DesktopShortcutDestination.local
    var clipboardEnabled = true
    var muted = false
    var cursorMode = DesktopCursorMode.local
    // Optional 保持旧版已保存的五项偏好可解码；缺失时默认开启。
    var localInputEnabled: Bool? = nil
    // 缺失即沿用升级前的超清 30 帧，不影响旧偏好的解码。
    var videoPreset: DesktopVideoPreset? = nil
    var lockRemoteOnDisconnect: Bool? = nil

    static func load(accountID: String?, peerID: UUID, defaults: UserDefaults) -> Self {
        if let accountID, let data = defaults.data(forKey: key(accountID, peerID)),
           let preferences = try? JSONDecoder().decode(Self.self, from: data) {
            return preferences
        }
        // 升级前光标是全局偏好；尚未保存过的电脑沿用旧值。
        var preferences = Self()
        preferences.cursorMode = DesktopCursorMode(rawValue: defaults.string(forKey: "taoscreen.desktop.cursorMode") ?? "") ?? .local
        return preferences
    }

    func save(accountID: String, peerID: UUID, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(accountID, peerID))
    }

    private static func key(_ accountID: String, _ peerID: UUID) -> String {
        "taoscreen.desktop.viewer.\(accountID).\(peerID.uuidString)"
    }
}

/// 独立消息类型让旧版忽略光标协商，不会误当作鼠标输入。
struct DesktopCursorMessage: Codable, Equatable {
    enum Action: String, Codable { case request, status }
    var kind = "desktop-cursor.v1"
    var action: Action
    var showsCursor: Bool
    var failed = false
    var isValid: Bool { kind == "desktop-cursor.v1" && (action == .status || !failed) }
}

/// 本机、按服务地址和账号隔离保存；不会同步到其他设备。
struct DesktopUnattendedSettings: Codable, Equatable {
    var enabled = false
    // nil 表示连接时的主屏幕；固定屏幕断开时拒绝连接，不改为共享其他屏幕。
    var displayID: CGDirectDisplayID?
    var control = true
    var audio = false
    // 旧版配置未包含网络访问授权，升级后保持未授权。
    var portForwarding: Bool? = nil
    var virtualDisplayPreset: DesktopVirtualDisplayPreset? = nil

    var shareDisplay: DesktopShareDisplay {
        get {
            if let virtualDisplayPreset { return .virtual(virtualDisplayPreset) }
            if let displayID { return .fixed(displayID) }
            return .main
        }
        set {
            if case let .fixed(id) = newValue { displayID = id } else { displayID = nil }
            virtualDisplayPreset = newValue.virtualPreset
        }
    }

    static func load(accountID: String?, defaults: UserDefaults) -> Self {
        guard let accountID, let data = defaults.data(forKey: key(accountID)),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(accountID: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    private static func key(_ accountID: String) -> String { "taoscreen.desktop.unattended.\(accountID)" }
}

enum DesktopLatency {
    /// 只读取当前 transport 选中的 ICE pair，避免显示已弃用链路的延迟。
    static func milliseconds(statistics: [String: (type: String, values: [String: NSObject])]) -> Double? {
        for transport in statistics.values where transport.type == "transport" {
            guard let id = transport.values["selectedCandidatePairId"] as? String,
                  let pair = statistics[id], pair.type == "candidate-pair",
                  let seconds = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue,
                  seconds.isFinite, seconds >= 0, (seconds * 1000).isFinite else { continue }
            return seconds * 1000
        }
        return nil
    }
}

/// 只显示 transport 当前选中链路两端的 IP；不从未选中候选或本机其他网卡猜测。
struct DesktopConnectionAddresses: Equatable {
    struct Endpoint: Equatable {
        let ip: String
        let relayed: Bool
        var description: String { ip + (relayed ? L10n.text("（中继）") : "") }
    }
    var local: Endpoint?
    var remote: Endpoint?

    static func selected(statistics: [String: (type: String, values: [String: NSObject])]) -> Self {
        let pairIDs = Set(statistics.values.filter { $0.type == "transport" }
            .compactMap { $0.values["selectedCandidatePairId"] as? String })
        guard pairIDs.count == 1, let pairID = pairIDs.first,
              let pair = statistics[pairID], pair.type == "candidate-pair" else { return Self() }
        func endpoint(_ key: String, type: String) -> Endpoint? {
            guard let id = pair.values[key] as? String, let candidate = statistics[id], candidate.type == type,
                  let address = candidate.values["address"] as? String,
                  let candidateType = candidate.values["candidateType"] as? String,
                  ["host", "srflx", "prflx", "relay"].contains(candidateType) else { return nil }
            var ipv4 = in_addr(), ipv6 = in6_addr()
            guard inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else { return nil }
            return Endpoint(ip: address, relayed: candidateType == "relay")
        }
        return Self(local: endpoint("localCandidateId", type: "local-candidate"),
                    remote: endpoint("remoteCandidateId", type: "remote-candidate"))
    }
}

struct DesktopPeer: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
}
struct DesktopConfiguration: Decodable {
    struct Server: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?
    }
    let iceServers: [Server]
    let relayAvailable: Bool
    enum CodingKeys: String, CodingKey { case iceServers = "ice_servers", relayAvailable = "relay_available" }
}
struct DesktopSignal: Codable {
    var type: String
    var id: UUID?
    var to: UUID?
    var from: UUID?
    var payload: Payload?
    struct Payload: Codable {
        var sdp: String?
        var candidate: String?
        var mid: String?
        var line: Int32?
        var control: Bool?
        var audio: Bool?
        var files: Bool?
        var message: String?
        var code: String?
        var resume: Bool?
        var keepalive: Bool?
        var independent: Bool?
        var paired: Bool?
        var resumeToken: UUID?
        enum CodingKeys: String, CodingKey {
            case sdp, candidate, mid, line, control, audio, files, message, code, resume, keepalive, independent, paired
            case resumeToken = "resume_token"
        }
    }
}
struct DesktopInvitation: Identifiable {
    let id: UUID
    let peer: DesktopPeer
}
struct DesktopInput: Codable {
    var kind: String
    var x: Double?
    var y: Double?
    var button: Int?
    var down: Bool?
    var key: UInt16?
    var flags: UInt64?
    var dx: Double?
    var dy: Double?
    var text: String?
    var clicks: Int?
    var transient: Bool?

    /// 与旧版兼容：有序通道上先释放修饰键，再写入文字并执行粘贴，不发送回车。
    static func textPaste(_ text: String, transient: Bool = false) throws -> [Self] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count <= 16 * 1024 else { throw CloudError(L10n.text("输入文本超过 16 KB，请缩短后重试。")) }
        let clipboard = Self(kind: "clipboard", text: text, transient: transient ? true : nil)
        guard try JSONEncoder().encode(clipboard).count <= 32 * 1024 else {
            throw CloudError(L10n.text("输入文本编码后过大，请缩短后重试。"))
        }
        return [.init(kind: "release"), clipboard,
                .init(kind: "key", down: true, key: 9, flags: CGEventFlags.maskCommand.rawValue),
                .init(kind: "key", down: false, key: 9, flags: CGEventFlags.maskCommand.rawValue)]
    }

    var isValid: Bool {
        switch kind {
        case "move", "button":
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return false }
            return kind == "move" || ((0...2).contains(button ?? -1) && down != nil && (0...3).contains(clicks ?? 1))
        case "scroll": return dx?.isFinite == true && dy?.isFinite == true && abs(dx!) <= 1000 && abs(dy!) <= 1000
        case "key": return key.map { $0 < 128 } == true && down != nil
        case "release": return true
        case "clipboard": return text.map { $0.utf8.count <= 16 * 1024 } == true
        default: return false
        }
    }
    static func normalized(_ point: CGPoint, bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width, y: 1 - (point.y - bounds.minY) / bounds.height)
    }
}

@MainActor
final class DesktopInputReceiver {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var enabled = false { didSet { if !enabled { releaseAll(); systemObserver.stop() } } }
    let systemObserver = DesktopInputSystemObserver()
    var onLeftMouseEvent: ((CGEventType) -> Void)?
    private var keys: Set<CGKeyCode> = []
    private struct Press {
        let number: Int64
        let clicks: Int64
    }
    private var buttons: [Int: Press] = [:]
    private var nextMouseEventNumber: Int64 = 0
    private var point = CGPoint.zero
    private let source = CGEventSource(stateID: .privateState)
    private static let keyboardModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]
    private let canPost: () -> Bool
    private let post: (CGEvent) -> Void

    init(canPost: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.canPost = canPost
        self.post = post
    }

    func receive(_ input: DesktopInput) {
        guard input.isValid, enabled else {
            DesktopInputDiagnostics.record("receiver_rejected", input: input, detail: "valid=\(input.isValid) enabled=\(enabled)")
            return
        }
        guard canPost() else {
            DesktopInputDiagnostics.record("permission_denied", input: input)
            return
        }
        let flags = CGEventFlags(rawValue: (input.flags ?? 0) & (CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlphaShift.rawValue))
        if let x = input.x, let y = input.y {
            let bounds = CGDisplayBounds(displayID)
            point = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1), y: bounds.minY + y * max(0, bounds.height - 1))
        }
        var event: CGEvent?
        switch input.kind {
        case "move":
            let button = (0...2).first { buttons[$0] != nil }
            let type: CGEventType = button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : button == 2 ? .otherMouseDragged : .mouseMoved
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                            mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0))!)
            if let button, let press = buttons[button] {
                event?.setIntegerValueField(.mouseEventNumber, value: press.number)
                event?.setIntegerValueField(.mouseEventClickState, value: press.clicks)
                event?.setDoubleValueField(.mouseEventPressure, value: 1)
            }
        case "button":
            event = buttonEvent(button: input.button!, down: input.down!, clicks: input.clicks ?? 1)
        case "key":
            let key = input.key!
            if input.down! { keys.insert(key) } else { keys.remove(key) }
            event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: input.down!)
        case "scroll": event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(input.dy!), wheel2: Int32(input.dx!), wheel3: 0)
        case "clipboard": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(input.text!, forType: .string)
        case "release": releaseAll()
        default: break
        }
        if let event {
            if input.kind == "key" {
                // CGEvent 根据键码生成 Fn、方向键/数字区及左右修饰键标志。
                // 这些属于按键自身，不能被远端传来的组合键状态覆盖。
                event.flags = event.flags.subtracting(Self.keyboardModifiers).union(flags)
            } else { event.flags = flags }
        }
        if let event {
            postEvent(event)
            // CGEventPost 不返回投递结果；submitted 只表示调用完成，不表示目标应用已响应。
            DesktopInputDiagnostics.record("submitted", input: input,
                detail: "type=\(event.type.rawValue) number=\(event.getIntegerValueField(.mouseEventNumber)) timestamp=\(event.timestamp)")
        } else {
            DesktopInputDiagnostics.record("no_event", input: input)
        }
    }

    private func postEvent(_ event: CGEvent) {
        // Newly created CGEvents can have timestamp == 0. Supply the local
        // monotonic time in nanoseconds before posting, including releases;
        // a valid click pair also needs timestamps that AppKit can track.
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        systemObserver.prepare(event)
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            onLeftMouseEvent?(event.type)
        }
        post(event)
    }

    private func buttonEvent(button: Int, down: Bool, clicks: Int) -> CGEvent? {
        let press: Press
        if down {
            nextMouseEventNumber += 1
            press = Press(number: nextMouseEventNumber, clicks: Int64(max(1, min(3, clicks))))
        } else {
            // An activation click or a cancelled drag may have no matching down.
            guard let held = buttons[button] else { return nil }
            press = held
        }
        let type: CGEventType = button == 0 ? (down ? .leftMouseDown : .leftMouseUp)
            : button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button))!) else { return nil }
        // AppKit pairs a press and release by event number. Preserve the down's
        // click count, including when the sender reports zero on mouse-up.
        event.setIntegerValueField(.mouseEventNumber, value: press.number)
        event.setIntegerValueField(.mouseEventClickState, value: press.clicks)
        event.setDoubleValueField(.mouseEventPressure, value: down ? 1 : 0)
        if down { buttons[button] = press } else { buttons.removeValue(forKey: button) }
        return event
    }

    func releaseAll() {
        for key in keys {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
                event.flags.subtract(Self.keyboardModifiers); postEvent(event)
            }
        }
        for button in Array(buttons.keys) {
            if let event = buttonEvent(button: button, down: false, clicks: 1) {
                event.flags = []; postEvent(event)
            }
        }
        keys.removeAll(); buttons.removeAll()
    }
}
