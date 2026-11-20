import CommonCrypto
import CryptoKit
import Foundation
import Network

/// macOS 14 兼容的 128 位无符号整数，仅用于 64 位肢体乘法累积。
private struct UInt128Val {
    var hi: UInt64
    var lo: UInt64

    static let zero = UInt128Val(hi: 0, lo: 0)

    init(hi: UInt64 = 0, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    static func mul(_ a: UInt64, _ b: UInt64) -> UInt128Val {
        let product = a.multipliedFullWidth(by: b)
        return UInt128Val(hi: product.high, lo: product.low)
    }

    static func + (lhs: UInt128Val, rhs: UInt128Val) -> UInt128Val {
        let (lo, overflow) = lhs.lo.addingReportingOverflow(rhs.lo)
        let hi = lhs.hi &+ rhs.hi &+ (overflow ? 1 : 0)
        return UInt128Val(hi: hi, lo: lo)
    }

    static func += (lhs: inout UInt128Val, rhs: UInt128Val) {
        lhs = lhs + rhs
    }

    static func += (lhs: inout UInt128Val, rhs: UInt64) {
        let (lo, overflow) = lhs.lo.addingReportingOverflow(rhs)
        lhs.lo = lo
        if overflow { lhs.hi &+= 1 }
    }

    func shiftedRight51() -> UInt64 {
        (hi << 13) | (lo >> 51)
    }

    func low51() -> UInt64 {
        lo & Field25519.mask51
    }
}

/// 有限域 F_{2^255 - 19} 算术与 RFC 9380 Curve25519 Elligator2 映射。
struct Field25519: Equatable {
    fileprivate static let mask51: UInt64 = (1 << 51) - 1
    static let zero = Field25519(0, 0, 0, 0, 0)
    static let one = Field25519(1, 0, 0, 0, 0)
    private static let aMont = Field25519(u64: 486_662)

    private var l0: UInt64
    private var l1: UInt64
    private var l2: UInt64
    private var l3: UInt64
    private var l4: UInt64

    init(_ l0: UInt64, _ l1: UInt64, _ l2: UInt64, _ l3: UInt64, _ l4: UInt64) {
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3; self.l4 = l4
    }

    init(u64 value: UInt64) {
        l0 = value & Self.mask51
        l1 = value >> 51
        l2 = 0; l3 = 0; l4 = 0
    }

    init(littleEndianBytes data: Data) {
        precondition(data.count == 32)
        var bytes = [UInt8](data)
        bytes[31] &= 0x7f
        func load64(_ offset: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
            return v
        }
        l0 = load64(0) & Self.mask51
        l1 = (load64(6) >> 3) & Self.mask51
        l2 = (load64(12) >> 6) & Self.mask51
        l3 = (load64(19) >> 1) & Self.mask51
        l4 = (load64(24) >> 12) & Self.mask51
    }

