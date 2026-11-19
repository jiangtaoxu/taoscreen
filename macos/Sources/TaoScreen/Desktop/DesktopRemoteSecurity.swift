import AppKit
import CryptoKit
import LocalAuthentication
import Security

struct DesktopRemotePasswordScope: Equatable {
    let accountID: String
    let peerID: UUID
    var key: String { CloudCoding.sha(Data((accountID + "\n" + peerID.uuidString.lowercased()).utf8)) }
}

struct DesktopRemotePasswordStore {
    var read: (DesktopRemotePasswordScope) async throws -> String?
    var contains: (DesktopRemotePasswordScope) throws -> Bool
    var save: (DesktopRemotePasswordScope, String) throws -> Void
    var delete: (DesktopRemotePasswordScope) throws -> Void
    static let keychain = Self(read: DesktopRemotePasswordKeychain.read, contains: DesktopRemotePasswordKeychain.contains,
                               save: DesktopRemotePasswordKeychain.save, delete: DesktopRemotePasswordKeychain.delete)
}

/// 远程密码由系统验证保护，并按账号和被控设备存放在本机。
enum DesktopRemotePasswordKeychain {
    private static let legacyService = DesktopRuntime.keychainService("remote-login.local")
    private static let service = DesktopRuntime.keychainService("remote-login.verified")
    private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    private struct SealedPassword: Codable {
        let enclaveKey: Data
        let encapsulatedKey: Data
        let ciphertext: Data
    }

    static func query(_ scope: DesktopRemotePasswordScope) -> [String: Any] {
        var query = item(scope, service: service)
        if !SecureEnclave.isAvailable { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func item(_ scope: DesktopRemotePasswordScope, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: scope.key, kSecAttrSynchronizable as String: false]
    }

    private static func accessControl(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil)
        else { throw CloudError("无法设置远程登录密码的本机验证。") }
        return control
    }

    static func read(_ scope: DesktopRemotePasswordScope) async throws -> String? {
        let context = LAContext()
        context.localizedReason = "验证身份以使用已保存的远程登录密码。"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return try await withTaskCancellationHandler {
            defer { context.invalidate() }
            let password = try await Task.detached { try read(scope, context: context) }.value
            try Task.checkCancellation()
            return password
        } onCancel: {
            context.invalidate()
        }
    }

    static func read(_ scope: DesktopRemotePasswordScope, context: LAContext) throws -> String? {
        var query = query(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled { throw CancellationError() }
        guard status == errSecSuccess, let stored = item as? Data else { throw failure(status, action: "读取") }
        let data: Data
        if SecureEnclave.isAvailable {
            do {
                let protected = try PropertyListDecoder().decode(SealedPassword.self, from: stored)
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: protected.enclaveKey, authenticationContext: context)
                var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: Data(scope.key.utf8),
                                                   encapsulatedKey: protected.encapsulatedKey)
                data = try recipient.open(protected.ciphertext)
            } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
                throw CancellationError()
            } catch {
                throw CloudError("本机验证未完成，或已保存的密码无法解密。请重试或重新保存。")
            }
        } else {
            data = stored
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw CloudError("本机保存的密码格式无效，请重新保存。")
        }
        return password
    }

    static func contains(_ scope: DesktopRemotePasswordScope) throws -> Bool {
        var query = query(scope)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess || status == errSecInteractionNotAllowed else {
            throw failure(status, action: "检查")
        }
        return true
    }

    static func save(_ scope: DesktopRemotePasswordScope, _ password: String) throws {
        guard DesktopRemoteSecurityMessage.validPassword(password) else {
            throw CloudError("密码不能为空、超过 1024 字节或包含换行、制表等控制字符。")
        }
        let query = query(scope)
        let plain = Data(password.utf8)
        var attributes: [String: Any] = [:]
        let stored: Data
        if SecureEnclave.isAvailable {
            // 用不可导出的、每次使用都要求用户在场的硬件私钥保护密文。
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl([.userPresence, .privateKeyUsage]))
            var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: suite, info: Data(scope.key.utf8))
            let ciphertext = try sender.seal(plain)
            stored = try PropertyListEncoder().encode(SealedPassword(enclaveKey: key.dataRepresentation,
                                                                      encapsulatedKey: sender.encapsulatedKey,
                                                                      ciphertext: ciphertext))
        } else {
            attributes[kSecAttrAccessControl as String] = try accessControl(.userPresence)
            stored = plain
        }
        attributes[kSecValueData as String] = stored
        var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: stored] as CFDictionary)
        }
        guard status == errSecSuccess else { throw failure(status, action: "保存") }
        try remove(item(scope, service: legacyService))
    }

    static func delete(_ scope: DesktopRemotePasswordScope) throws {
        try remove(item(scope, service: legacyService))
        try remove(query(scope))
    }

    private static func remove(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, action: "删除") }
    }

    private static func failure(_ status: OSStatus, action: String) -> CloudError {
        if status == errSecMissingEntitlement {
            return CloudError("此构建缺少受保护钥匙串权限。请使用已配置钥匙串权限的签名版本，或在远端手动输入密码。")
        }
        return CloudError("无法\(action)本机受保护的远程密码（\(status)）。")
    }
}

