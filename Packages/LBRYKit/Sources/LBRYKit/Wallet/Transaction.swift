import Foundation

/// A Bitcoin-format (legacy, non-witness) LBC transaction. Claims and supports
/// are just output scripts.
public struct Transaction: Equatable, Sendable {

    public struct Input: Equatable, Sendable {
        /// Previous transaction id, display hex.
        public var txid: String
        public var vout: UInt32
        public var scriptSig: [UInt8] = []
        public var sequence: UInt32 = 0xFFFF_FFFF
    }

    public struct Output: Equatable, Sendable {
        public var value: UInt64
        public var script: [UInt8]
    }

    public var version: Int32 = 1
    public var inputs: [Input] = []
    public var outputs: [Output] = []
    public var locktime: UInt32 = 0

    public init() {}

    public func serialized() -> [UInt8] {
        var w = ByteWriter()
        w.int32(version)
        w.varInt(inputs.count)
        for input in inputs {
            w.append(Self.internalHash(input.txid))
            w.uint32(input.vout)
            w.varBytes(input.scriptSig)
            w.uint32(input.sequence)
        }
        w.varInt(outputs.count)
        for output in outputs {
            w.uint64(output.value)
            w.varBytes(output.script)
        }
        w.uint32(locktime)
        return w.bytes
    }

    public var hex: String { serialized().hex }

    public var txid: String { LBRYHash.sha256d(serialized()).reversed().hex }

    public var totalOutput: UInt64 { outputs.reduce(0) { $0 + $1.value } }

    /// Legacy SIGHASH_ALL digest. `scriptCode` is the whole previous output script,
    /// claim prefix included, as lbry-sdk and lbcd do.
    public func legacySighash(inputIndex: Int, scriptCode: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.int32(version)
        w.varInt(inputs.count)
        for (i, input) in inputs.enumerated() {
            w.append(Self.internalHash(input.txid))
            w.uint32(input.vout)
            w.varBytes(i == inputIndex ? scriptCode : [])
            w.uint32(input.sequence)
        }
        w.varInt(outputs.count)
        for output in outputs {
            w.uint64(output.value)
            w.varBytes(output.script)
        }
        w.uint32(locktime)
        w.uint32(1)   // SIGHASH_ALL
        return LBRYHash.sha256d(w.bytes)
    }

    /// Display hex → internal byte order.
    static func internalHash(_ txid: String) -> [UInt8] {
        ([UInt8](hex: txid) ?? [UInt8](repeating: 0, count: 32)).reversed()
    }
}

struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func append(_ b: [UInt8]) { bytes += b }
    mutating func int32(_ v: Int32) { uint32(UInt32(bitPattern: v)) }
    mutating func uint32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func uint64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }

    mutating func varInt(_ n: Int) {
        switch n {
        case ..<0xFD: bytes.append(UInt8(n))
        case ...0xFFFF:
            bytes.append(0xFD)
            withUnsafeBytes(of: UInt16(n).littleEndian) { bytes += $0 }
        case ...0xFFFF_FFFF:
            bytes.append(0xFE)
            uint32(UInt32(n))
        default:
            bytes.append(0xFF)
            uint64(UInt64(n))
        }
    }

    mutating func varBytes(_ b: [UInt8]) {
        varInt(b.count)
        bytes += b
    }
}
