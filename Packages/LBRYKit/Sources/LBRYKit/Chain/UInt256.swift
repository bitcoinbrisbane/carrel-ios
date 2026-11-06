import Foundation

/// Minimal unsigned 256-bit integer for difficulty targets: compact ("bits")
/// encoding, multiply/divide by a small number, and comparison. Arithmetic
/// wraps mod 2^256, matching lbrycrd's `arith_uint256`.
public struct UInt256: Comparable, Hashable, Sendable, CustomStringConvertible {

    /// Little-endian 64-bit limbs: limbs[0] is least significant.
    public private(set) var limbs: [UInt64]

    public static let zero = UInt256(limbs: [0, 0, 0, 0])

    /// LBRY's proof-of-work limit (0x0000ffff…ff).
    public static let lbryMaxTarget = UInt256(limbs: [.max, .max, .max, 0x0000_FFFF_FFFF_FFFF])

    public init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = limbs
    }

    public init(_ value: UInt64) {
        self.init(limbs: [value, 0, 0, 0])
    }

    /// Interpret 32 bytes as a little-endian number (how Bitcoin-family hashes compare to targets).
    public init(littleEndianBytes bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<32 {
            limbs[i / 8] |= UInt64(bytes[i]) << (8 * UInt64(i % 8))
        }
        self.init(limbs: limbs)
    }

    // MARK: Compact encoding (nBits)

    public init(compact: UInt32) {
        let size = Int(compact >> 24)
        let word = UInt64(compact & 0x007F_FFFF)
        if size <= 3 {
            self = UInt256(word >> (8 * UInt64(3 - size)))
        } else {
            self = UInt256(word) << (8 * (size - 3))
        }
    }

    public var compact: UInt32 {
        var size = (bitWidth + 7) / 8
        var mantissa: UInt64
        if size <= 3 {
            mantissa = limbs[0] << (8 * UInt64(3 - size))
        } else {
            mantissa = (self >> (8 * (size - 3))).limbs[0]
        }
        // 0x00800000 is the sign bit; keep the mantissa positive.
        if mantissa & 0x0080_0000 != 0 {
            mantissa >>= 8
            size += 1
        }
        return UInt32(truncatingIfNeeded: mantissa) | UInt32(size) << 24
    }

    /// Position of the highest set bit plus one (0 for zero).
    public var bitWidth: Int {
        for i in stride(from: 3, through: 0, by: -1) where limbs[i] != 0 {
            return i * 64 + (64 - limbs[i].leadingZeroBitCount)
        }
        return 0
    }

    // MARK: Arithmetic

    public func multiplied(by m: UInt64) -> UInt256 {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (high, low) = limbs[i].multipliedFullWidth(by: m)
            let (sum, overflow) = low.addingReportingOverflow(carry)
            out[i] = sum
            carry = high &+ (overflow ? 1 : 0)
        }
        return UInt256(limbs: out)   // final carry discarded: mod 2^256
    }

    public func divided(by d: UInt64) -> UInt256 {
        precondition(d != 0)
        var out = [UInt64](repeating: 0, count: 4)
        var remainder: UInt64 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            let (q, r) = d.dividingFullWidth((high: remainder, low: limbs[i]))
            out[i] = q
            remainder = r
        }
        return UInt256(limbs: out)
    }

    public static func << (lhs: UInt256, shift: Int) -> UInt256 {
        guard shift > 0 else { return lhs }
        guard shift < 256 else { return .zero }
        let limbShift = shift / 64, bitShift = UInt64(shift % 64)
        var out = [UInt64](repeating: 0, count: 4)
        for i in stride(from: 3, through: limbShift, by: -1) {
            out[i] = lhs.limbs[i - limbShift] << bitShift
            if bitShift > 0 && i - limbShift - 1 >= 0 {
                out[i] |= lhs.limbs[i - limbShift - 1] >> (64 - bitShift)
            }
        }
        return UInt256(limbs: out)
    }

    public static func >> (lhs: UInt256, shift: Int) -> UInt256 {
        guard shift > 0 else { return lhs }
        guard shift < 256 else { return .zero }
        let limbShift = shift / 64, bitShift = UInt64(shift % 64)
        var out = [UInt64](repeating: 0, count: 4)
        for i in 0..<(4 - limbShift) {
            out[i] = lhs.limbs[i + limbShift] >> bitShift
            if bitShift > 0 && i + limbShift + 1 < 4 {
                out[i] |= lhs.limbs[i + limbShift + 1] << (64 - bitShift)
            }
        }
        return UInt256(limbs: out)
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    /// Approximate value as a Double — used only to compare chain work.
    public var doubleValue: Double {
        limbs.enumerated().reduce(0) { $0 + Double($1.element) * pow(2, Double(64 * $1.offset)) }
    }

    public var description: String {
        "0x" + limbs.reversed().map { String(format: "%016llx", $0) }.joined()
    }
}
