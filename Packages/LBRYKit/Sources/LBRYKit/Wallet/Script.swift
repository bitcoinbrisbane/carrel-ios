import Foundation

/// LBC network constants.
public enum LBCNetwork {
    /// Base58 version for pay-to-pubkey-hash (addresses start with "b").
    public static let pubKeyHashPrefix: UInt8 = 0x55
    /// Base58 version for pay-to-script-hash (addresses start with "r").
    public static let scriptHashPrefix: UInt8 = 0x7A
    public static let wifPrefix: UInt8 = 0x1C
    /// 1 LBC = 10^8 dewies.
    public static let dewiesPerLBC: UInt64 = 100_000_000
    /// Outputs smaller than this aren't worth creating.
    public static let dustThreshold: UInt64 = 1_000
    /// Default fee rate, dewies per byte (as lbry-sdk and lbc.exchange use).
    public static let defaultFeePerByte: UInt64 = 50
}

/// The parts of Bitcoin script LBRY wallets need, plus LBRY's claim opcodes.
public enum Script {

    public enum Op {
        public static let pushData1: UInt8 = 0x4C
        public static let pushData2: UInt8 = 0x4D
        public static let pushData4: UInt8 = 0x4E
        public static let twoDrop: UInt8 = 0x6D
        public static let drop: UInt8 = 0x75
        public static let dup: UInt8 = 0x76
        public static let equal: UInt8 = 0x87
        public static let equalVerify: UInt8 = 0x88
        public static let hash160: UInt8 = 0xA9
        public static let checkSig: UInt8 = 0xAC
        /// LBRY: claim a name (OP_NOP6).
        public static let claimName: UInt8 = 0xB5
        /// LBRY: support a claim, also used for tips (OP_NOP7).
        public static let supportClaim: UInt8 = 0xB6
        /// LBRY: update a claim (OP_NOP8).
        public static let updateClaim: UInt8 = 0xB7
    }

    public static func pushData(_ data: [UInt8]) -> [UInt8] {
        let n = data.count
        switch n {
        case 0..<Int(Op.pushData1): return [UInt8(n)] + data
        case 0...0xFF: return [Op.pushData1, UInt8(n)] + data
        case 0...0xFFFF: return [Op.pushData2, UInt8(n & 0xFF), UInt8(n >> 8)] + data
        default: return [Op.pushData4] + withUnsafeBytes(of: UInt32(n).littleEndian, Array.init) + data
        }
    }

    public static func p2pkh(hash160: [UInt8]) -> [UInt8] {
        [Op.dup, Op.hash160, 20] + hash160 + [Op.equalVerify, Op.checkSig]
    }

    public static func p2sh(hash160: [UInt8]) -> [UInt8] {
        [Op.hash160, 20] + hash160 + [Op.equal]
    }

    /// Support (or tip) output: `OP_SUPPORT_CLAIM <name> <claim id> OP_2DROP OP_DROP <payee script>`.
    /// A tip is a support whose payee is the creator; a support pays back to yourself.
    /// `claimID` is the usual display hex (it's stored reversed in the script).
    public static func support(name: String, claimID: String, payee: [UInt8]) throws -> [UInt8] {
        guard let id = [UInt8](hex: claimID), id.count == 20 else { throw ScriptError.badClaimID }
        return [Op.supportClaim] + pushData(Array(name.utf8)) + pushData(id.reversed())
            + [Op.twoDrop, Op.drop] + payee
    }

    /// Strips a leading claim/support/update prefix, leaving the payee script.
    public static func stripClaimPrefix(_ script: [UInt8]) -> [UInt8] {
        guard let first = script.first, [Op.claimName, Op.supportClaim, Op.updateClaim].contains(first) else { return script }
        var i = 1
        // Skip the prefix's data pushes…
        while i < script.count {
            let op = script[i]
            var length = 0
            var header = 1
            if op > 0 && op < Op.pushData1 {
                length = Int(op)
            } else if op == Op.pushData1, i + 1 < script.count {
                length = Int(script[i + 1]); header = 2
            } else if op == Op.pushData2, i + 2 < script.count {
                length = Int(script[i + 1]) | Int(script[i + 2]) << 8; header = 3
            } else if op == 0 {
                length = 0
            } else {
                break
            }
            i += header + length
        }
        // …then the drops that discard them.
        while i < script.count, script[i] == Op.twoDrop || script[i] == Op.drop { i += 1 }
        return i <= script.count ? Array(script[i...]) : script
    }

    /// The pubkey hash a (possibly claim-prefixed) P2PKH script pays, if it is one.
    public static func p2pkhHash(_ script: [UInt8]) -> [UInt8]? {
        let base = stripClaimPrefix(script)
        guard base.count == 25, base[0] == Op.dup, base[1] == Op.hash160, base[2] == 20,
              base[23] == Op.equalVerify, base[24] == Op.checkSig else { return nil }
        return Array(base[3..<23])
    }

    public static func isClaimOrSupport(_ script: [UInt8]) -> Bool {
        guard let first = script.first else { return false }
        return [Op.claimName, Op.supportClaim, Op.updateClaim].contains(first)
    }
}

public enum ScriptError: Error, Equatable {
    case badClaimID
    case badAddress
}

/// LBC addresses and private-key import format.
public enum LBCAddress {

    public static func p2pkh(publicKey: [UInt8]) -> String {
        Base58.encodeCheck([LBCNetwork.pubKeyHashPrefix] + LBRYHash.hash160(publicKey))
    }

    /// The output script an address is paid with.
    public static func script(for address: String) throws -> [UInt8] {
        guard let payload = Base58.decodeCheck(address.trimmingCharacters(in: .whitespacesAndNewlines)),
              payload.count == 21 else { throw ScriptError.badAddress }
        let hash = Array(payload[1...])
        switch payload[0] {
        case LBCNetwork.pubKeyHashPrefix: return Script.p2pkh(hash160: hash)
        case LBCNetwork.scriptHashPrefix: return Script.p2sh(hash160: hash)
        default: throw ScriptError.badAddress
        }
    }

    public static func isValid(_ address: String) -> Bool {
        (try? script(for: address)) != nil
    }

    /// Address paid by a (possibly claim-prefixed) P2PKH script.
    public static func address(for script: [UInt8]) -> String? {
        Script.p2pkhHash(script).map { Base58.encodeCheck([LBCNetwork.pubKeyHashPrefix] + $0) }
    }

    public static func wif(privateKey: [UInt8], compressed: Bool = true) -> String {
        Base58.encodeCheck([LBCNetwork.wifPrefix] + privateKey + (compressed ? [1] : []))
    }
}

/// Amounts in dewies, shown as LBC.
public enum LBCAmount {
    public static func format(_ dewies: UInt64, maxFractionDigits: Int = 8) -> String {
        let whole = dewies / LBCNetwork.dewiesPerLBC
        var fraction = String(dewies % LBCNetwork.dewiesPerLBC)
        fraction = String(repeating: "0", count: 8 - fraction.count) + fraction
        fraction = String(fraction.prefix(maxFractionDigits))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
    }

    /// "1.5" → 150_000_000. Rejects more than 8 decimal places.
    public static func parse(_ text: String) -> UInt64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = UInt64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
        var fraction: UInt64 = 0
        if parts.count == 2 {
            let f = String(parts[1])
            guard f.count <= 8, f.allSatisfy(\.isNumber) else { return nil }
            fraction = UInt64(f + String(repeating: "0", count: 8 - f.count)) ?? 0
        }
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: LBCNetwork.dewiesPerLBC)
        guard !overflow else { return nil }
        return scaled + fraction
    }
}
