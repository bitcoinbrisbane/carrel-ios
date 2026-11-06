import Foundation

extension Transaction {

    public enum ParseError: Error, Equatable {
        case truncated
        case unsupportedFlag
        case trailingBytes
        case badHex
    }

    public init(hex: String) throws {
        guard let bytes = [UInt8](hex: hex) else { throw ParseError.badHex }
        try self.init(bytes: bytes)
    }

    /// Parses legacy and SegWit serialisations (witness data is skipped: the wallet
    /// only signs legacy P2PKH, but may receive from anything).
    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        self.init()
        version = Int32(bitPattern: try r.uint32())
        var segwit = false
        if r.remaining >= 2, r.peek() == 0x00 {
            _ = try r.uint8()
            guard try r.uint8() == 0x01 else { throw ParseError.unsupportedFlag }
            segwit = true
        }
        let inputCount = try r.varInt()
        for _ in 0..<inputCount {
            let prev = try r.read(32)
            let vout = try r.uint32()
            let scriptSig = try r.read(try r.varInt())
            let sequence = try r.uint32()
            inputs.append(Input(txid: prev.reversed().hex, vout: vout, scriptSig: scriptSig, sequence: sequence))
        }
        let outputCount = try r.varInt()
        for _ in 0..<outputCount {
            let value = try r.uint64()
            outputs.append(Output(value: value, script: try r.read(try r.varInt())))
        }
        if segwit {
            for _ in 0..<inputCount {
                let items = try r.varInt()
                for _ in 0..<items { _ = try r.read(try r.varInt()) }
            }
        }
        locktime = try r.uint32()
        guard r.remaining == 0 else { throw ParseError.trailingBytes }
    }

    /// The txid of a SegWit transaction ignores witness data, so re-serialising the
    /// parsed (witness-free) form gives the right id either way.
    public var isCoinbase: Bool {
        inputs.count == 1 && inputs[0].txid == String(repeating: "0", count: 64) && inputs[0].vout == 0xFFFF_FFFF
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }
    func peek() -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func read(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw Transaction.ParseError.truncated }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func uint8() throws -> UInt8 { try read(1)[0] }

    mutating func uint32() throws -> UInt32 {
        try read(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func uint64() throws -> UInt64 {
        try read(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    mutating func varInt() throws -> Int {
        let first = try uint8()
        switch first {
        case 0xFD: return Int(try read(2).enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) })
        case 0xFE: return Int(try uint32())
        case 0xFF:
            let v = try uint64()
            guard v <= UInt64(Int.max) else { throw Transaction.ParseError.truncated }
            return Int(v)
        default: return Int(first)
        }
    }
}

/// Electrum-style merkle branch check: does `txid` sit under `merkleRoot`?
/// `branch` and `txid` are display hex (as hubs return them); `merkleRoot` is the
/// header's internal-order root.
public enum MerkleProof {
    public static func verify(txid: String, branch: [String], position: Int, merkleRoot: [UInt8]) -> Bool {
        guard var hash = [UInt8](hex: txid).map({ Array($0.reversed()) }), hash.count == 32, position >= 0 else { return false }
        var index = position
        for siblingHex in branch {
            guard let s = [UInt8](hex: siblingHex), s.count == 32 else { return false }
            let sibling = Array(s.reversed())
            hash = index & 1 == 1 ? LBRYHash.sha256d(sibling + hash) : LBRYHash.sha256d(hash + sibling)
            index >>= 1
        }
        return index == 0 && hash == merkleRoot
    }
}
