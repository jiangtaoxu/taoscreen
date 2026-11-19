import CryptoKit
import Foundation
import Network
import Security

struct DesktopDirectCode {
    private static let prefix = "TS1-"
    let fingerprint: Data
    private let secret: Data

    init(fingerprint: Data) {
        self.fingerprint = fingerprint
        secret = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(Self.prefix), value.utf8.count == 68,
              let data = Data(base64Encoded: String(value.dropFirst(Self.prefix.count))
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              data.count == 48 else { return nil }
        fingerprint = Data(data.prefix(32))
        secret = Data(data.suffix(16))
    }

    var text: String {
        Self.prefix + (fingerprint + secret).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    func proof(for id: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: proofInput(id), using: SymmetricKey(data: secret)))
    }

    func verifies(_ proof: Data, for id: UUID) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofInput(id), using: SymmetricKey(data: secret))
    }

    private func proofInput(_ id: UUID) -> Data { Data("taoscreen-direct-v1:\(id.uuidString)".utf8) }
}

/// 每次开启接收时生成仅驻留内存的证书。控制端通过连接码或通道绑定 PAKE 验证这张证书。
struct DesktopDirectIdentity {
    let identity: sec_identity_t
    let code: DesktopDirectCode
    let certificateFingerprint: Data

    init(deviceKey: P256.Signing.PrivateKey? = nil) throws {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary
        let signingKey: SecKey?
        if let deviceKey {
            let keyAttributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                 kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256] as CFDictionary
            signingKey = SecKeyCreateWithData(deviceKey.x963Representation as CFData, keyAttributes, nil)
        } else { signingKey = SecKeyCreateRandomKey(attributes, nil) }
        guard let privateKey = signingKey, let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw Self.failure }

        // X.509 v3 自签名叶证书，EC P-256 公钥，ECDSA / SHA-256 签名。
        let signatureAlgorithm = Self.der(0x30, Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        let publicAlgorithm = Self.der(0x30, Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                                  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]))
        let name = Self.der(0x30, Self.der(0x31, Self.der(0x30, Data([0x06, 0x03, 0x55, 0x04, 0x03])
            + Self.der(0x0c, Data("TaoScreen Direct".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let now = Date()
        let lifetime: TimeInterval = deviceKey == nil ? 86400 : 365 * 86400
        let validity = Self.der(0x30, Self.der(0x18, Data(formatter.string(from: now.addingTimeInterval(-60)).utf8))
            + Self.der(0x18, Data(formatter.string(from: now.addingTimeInterval(lifetime)).utf8)))
        let publicInfo = Self.der(0x30, publicAlgorithm + Self.der(0x03, Data([0]) + publicBytes))
        let serial = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        var serialBytes = serial.drop(while: { $0 == 0 })
        if serialBytes.isEmpty { serialBytes = Data([1])[...] }
        let serialNumber = Self.der(0x02, ((serialBytes.first ?? 0) >= 128 ? Data([0]) : Data()) + serialBytes)
        let certificateBody = Self.der(0x30, Data([0xa0, 0x03, 0x02, 0x01, 0x02]) + serialNumber
            + signatureAlgorithm + name + validity + name + publicInfo)
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, certificateBody as CFData, nil) as Data? else {
            throw Self.failure
        }
        let bytes = Self.der(0x30, certificateBody + signatureAlgorithm + Self.der(0x03, Data([0]) + signature))
        guard let cert = SecCertificateCreateWithData(nil, bytes as CFData),
              let localIdentity = SecIdentityCreate(nil, cert, privateKey), let identity = sec_identity_create(localIdentity) else {
            throw Self.failure
        }
        self.identity = identity
        let fingerprint = Data(SHA256.hash(data: bytes))
        self.certificateFingerprint = fingerprint
        code = DesktopDirectCode(fingerprint: fingerprint)
    }

    private static var failure: CloudError { CloudError("无法创建本次直连的加密身份，请重试。") }

    private static func der(_ tag: UInt8, _ contents: Data) -> Data {
        if contents.count < 128 { return Data([tag, UInt8(contents.count)]) + contents }
        if contents.count < 256 { return Data([tag, 0x81, UInt8(contents.count)]) + contents }
        return Data([tag, 0x82, UInt8(contents.count >> 8), UInt8(truncatingIfNeeded: contents.count)]) + contents
    }

    static func parameters(identity: sec_identity_t? = nil, fingerprint: Data? = nil) -> NWParameters {
        parameters(identity: identity, verified: fingerprint.map { fingerprint in
            { cert in Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data)) == fingerprint }
        })
    }

    static func trustedParameters(identity: sec_identity_t, permits: @escaping (Data) -> Bool) -> NWParameters {
        parameters(identity: identity, requiresClientIdentity: true, verified: { certificate in
            guard let key = publicKey(of: certificate) else { return false }
            return permits(key)
        })
    }

    /// 供通道绑定 PAKE 使用：TLS 层接受对端叶子证书，身份真伪由后续 PAKE 绑定该证书 SHA-256 指纹验证。
    static func unpinnedParameters() -> NWParameters {
        parameters(identity: nil, requiresClientIdentity: false, verified: { _ in true })
    }

    static func peerCertificateFingerprint(_ connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var fingerprint: Data?
        sec_protocol_metadata_access_peer_certificate_chain(tls.securityProtocolMetadata) { certificate in
            if fingerprint == nil {
                let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
                fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(ref) as Data))
            }
        }
        return fingerprint
    }

    static func peerPublicKey(_ connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var key: Data?
        sec_protocol_metadata_access_peer_certificate_chain(tls.securityProtocolMetadata) { certificate in
            if key == nil { key = publicKey(of: sec_certificate_copy_ref(certificate).takeRetainedValue()) }
        }
        return key
    }

    private static func publicKey(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    private static func parameters(identity: sec_identity_t?, requiresClientIdentity: Bool = false,
                                   verified: ((SecCertificate) -> Bool)?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        if let identity { sec_protocol_options_set_local_identity(options, identity) }
        if requiresClientIdentity { sec_protocol_options_set_peer_authentication_required(options, true) }
        if let verified {
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate], let leaf = chain.first else {
                    complete(false); return
                }
                complete(verified(leaf))
            }, .main)
        }
        return NWParameters(tls: tls, tcp: .init())
    }
}
