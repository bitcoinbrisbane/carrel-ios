import Foundation

/// What Ethereum amounts need from `UInt256`: parsing, adding, and big-endian bytes.
extension UInt256 {

    public func adding(_ other: UInt256) -> UInt256 {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return UInt256(limbs: out)
    }

    /// Nil on underflow.
    public func subtracting(_ other: UInt256) -> UInt256? {
        guard self >= other else { return nil }
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = limbs[i].subtractingReportingOverflow(other.limbs[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return UInt256(limbs: out)
    }

    /// Decimal digits ("1500000"). Nil if not a number or too big.
    public init?(decimal: String) {
        var value = UInt256.zero
        guard !decimal.isEmpty else { return nil }
        for c in decimal {
            guard let d = c.wholeNumberValue, c.isASCII else { return nil }
            let next = value.multiplied(by: 10).adding(UInt256(UInt64(d)))
            guard next.divided(by: 10) == value || value == .zero else { return nil }   // overflow
            value = next
        }
        self = value
    }

    /// Hex quantity ("0x5208"), as JSON-RPC returns.
    public init?(hex: String) {
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !body.isEmpty, body.count <= 64, body.allSatisfy(\.isHexDigit) else { return nil }
        let padded = String(repeating: "0", count: 64 - body.count) + body
        guard let bytes = [UInt8](hex: padded.lowercased()) else { return nil }
        self.init(bigEndianBytes: bytes)
    }

    public init(bigEndianBytes bytes: [UInt8]) {
        precondition(bytes.count <= 32)
        self.init(littleEndianBytes: Array(([UInt8](repeating: 0, count: 32 - bytes.count) + bytes).reversed()))
    }

    /// 32 bytes, big-endian (an ABI word).
    public var bigEndian32: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) }
        }
        return out
    }

    /// Big-endian with no leading zeros (zero → empty), as RLP wants.
    public var minimalBigEndian: [UInt8] {
        Array(bigEndian32.drop { $0 == 0 })
    }

    /// "0x…" quantity for JSON-RPC.
    public var hexQuantity: String {
        let hex = minimalBigEndian.hex
        let trimmed = hex.drop { $0 == "0" }
        return "0x" + (trimmed.isEmpty ? "0" : String(trimmed))
    }

    public var decimalString: String {
        if self == .zero { return "0" }
        var digits: [Character] = []
        var n = self
        while n != .zero {
            let q = n.divided(by: 10)
            let r = n.subtracting(q.multiplied(by: 10))!.limbs[0]
            digits.append(Character(String(r)))
            n = q
        }
        return String(digits.reversed())
    }

    /// Whole units → smallest units: "1.5" with 6 decimals → 1_500_000. Nil if more
    /// decimal places than the asset has, or not a number.
    public init?(units text: String, decimals: Int) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals else { return nil }
        self.init(decimal: whole + fraction + String(repeating: "0", count: decimals - fraction.count))
    }

    /// Smallest units → "1.5" (trailing zeros trimmed).
    public func formatted(decimals: Int, maxFractionDigits: Int? = nil) -> String {
        var s = decimalString
        if s.count <= decimals { s = String(repeating: "0", count: decimals - s.count + 1) + s }
        let whole = String(s.dropLast(decimals))
        var fraction = String(s.suffix(decimals))
        if let max = maxFractionDigits { fraction = String(fraction.prefix(max)) }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }
}
