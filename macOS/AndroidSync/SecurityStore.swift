import Foundation
import Security
import CryptoKit

struct StoreError: LocalizedError {
    var detail: String
    var errorDescription: String? { detail }
}
enum Vault {
    static var service = "dev.androidsync.mac"
    static func get(_ name: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(detail: "Keychain unavailable (\(status)).") }
        return result as? Data
    }
    static func put(_ name: String, _ data: Data) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary
        let status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            let add = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
            guard add == errSecSuccess else { throw StoreError(detail: "Could not save credentials (\(add)).") }; return
        }
        guard status == errSecSuccess else { throw StoreError(detail: "Could not save credentials (\(status)).") }
    }
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw StoreError(detail: "Secure random generator unavailable.") }; return data
    }
    static func encryptionKey() throws -> SymmetricKey {
        if let data = try get("history-key") { return SymmetricKey(data: data) }
        let data = try random(32); try put("history-key", data); return SymmetricKey(data: data)
    }
}
// A minimal DER encoder for an ECDSA P-256 self-signed certificate. The private key never leaves Keychain.
enum DER {
    static func node(_ tag: UInt8, _ value: Data) -> Data {
        let length: Data
        if value.count < 128 { length = Data([UInt8(value.count)]) }
        else { var n = value.count; var bytes: [UInt8] = []; while n > 0 { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 }; length = Data([0x80 | UInt8(bytes.count)] + bytes) }
        return Data([tag]) + length + value
    }
    static func seq(_ items: Data...) -> Data { node(0x30, items.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { node(0x06, Data(bytes)) }
    static let algorithm = seq(oid([0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]))
    static func name(_ value: String) -> Data { seq(node(0x31, seq(oid([0x55,0x04,0x03]), node(0x0c, Data(value.utf8))))) }
    static func time(_ date: Date) -> Data {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyyMMddHHmmss'Z'"
        return node(0x18, Data(format.string(from: date).utf8))
    }
}
struct MacIdentity {
    let id: String
    let certificate: SecCertificate
    let identity: SecIdentity
    var fingerprint: String { SyncRules.hex(Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))) }
    init() throws {
        if let saved = try Vault.get("mac-id"), let value = String(data: saved, encoding: .utf8) { id = value }
        else { id = UUID().uuidString; try Vault.put("mac-id", Data(id.utf8)) }
        let tag = Data("\(Vault.service).tls.v2.key".utf8)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef: true] as CFDictionary, &item)
        let key: SecKey
        if status == errSecSuccess { key = item as! SecKey }
        else {
            var error: Unmanaged<CFError>?
            guard let generated = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]] as CFDictionary, &error) else { throw StoreError(detail: "Could not create TLS identity.") }
            key = generated
        }
        if let saved = try Vault.get("tls-cert-v2"), let cert = SecCertificateCreateWithData(nil, saved as CFData) { certificate = cert }
        else {
            var error: Unmanaged<CFError>?
            let pub = SecKeyCopyPublicKey(key)!
            guard let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw StoreError(detail: "Could not read public identity.") }
            let spki = DER.seq(DER.seq(DER.oid([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]), DER.oid([0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])), DER.node(0x03, Data([0]) + raw))
            let name = DER.name("Android Sync \(id)")
            var serialBytes = try Vault.random(16)
            while serialBytes.count > 1 && serialBytes.first == 0 { serialBytes.removeFirst() }
            if serialBytes.first! & 0x80 != 0 { serialBytes.insert(0, at: 0) }
            let serial = DER.node(0x02, serialBytes)
            let tbs = DER.seq(DER.node(0xa0, DER.node(0x02, Data([2]))), serial, DER.algorithm, name, DER.seq(DER.time(Date().addingTimeInterval(-86400)), DER.time(Date().addingTimeInterval(10 * 365 * 86400))), name, spki)
            guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else { throw StoreError(detail: "Could not sign TLS certificate.") }
            let data = DER.seq(tbs, DER.algorithm, DER.node(0x03, Data([0]) + sig))
            guard let cert = SecCertificateCreateWithData(nil, data as CFData) else { throw StoreError(detail: "Invalid TLS certificate.") }
            certificate = cert; try Vault.put("tls-cert-v2", data)
        }
        let added = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw StoreError(detail: "Could not install local identity (\(added)).") }
        var result: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &result) == errSecSuccess, let result else { throw StoreError(detail: "TLS identity unavailable.") }
        identity = result
    }
    static func verify(publicKey: String, signature: String, message: Data) -> Bool {
        guard let x509 = Data(base64Encoded: publicKey), x509.count == 91,
              let raw = x509.suffix(65).first, raw == 4, let sig = Data(base64Encoded: signature) else { return false }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(x509.suffix(65)) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 256] as CFDictionary, &error) else { return false }
        return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, sig as CFData, &error)
    }
}
