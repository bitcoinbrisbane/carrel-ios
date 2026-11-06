import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import libsecp256k1

// MARK: - Hashes used by the wallet

extension LBRYHash {
    /// RIPEMD160(SHA256(data)): public key hashes and script hashes.
    public static func hash160(_ data: [UInt8]) -> [UInt8] {
        RIPEMD160.hash(sha256(data))
    }

    public static func hmacSHA512(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// PBKDF2-HMAC-SHA512 (RFC 8018), used for BIP39 and LBRY seeds.
    public static func pbkdf2SHA512(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        var block: UInt32 = 1
        while out.count < keyLength {
            let index = [UInt8(block >> 24), UInt8((block >> 16) & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(block & 0xFF)]
            var u = Array(HMAC<SHA512>.authenticationCode(for: salt + index, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA512>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out += t
            block += 1
        }
        return Array(out.prefix(keyLength))
    }

    /// Cryptographically secure random bytes.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
}

// MARK: - secp256k1 (Bitcoin Core's libsecp256k1 via its C API)

public enum Secp256k1Error: Error, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidTweak
    case signingFailed
}

/// Thin wrapper over the libsecp256k1 C API: key creation, BIP32 tweaks, and
/// RFC 6979 deterministic, low-S ECDSA (what LBRY nodes require).
public enum Secp256k1 {

    private final class Context: @unchecked Sendable {
        let pointer: OpaquePointer
        init() {
            // SECP256K1_CONTEXT_NONE == 1
            pointer = secp256k1_context_create(1)!
            var seed = LBRYHash.randomBytes(32)
            _ = secp256k1_context_randomize(pointer, &seed)   // side-channel blinding
        }
    }
    private static let shared = Context()
    private static var ctx: OpaquePointer { shared.pointer }

    private static let compressed: UInt32 = 258   // SECP256K1_EC_COMPRESSED

    public static func isValidPrivateKey(_ key: [UInt8]) -> Bool {
        key.count == 32 && secp256k1_ec_seckey_verify(ctx, key) == 1
    }

    /// 33-byte compressed public key.
    public static func publicKey(privateKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == 32 else { throw Secp256k1Error.invalidPrivateKey }
        var pub = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctx, &pub, privateKey) == 1 else { throw Secp256k1Error.invalidPrivateKey }
        return serialize(&pub)
    }

    /// (key + tweak) mod n. Fails if the tweak is out of range or the result is zero.
    public static func privateKeyTweakAdd(_ key: [UInt8], tweak: [UInt8]) throws -> [UInt8] {
        guard key.count == 32, tweak.count == 32 else { throw Secp256k1Error.invalidTweak }
        var out = key
        guard secp256k1_ec_seckey_tweak_add(ctx, &out, tweak) == 1 else { throw Secp256k1Error.invalidTweak }
        return out
    }

    /// point + tweak·G, compressed.
    public static func publicKeyTweakAdd(_ key: [UInt8], tweak: [UInt8]) throws -> [UInt8] {
        guard tweak.count == 32 else { throw Secp256k1Error.invalidTweak }
        var pub = try parse(key)
        guard secp256k1_ec_pubkey_tweak_add(ctx, &pub, tweak) == 1 else { throw Secp256k1Error.invalidTweak }
        return serialize(&pub)
    }

    /// DER-encoded, low-S ECDSA signature over a 32-byte digest (RFC 6979 nonce).
    public static func sign(digest: [UInt8], privateKey: [UInt8]) throws -> [UInt8] {
        guard digest.count == 32 else { throw Secp256k1Error.signingFailed }
        guard isValidPrivateKey(privateKey) else { throw Secp256k1Error.invalidPrivateKey }
        var sig = secp256k1_ecdsa_signature()
        guard secp256k1_ecdsa_sign(ctx, &sig, digest, privateKey, nil, nil) == 1 else { throw Secp256k1Error.signingFailed }
        var der = [UInt8](repeating: 0, count: 72)
        var length = der.count
        guard secp256k1_ecdsa_signature_serialize_der(ctx, &der, &length, &sig) == 1 else { throw Secp256k1Error.signingFailed }
        return Array(der.prefix(length))
    }

    /// Verifies a DER signature; rejects high-S signatures like the network does.
    public static func verify(signature der: [UInt8], digest: [UInt8], publicKey: [UInt8]) -> Bool {
        guard digest.count == 32, var pub = try? parse(publicKey) else { return false }
        var sig = secp256k1_ecdsa_signature()
        guard secp256k1_ecdsa_signature_parse_der(ctx, &sig, der, der.count) == 1 else { return false }
        return secp256k1_ecdsa_verify(ctx, &sig, digest, &pub) == 1
    }

    /// 65-byte uncompressed public key (0x04 ‖ X ‖ Y), as Ethereum addresses need.
    public static func uncompressedPublicKey(privateKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == 32 else { throw Secp256k1Error.invalidPrivateKey }
        var pub = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctx, &pub, privateKey) == 1 else { throw Secp256k1Error.invalidPrivateKey }
        return serialize(&pub, flags: uncompressed)
    }

    /// Recovers the uncompressed public key that made a 65-byte `r ‖ s ‖ v` signature
    /// (v = 27/28 or 0/1) over a 32-byte digest. Used to check signed Ethereum messages.
    public static func recoverPublicKey(signature: [UInt8], digest: [UInt8]) -> [UInt8]? {
        guard signature.count == 65, digest.count == 32 else { return nil }
        var v = Int32(signature[64])
        if v >= 27 { v -= 27 }
        guard v == 0 || v == 1 else { return nil }
        var sig = secp256k1_ecdsa_recoverable_signature()
        let compact = Array(signature[0..<64])
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &sig, compact, v) == 1 else { return nil }
        var pub = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(ctx, &pub, &sig, digest) == 1 else { return nil }
        return serialize(&pub, flags: uncompressed)
    }

