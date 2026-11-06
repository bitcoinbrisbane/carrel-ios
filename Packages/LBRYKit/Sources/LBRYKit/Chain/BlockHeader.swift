import Foundation

/// An LBRY block header: Bitcoin's 80-byte layout plus a 32-byte claimtrie root.
///
///     version(4) prevHash(32) merkleRoot(32) claimTrieRoot(32) timestamp(4) bits(4) nonce(4)
public struct BlockHeader: Hashable, Sendable, Codable {
    public static let size = 112

    public let raw: [UInt8]
    public let version: UInt32
    /// Internal (little-endian) byte order, as stored in the header.
    public let prevHash: [UInt8]
    public let merkleRoot: [UInt8]
    /// Commitment to the claimtrie — lets a client check `resolve` answers (see README).
    public let claimTrieRoot: [UInt8]
    public let timestamp: UInt32
    public let bits: UInt32
    public let nonce: UInt32
    /// Double SHA-256 of `raw`, internal byte order.
    public let hash: [UInt8]

    public enum ParseError: Error, Equatable { case wrongLength(Int) }

    public init(raw: [UInt8]) throws {
        guard raw.count == Self.size else { throw ParseError.wrongLength(raw.count) }
        self.raw = raw
        version = Self.u32(raw, 0)
        prevHash = Array(raw[4..<36])
        merkleRoot = Array(raw[36..<68])
        claimTrieRoot = Array(raw[68..<100])
        timestamp = Self.u32(raw, 100)
        bits = Self.u32(raw, 104)
        nonce = Self.u32(raw, 108)
        hash = LBRYHash.sha256d(raw)
    }

    public init(hex: String) throws {
        guard let bytes = [UInt8](hex: hex) else { throw ParseError.wrongLength(hex.count / 2) }
        try self.init(raw: bytes)
    }

    /// Block hash as shown by explorers (big-endian hex).
    public var hashHex: String { hash.reversed().hex }
    public var prevHashHex: String { prevHash.reversed().hex }
    public var claimTrieRootHex: String { claimTrieRoot.reversed().hex }

    public var target: UInt256 { UInt256(compact: bits) }

    /// LBRY proof-of-work value, comparable against `target`.
    public var proofOfWork: UInt256 {
        UInt256(littleEndianBytes: LBRYHash.powHash(blockHash: hash))
    }

    /// Expected work to produce this block, ≈ 2^256 / (target + 1). Approximate; for fork choice only.
    public var work: Double {
        pow(2, 256) / (target.doubleValue + 1)
    }

    public static func split(_ bytes: [UInt8]) throws -> [BlockHeader] {
        guard bytes.count % size == 0 else { throw ParseError.wrongLength(bytes.count) }
        return try stride(from: 0, to: bytes.count, by: size).map {
            try BlockHeader(raw: Array(bytes[$0..<($0 + size)]))
        }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    // Codable as hex of the raw bytes; everything else is derived.
    public init(from decoder: Decoder) throws {
        try self.init(hex: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw.hex)
    }
}

/// LBRY difficulty adjustment (lbrycrd `src/lbry.cpp`). Retargets every block from
/// the time between the two previous blocks, damped by 1/8 and clamped.
public enum LBRYDifficulty {
    public static let targetSpacing = 150     // seconds
    public static let minTimespan = 132       // 150 - 150/8
    public static let maxTimespan = 225       // 150 + 150/2

    /// Expected `bits` for the block after `previous`, given the block before that.
    public static func nextBits(previousPrevious: BlockHeader, previous: BlockHeader) -> UInt32 {
        nextBits(
            previousPreviousTimestamp: previousPrevious.timestamp,
            previousTimestamp: previous.timestamp,
            previousBits: previous.bits
        )
    }

    public static func nextBits(previousPreviousTimestamp: UInt32, previousTimestamp: UInt32, previousBits: UInt32) -> UInt32 {
        let actual = Int(previousTimestamp) - Int(previousPreviousTimestamp)
        let modulated = targetSpacing + (actual - targetSpacing) / 8   // Swift `/` truncates toward zero, like C++
        let clamped = max(minTimespan, min(modulated, maxTimespan))
        let next = UInt256(compact: previousBits)
            .multiplied(by: UInt64(clamped))
            .divided(by: UInt64(targetSpacing))
        return min(next, UInt256.lbryMaxTarget).compact
    }
}