    private mutating func carry() {
        for _ in 0..<2 {
            l1 += l0 >> 51; l0 &= Self.mask51
            l2 += l1 >> 51; l1 &= Self.mask51
            l3 += l2 >> 51; l2 &= Self.mask51
            l4 += l3 >> 51; l3 &= Self.mask51
            l0 += (l4 >> 51) * 19; l4 &= Self.mask51
        }
        l1 += l0 >> 51; l0 &= Self.mask51
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 {
        var r = Field25519(a.l0 + b.l0, a.l1 + b.l1, a.l2 + b.l2, a.l3 + b.l3, a.l4 + b.l4)
        r.carry()
        return r
    }

    static func - (a: Field25519, b: Field25519) -> Field25519 {
        // 加 4p 保证任意已规约肢体相减不下溢。
        let fourP0: UInt64 = (1 << 53) - 76
        let fourPi: UInt64 = (1 << 53) - 4
        var r = Field25519(
            a.l0 + fourP0 - b.l0,
            a.l1 + fourPi - b.l1,
            a.l2 + fourPi - b.l2,
            a.l3 + fourPi - b.l3,
            a.l4 + fourPi - b.l4
        )
        r.carry()
        return r
    }

    static prefix func - (a: Field25519) -> Field25519 {
        .zero - a
    }

    static func * (a: Field25519, b: Field25519) -> Field25519 {
        let b1_19 = b.l1 * 19
        let b2_19 = b.l2 * 19
        let b3_19 = b.l3 * 19
        let b4_19 = b.l4 * 19

        let t0 = UInt128Val.mul(a.l0, b.l0)
            + UInt128Val.mul(a.l1, b4_19)
            + UInt128Val.mul(a.l2, b3_19)
            + UInt128Val.mul(a.l3, b2_19)
            + UInt128Val.mul(a.l4, b1_19)

        var t1 = UInt128Val.mul(a.l0, b.l1)
            + UInt128Val.mul(a.l1, b.l0)
            + UInt128Val.mul(a.l2, b4_19)
            + UInt128Val.mul(a.l3, b3_19)
            + UInt128Val.mul(a.l4, b2_19)

        var t2 = UInt128Val.mul(a.l0, b.l2)
            + UInt128Val.mul(a.l1, b.l1)
            + UInt128Val.mul(a.l2, b.l0)
            + UInt128Val.mul(a.l3, b4_19)
            + UInt128Val.mul(a.l4, b3_19)

        var t3 = UInt128Val.mul(a.l0, b.l3)
            + UInt128Val.mul(a.l1, b.l2)
            + UInt128Val.mul(a.l2, b.l1)
            + UInt128Val.mul(a.l3, b.l0)
            + UInt128Val.mul(a.l4, b4_19)

        var t4 = UInt128Val.mul(a.l0, b.l4)
            + UInt128Val.mul(a.l1, b.l3)
            + UInt128Val.mul(a.l2, b.l2)
            + UInt128Val.mul(a.l3, b.l1)
            + UInt128Val.mul(a.l4, b.l0)

        let r0Initial = t0.low51(); t1 += t0.shiftedRight51()
        let r1Initial = t1.low51(); t2 += t1.shiftedRight51()
        let r2Initial = t2.low51(); t3 += t2.shiftedRight51()
        let r3Initial = t3.low51(); t4 += t3.shiftedRight51()
        let r4Initial = t4.low51()
        let wrap = t4.shiftedRight51()
        // wrap < 2^57, wrap * 19 < 2^62，可安全在 UInt64 内完成二次进位。
        var r = Field25519(r0Initial + wrap * 19, r1Initial, r2Initial, r3Initial, r4Initial)
        r.carry()
        return r
    }

    func squared() -> Field25519 { self * self }

    func bytes() -> Data {
        var r = self
        r.carry()
        var q = (r.l0 + 19) >> 51
        q = (r.l1 + q) >> 51
        q = (r.l2 + q) >> 51
        q = (r.l3 + q) >> 51
        q = (r.l4 + q) >> 51

        r.l0 += 19 * q
        r.l1 += r.l0 >> 51; r.l0 &= Self.mask51
        r.l2 += r.l1 >> 51; r.l1 &= Self.mask51
        r.l3 += r.l2 >> 51; r.l2 &= Self.mask51
        r.l4 += r.l3 >> 51; r.l3 &= Self.mask51
        r.l4 &= Self.mask51

        // 5 x 51 位拼接为 32 字节小端序。
        let w0 = r.l0 | (r.l1 << 51)
        let w1 = (r.l1 >> 13) | (r.l2 << 38)
        let w2 = (r.l2 >> 26) | (r.l3 << 25)
        let w3 = (r.l3 >> 39) | (r.l4 << 12)
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            func store64(_ offset: Int, _ val: UInt64) {
                for i in 0..<8 { ptr[offset + i] = UInt8(truncatingIfNeeded: val >> (8 * i)) }
            }
            store64(0, w0)
            store64(8, w1)
            store64(16, w2)
            store64(24, w3)
        }
        return out
    }

    /// 恒定时间计算 `self^((p - 1) / 2)`，判断是否为二次剩余。
    func legendreSymbol() -> Field25519 {
        // (p - 1) / 2 = 2^254 - 10: bit 0 = 0, bit 1 = 1, bit 2 = 1, bit 3 = 0, bits 4...253 = 1
        var acc = Field25519.one
        var base = self
        for bit in 0..<254 {
            let isSet = (bit != 0 && bit != 3)
            if isSet { acc = acc * base }
            if bit < 253 { base = base.squared() }
        }
        return acc
    }

    func isSquareOrZero() -> Bool {
        let l = legendreSymbol().bytes()
        let oneBytes = Field25519.one.bytes()
        let zeroBytes = Data(repeating: 0, count: 32)
        return DesktopDirectPAKE.constantTimeEqual(l, oneBytes) || DesktopDirectPAKE.constantTimeEqual(l, zeroBytes)
    }

    func inverted() -> Field25519 {
        // p - 2 = 2^255 - 21: bits 2 and 4 are 0; bits 0, 1, 3, and 5...254 are 1
        var acc = Field25519.one
        var base = self
        for bit in 0..<255 {
            let isSet = (bit != 2 && bit != 4)
            if isSet { acc = acc * base }
            if bit < 254 { base = base.squared() }
        }
        return acc
    }