    /// Recoverable ECDSA signature for Ethereum: (r, s, recovery id 0/1). Low-S,
    /// RFC 6979 nonce, so the same key and digest always give the same signature.
    public static func signRecoverable(digest: [UInt8], privateKey: [UInt8]) throws -> (r: [UInt8], s: [UInt8], recid: Int32) {
        guard digest.count == 32 else { throw Secp256k1Error.signingFailed }
        guard isValidPrivateKey(privateKey) else { throw Secp256k1Error.invalidPrivateKey }
        var sig = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(ctx, &sig, digest, privateKey, nil, nil) == 1 else {
            throw Secp256k1Error.signingFailed
        }
        var compact = [UInt8](repeating: 0, count: 64)
        var recid: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &compact, &recid, &sig) == 1 else {
            throw Secp256k1Error.signingFailed
        }
        return (Array(compact[0..<32]), Array(compact[32..<64]), recid)
    }

    private static let uncompressed: UInt32 = 2   // SECP256K1_EC_UNCOMPRESSED

    private static func parse(_ key: [UInt8]) throws -> secp256k1_pubkey {
        var pub = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_parse(ctx, &pub, key, key.count) == 1 else { throw Secp256k1Error.invalidPublicKey }
        return pub
    }

    private static func serialize(_ pub: inout secp256k1_pubkey, flags: UInt32 = 258) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: flags == 2 ? 65 : 33)
        var length = out.count
        _ = secp256k1_ec_pubkey_serialize(ctx, &out, &length, &pub, flags)
        return Array(out.prefix(length))
    }
}

// MARK: - Base58Check

public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let indexes: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    public static func encode(_ bytes: [UInt8]) -> String {
        let zeros = bytes.prefix { $0 == 0 }.count
        var digits: [UInt8] = []   // base-58 digits, least significant first
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let out = [UInt8](repeating: alphabet[0], count: zeros) + digits.reversed().map { alphabet[Int($0)] }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        let zeros = chars.prefix { $0 == alphabet[0] }.count
        var bytes: [UInt8] = []   // least significant first
        for c in chars {
            guard var carry = indexes[c] else { return nil }
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }

    public static func encodeCheck(_ payload: [UInt8]) -> String {
        encode(payload + LBRYHash.sha256d(payload).prefix(4))
    }

    public static func decodeCheck(_ string: String) -> [UInt8]? {
        guard let raw = decode(string), raw.count >= 4 else { return nil }
        let payload = Array(raw.dropLast(4))
        guard Array(LBRYHash.sha256d(payload).prefix(4)) == Array(raw.suffix(4)) else { return nil }
        return payload
    }
}
