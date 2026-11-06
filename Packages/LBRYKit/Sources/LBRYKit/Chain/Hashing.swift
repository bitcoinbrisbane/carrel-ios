import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hash functions used by the LBRY chain.
///
/// Block identity is Bitcoin-style double SHA-256 of the 112-byte header.
/// Proof of work is LBRY's own construction (lbrycrd `PoWHash`):
///
///     h   = SHA512(blockHash)
///     pow = SHA256d(RIPEMD160(h[0..<32]) ‖ RIPEMD160(h[32..<64]))
///
/// All byte arrays here are in internal (little-endian) order; reverse for display hex.
public enum LBRYHash {

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    public static func sha256d(_ data: [UInt8]) -> [UInt8] {
        sha256(sha256(data))
    }

    public static func sha512(_ data: [UInt8]) -> [UInt8] {
        Array(SHA512.hash(data: data))
    }

    /// LBRY proof-of-work hash of a block hash (internal byte order in, internal byte order out).
    public static func powHash(blockHash: [UInt8]) -> [UInt8] {
        let h = sha512(blockHash)
        return sha256d(RIPEMD160.hash(Array(h[0..<32])) + RIPEMD160.hash(Array(h[32..<64])))
    }
}

/// RIPEMD-160 (not provided by CryptoKit). Straight port of the reference
/// algorithm; checked against known vectors in the test suite.
public enum RIPEMD160 {

    private static let rl: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
    ]
    private static let rr: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
    ]
    private static let sl: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
    ]
    private static let sr: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
    ]
    private static let kl: [UInt32] = [0x0000_0000, 0x5A82_7999, 0x6ED9_EBA1, 0x8F1B_BCDC, 0xA953_FD4E]
    private static let kr: [UInt32] = [0x50A2_8BE6, 0x5C4D_D124, 0x6D70_3EF3, 0x7A6D_76E9, 0x0000_0000]

    @inline(__always) private static func rol(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    @inline(__always) private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16: return x ^ y ^ z
        case 16..<32: return (x & y) | (~x & z)
        case 32..<48: return (x | ~y) ^ z
        case 48..<64: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]

        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        var x = [UInt32](repeating: 0, count: 16)
        for offset in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = offset + i * 4
                x[i] = UInt32(msg[b]) | UInt32(msg[b + 1]) << 8 | UInt32(msg[b + 2]) << 16 | UInt32(msg[b + 3]) << 24
            }

            var (al, bl, cl, dl, el) = (h[0], h[1], h[2], h[3], h[4])
            var (ar, br, cr, dr, er) = (h[0], h[1], h[2], h[3], h[4])

            for j in 0..<80 {
                var t = rol(al &+ f(j, bl, cl, dl) &+ x[rl[j]] &+ kl[j / 16], sl[j]) &+ el
                (al, el, dl, cl, bl) = (el, dl, rol(cl, 10), bl, t)

                t = rol(ar &+ f(79 - j, br, cr, dr) &+ x[rr[j]] &+ kr[j / 16], sr[j]) &+ er
                (ar, er, dr, cr, br) = (er, dr, rol(cr, 10), br, t)
            }

            let t = h[1] &+ cl &+ dr
            h[1] = h[2] &+ dl &+ er
            h[2] = h[3] &+ el &+ ar
            h[3] = h[4] &+ al &+ br
            h[4] = h[0] &+ bl &+ cr
            h[0] = t
        }

        var out = [UInt8]()
        out.reserveCapacity(20)
        for word in h {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt32(i)))) }
        }
        return out
    }
}

extension Array where Element == UInt8 {
    /// Lowercase hex, in the array's own byte order.
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