    /// RFC 9380 Section 6.7.1 Elligator2（Z = 2, A = 486662），跳过 u = 0 保证生成元有效。
    static func mapToCurve25519(_ uniform32: Data) -> Data {
        var r = Field25519(littleEndianBytes: uniform32)
        let zeroBytes = Data(repeating: 0, count: 32)
        for _ in 0..<16 {
            let tv1 = r.squared()
            let denom = Field25519.one + (tv1 + tv1) // 1 + 2 * r^2
            let d = (-aMont) * denom.inverted()
            let gx1 = d.squared() * d + aMont * d.squared() + d
            let u = gx1.isSquareOrZero() ? d : (-aMont - d)
            let encoded = u.bytes()
            if encoded != zeroBytes { return encoded }
            r = r + .one
        }
        return aMont.bytes()
    }
}

/// 绑定宿主 TLS 证书指纹的通道绑定 CPace255 口令认证密钥交换。
struct DesktopDirectPAKE {
    enum AuthMode: String, Codable {
        case temporary
        case unattendedPassword = "unattended_password"
    }

    let mode: AuthMode
    let sessionID: UUID
    let certFingerprint: Data
    let nonce: Data
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let localShare: Data

    init(prs: Data, mode: AuthMode, sessionID: UUID, certFingerprint: Data, nonce: Data) throws {
        guard certFingerprint.count == 32, nonce.count == 16 else {
            throw CloudError(L10n.text("直连加密握手参数无效。"))
        }
        self.mode = mode
        self.sessionID = sessionID
        self.certFingerprint = certFingerprint
        self.nonce = nonce
        let generator = try Self.generator(prs: prs, mode: mode, sessionID: sessionID,
                                            certFingerprint: certFingerprint, nonce: nonce)
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = key
        let share = try key.sharedSecretFromKeyAgreement(with: generator)
        self.localShare = share.withUnsafeBytes { Data($0) }
    }

    static func generator(prs: Data, mode: AuthMode, sessionID: UUID, certFingerprint: Data, nonce: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        var input = Data("taoscreen-cpace255-gen-v1:".utf8)
        input.append(Data(mode.rawValue.utf8))
        input.append(0)
        input.append(Data(sessionID.uuidString.lowercased().utf8))
        input.append(certFingerprint)
        input.append(nonce)
        input.append(prs)
        let digest = Data(SHA512.hash(data: input))
        let uBytes = Field25519.mapToCurve25519(Data(digest.prefix(32)))
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: uBytes)
    }

    func hostConfirm(clientShare: Data, clientConfirm: Data) -> Data? {
        guard clientShare.count == 32, clientConfirm.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientShare),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey) else { return nil }
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let key = deriveISK(hostShare: localShare, clientShare: clientShare, sharedK: sharedBytes)
        guard HMAC<SHA256>.isValidAuthenticationCode(clientConfirm, authenticating: Data("client-confirm".utf8), using: key) else {
            return nil
        }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("host-confirm".utf8), using: key))
    }

    func clientConfirm(hostShare: Data) throws -> (clientConfirm: Data, expectedHostConfirm: Data) {
        guard hostShare.count == 32 else { throw CloudError(L10n.text("对方返回的密钥交换数据无效。")) }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostShare)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let key = deriveISK(hostShare: hostShare, clientShare: localShare, sharedK: sharedBytes)
        let clientTag = Data(HMAC<SHA256>.authenticationCode(for: Data("client-confirm".utf8), using: key))
        let hostTag = Data(HMAC<SHA256>.authenticationCode(for: Data("host-confirm".utf8), using: key))
        return (clientTag, hostTag)
    }

    private func deriveISK(hostShare: Data, clientShare: Data, sharedK: Data) -> SymmetricKey {
        var input = Data("taoscreen-cpace255-isk-v1:".utf8)
        input.append(Data(mode.rawValue.utf8))
        input.append(0)
        input.append(Data(sessionID.uuidString.lowercased().utf8))
        input.append(certFingerprint)
        input.append(nonce)
        input.append(hostShare)
        input.append(clientShare)
        input.append(sharedK)
        return SymmetricKey(data: SHA256.hash(data: input))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= (a ^ b) }
        return diff == 0
    }
}

/// 6 位易读临时连接密码（无 0/O/1/I）。
enum DesktopTemporaryPassword {
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let length = 6

    static func generate() -> String {
        String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    static func format(_ raw: String) -> String {
        let normalized = normalize(raw) ?? raw
        guard normalized.count == 6 else { return raw }
        let split = normalized.index(normalized.startIndex, offsetBy: 3)
        return "\(normalized[..<split]) \(normalized[split...])"
    }

    static func normalize(_ input: String) -> String? {
        let cleaned = input.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar != "-"
        }
        let upper = String(String.UnicodeScalarView(cleaned)).uppercased()
        guard upper.count == length, upper.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return upper
    }