struct DesktopRemoteSecurityMessage: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable { case configure, status, unlock, unlockResult }
    enum Failure: String, Codable {
        case permission, notLocked, inputUnavailable, repeated, limit
        var message: String {
            switch self {
            case .permission: "当前连接没有鼠标键盘控制授权。"
            case .notLocked: "远端不再处于可解锁的已登录锁屏会话，未输入密码。"
            case .inputUnavailable: "远端未能提交密码，请检查录入权限并聚焦远端密码框。"
            case .repeated: "此解锁请求已处理，不会重复输入密码。"
            case .limit: "本次连接解锁尝试过于频繁，请稍后重试。"
            }
        }
    }
    var kind = "desktop-security.v1"
    let action: Action
    var requestID: UUID? = nil
    var lockOnDisconnect: Bool? = nil
    var password: String? = nil
    var submitted: Bool? = nil
    var failure: Failure? = nil
    var description: String { "DesktopRemoteSecurityMessage(action: \(action.rawValue), requestID: \(requestID?.uuidString ?? "none"))" }
    var debugDescription: String { description }
    static func validPassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains {
            $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
        }
    }
    var isValid: Bool {
        guard kind == "desktop-security.v1" else { return false }
        switch action {
        case .configure: return requestID != nil && lockOnDisconnect != nil && password == nil && submitted == nil && failure == nil
        case .status: return lockOnDisconnect != nil && password == nil && submitted == nil && (failure == nil || requestID != nil)
        case .unlock: return requestID != nil && password.map(Self.validPassword) == true && lockOnDisconnect == nil && submitted == nil && failure == nil
        case .unlockResult: return requestID != nil && password == nil && lockOnDisconnect == nil && submitted != nil && (submitted == true ? failure == nil : failure != nil)
        }
    }
}

/// 被控端只记住本次已授权连接的策略与请求 ID，不保存密码。
struct DesktopRemoteSecurityHost {
    private(set) var lockOnDisconnect = false
    private var unlockRequests = Set<UUID>()
    private var nextUnlock: TimeInterval = 0
    mutating func configure(_ value: Bool, authorized: Bool) -> Bool {
        guard authorized else { return false }
        lockOnDisconnect = value
        return true
    }
    mutating func authorizeUnlock(_ id: UUID, authorized: Bool, locked: Bool, now: TimeInterval) -> DesktopRemoteSecurityMessage.Failure? {
        guard authorized else { return .permission }
        guard locked else { return .notLocked }
        guard !unlockRequests.contains(id) else { return .repeated }
        guard unlockRequests.count < 64, now >= nextUnlock else { return .limit }
        unlockRequests.insert(id); nextUnlock = now + 5
        return nil
    }
    mutating func end(established: Bool, authorized: Bool, localSession: DesktopLocalSession) -> Bool {
        let lock = lockOnDisconnect && established && authorized && localSession.canHost && !localSession.locked
        self = Self()
        return lock
    }
}