    static func derivePRS(_ normalizedPassword: String, salt: Data) -> Data {
        var data = Data("taoscreen-temp-prs-v1:".utf8)
        data.append(salt)
        data.append(Data(normalizedPassword.utf8))
        return Data(SHA256.hash(data: data))
    }
}

/// 固定密码校验器：本地钥匙串只存 salt + rounds + PBKDF2 派生结果，不存明文密码。
struct DesktopFixedPasswordVerifier: Codable, Equatable {
    static let defaultRounds = 100_000
    let salt: Data
    let rounds: Int
    let derivedKey: Data

    static func create(password: String, rounds: Int = defaultRounds) throws -> Self {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let derived = try deriveKey(password: password, salt: salt, rounds: rounds)
        return Self(salt: salt, rounds: rounds, derivedKey: derived)
    }

    static func deriveKey(password: String, salt: Data, rounds: Int) throws -> Data {
        guard !password.isEmpty, salt.count == 16,
              DesktopDirectPassword.kdfBounds(for: .unattendedPassword).contains(rounds) else {
            throw CloudError(L10n.text("密码校验参数无效。"))
        }
        let passwordData = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordData.withUnsafeBytes { passRaw in
            salt.withUnsafeBytes { saltRaw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passRaw.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw CloudError(L10n.text("无法计算连接密码摘要（\(status)）。")) }
        return Data(derived)
    }
}

enum DesktopDirectPassword {
    static let minFixedLength = 8
    static let maxFixedBytes = 128

    static func validateFixed(_ password: String) -> String? {
        if password.count < minFixedLength {
            return L10n.text("固定访问密码至少需要 \(minFixedLength) 个字符。")
        }
        if password.utf8.count > maxFixedBytes {
            return L10n.text("固定访问密码不能超过 \(maxFixedBytes) 字节。")
        }
        if password.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return L10n.text("固定访问密码不能包含控制字符或换行。")
        }
        return nil
    }

    static func generateStrongFixed() -> String {
        let chars = DesktopTemporaryPassword.alphabet
        let raw = (0..<12).map { _ in chars[Int.random(in: 0..<chars.count)] }
        return "\(String(raw[0..<4]))-\(String(raw[4..<8]))-\(String(raw[8..<12]))"
    }

    static func kdfBounds(for mode: DesktopDirectPAKE.AuthMode) -> ClosedRange<Int> {
        switch mode {
        case .temporary: return 1...1
        case .unattendedPassword: return 10_000...500_000
        }
    }
}

enum DesktopDirectCredential {
    case directURI(endpoint: NWEndpoint, code: DesktopDirectCode)
    case legacyCode(DesktopDirectCode)
    case temporaryPassword(String)
    case fixedPassword(String)
    case invalid

    static func parse(_ input: String) -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        if trimmed.lowercased().hasPrefix("taoscreen-direct://"),
           let components = URLComponents(string: trimmed),
           let host = components.host, !host.isEmpty,
           let fragment = components.fragment,
           let code = DesktopDirectCode(fragment) {
            let portValue = components.port.flatMap(UInt16.init(exactly:)).flatMap(NWEndpoint.Port.init(rawValue:))
                ?? DesktopDirectEndpoint.port
            if portValue.rawValue != 0 {
                let endpoint = DesktopDirectEndpoint.parse(host, defaultPort: portValue)
                if let endpoint {
                    return .directURI(endpoint: endpoint, code: code)
                }
            }
        }
        if let code = DesktopDirectCode(trimmed) {
            return .legacyCode(code)
        }
        if let temp = DesktopTemporaryPassword.normalize(trimmed) {
            return .temporaryPassword(temp)
        }
        if DesktopDirectPassword.validateFixed(trimmed) == nil {
            return .fixedPassword(trimmed)
        }
        return .invalid
    }
}

struct DesktopDirectRateLimiter {
    let maxAttempts: Int
    let lockoutSeconds: TimeInterval
    private var failures = 0
    private var lockedUntil: Date?

    init(maxAttempts: Int = 5, lockoutSeconds: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.lockoutSeconds = lockoutSeconds
    }

    mutating func remainingLockout(now: Date = .now) -> Int? {
        guard let lockedUntil else { return nil }
        let remaining = lockedUntil.timeIntervalSince(now)
        if remaining > 0 {
            return max(1, Int(ceil(remaining)))
        }
        self.lockedUntil = nil
        failures = 0
        return nil
    }

    mutating func recordFailure(now: Date = .now) -> (lockedOut: Bool, remainingAttempts: Int) {
        failures += 1
        if failures >= maxAttempts {
            lockedUntil = now.addingTimeInterval(lockoutSeconds)
            return (true, 0)
        }
        return (false, maxAttempts - failures)
    }

    mutating func recordSuccess() {
        failures = 0
        lockedUntil = nil
    }
}