struct DesktopRemoteSecurityViewer {
    var preference = false
    private(set) var supported = false
    private(set) var confirmedLock: Bool?
    private(set) var lockRequest: DesktopRemoteSecurityMessage?
    private(set) var lockTimedOut = false
    private(set) var lockFailure: String?
    private(set) var retryLock: Bool?
    private(set) var unlockRequest: UUID?
    private(set) var unlockMessage: String?
    private var receivedInitialStatus = false
    var lockChanging: Bool { lockRequest != nil && !lockTimedOut }
    var selectedLock: Bool { lockRequest?.lockOnDisconnect ?? preference }
    var lockStatus: String {
        if !supported { return "对方尚未声明支持断连锁屏与一键解锁，请确认两端已升级。" }
        if let lockFailure { return lockFailure }
        if lockChanging { return "正在等待被控电脑确认…" }
        return confirmedLock == true ? "被控电脑已确认：连接结束后自动锁屏。" : "当前连接结束后不自动锁屏。"
    }
    mutating func configure(_ enabled: Bool) -> DesktopRemoteSecurityMessage? {
        guard supported, !lockChanging else { return nil }
        let message = DesktopRemoteSecurityMessage(action: .configure, requestID: UUID(), lockOnDisconnect: enabled)
        lockRequest = message; lockTimedOut = false; lockFailure = nil; retryLock = enabled
        return message
    }
    mutating func receive(_ message: DesktopRemoteSecurityMessage) -> DesktopRemoteSecurityMessage? {
        guard message.isValid else { return nil }
        if message.action == .status {
            if let id = message.requestID {
                guard lockRequest?.requestID == id else { return nil }
                confirmedLock = message.lockOnDisconnect
                lockRequest = nil; lockTimedOut = false
                if let failure = message.failure { lockFailure = failure.message }
                else { preference = message.lockOnDisconnect == true; lockFailure = nil; retryLock = nil }
            } else {
                supported = true; confirmedLock = message.lockOnDisconnect
                if !receivedInitialStatus {
                    receivedInitialStatus = true
                    if preference != (message.lockOnDisconnect == true) { return configure(preference) }
                }
            }
        } else if message.action == .unlockResult, message.requestID == unlockRequest {
            if message.submitted == true { unlockMessage = "密码已提交，等待远端确认解锁…" }
            else { unlockRequest = nil; unlockMessage = message.failure?.message }
        }
        return nil
    }
    mutating func expireLock(_ id: UUID) {
        guard lockRequest?.requestID == id else { return }
        lockTimedOut = true; confirmedLock = nil
        lockFailure = "未收到被控电脑确认，断连锁屏状态未确认；可重新确认。"
    }
    mutating func lockSendFailed(_ id: UUID) {
        guard lockRequest?.requestID == id else { return }
        lockRequest = nil; lockTimedOut = false
        lockFailure = "设置未能通过加密控制通道发送，尚未更改被控电脑的策略。"
    }
    mutating func beginUnlock() -> UUID? {
        guard supported, unlockRequest == nil else { return nil }
        let id = UUID(); unlockRequest = id; unlockMessage = "正在向锁屏中的电脑提交密码…"
        return id
    }
    mutating func expireUnlock(_ id: UUID) {
        guard unlockRequest == id else { return }
        unlockRequest = nil; unlockMessage = "未确认远端已解锁，请检查密码和远端密码框；不会自动重试。"
    }
    mutating func confirmUnlocked() {
        guard unlockRequest != nil else { return }
        unlockRequest = nil; unlockMessage = "远端已确认解锁。"
    }
    mutating func unlockFailed(_ message: String) { unlockRequest = nil; unlockMessage = message }
}

/// 只使用已获授权的 CGEvent 键盘路径；密码不用剪贴板，不进入按键诊断和日志。
@MainActor final class DesktopSecurityInput {
    private let canPost: () -> Bool
    private let session: () -> DesktopLocalSession
    private let post: (CGEvent) -> Void
    init(canPost: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
         session: @escaping () -> DesktopLocalSession = { .current },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.canPost = canPost; self.session = session; self.post = post
    }
    private func pair(_ key: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) throws -> [CGEvent] {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw CloudError("无法生成系统键盘事件。") }
        for event in [down, up] {
            event.flags = flags
            if let text {
                let characters = Array(text.utf16)
                characters.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress) }
            }
        }
        return [down, up]
    }
    private func emit(_ events: [CGEvent]) {
        for event in events { event.timestamp = DispatchTime.now().uptimeNanoseconds; post(event) }
    }
    func submitPassword(_ password: String) throws {
        guard DesktopRemoteSecurityMessage.validPassword(password) else { throw CloudError("远程密码格式无效。") }
        guard canPost() else { throw CloudError("缺少辅助功能或输入事件权限。") }
        guard session().canHost, session().locked else { throw CloudError("远端已离开锁屏会话，未输入密码。") }
        // 用户先在远端选择登录用户和密码框；⌘A 替换该框内容，Unicode 事件不依赖输入法或剪贴板。
        let command = try pair(55)
        command[0].flags = .maskCommand; command[1].flags = []
        let select = [command[0]] + (try pair(0, flags: .maskCommand)) + [command[1]]
        let characters = try password.unicodeScalars.map { try pair(0, text: String($0)) }
        let submit = try pair(36)
        emit(select)
        for events in characters + [submit] {
            guard canPost(), session().canHost, session().locked else { throw CloudError("远端会话或输入权限已改变，已停止输入。") }
            emit(events)
        }
    }
    func lock() throws {
        guard canPost() else { throw CloudError("断连锁屏缺少辅助功能或输入事件权限。") }
        let current = session()
        guard current.canHost else { throw CloudError("当前用户会话不可用，未发送锁屏快捷键。") }
        if current.locked { return }
        let controls = try pair(59), commands = try pair(55)
        // 按下 ⌃、⌘，发送 Q，依次释放；采用 macOS 的标准 ⌃⌘Q 锁屏快捷键。
        controls[0].flags = .maskControl; commands[0].flags = [.maskControl, .maskCommand]
        commands[1].flags = .maskControl; controls[1].flags = []
        emit([controls[0], commands[0]] + (try pair(12, flags: [.maskControl, .maskCommand])) + [commands[1], controls[1]])
    }
}
