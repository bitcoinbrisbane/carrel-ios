import Foundation

/// A spendable output owned by the wallet.
public struct UTXO: Equatable, Hashable, Sendable, Codable {
    public let txid: String
    public let vout: UInt32
    public let value: UInt64
    /// Full output script, including any claim/support prefix.
    public let script: [UInt8]
    public let address: String
    /// Block height, or 0 when unconfirmed.
    public let height: Int

    public init(txid: String, vout: UInt32, value: UInt64, script: [UInt8], address: String, height: Int) {
        self.txid = txid
        self.vout = vout
        self.value = value
        self.script = script
        self.address = address
        self.height = height
    }
}

public enum TxBuilderError: Error, Equatable {
    case insufficientFunds(needed: UInt64, available: UInt64)
    case tooManyInputs(max: Int, coins: Int)
    case keyMismatch(input: Int)
    case signatureCheckFailed(input: Int)
}

/// Coin selection, fees and signing — a direct port of lbc.exchange's builder, so
/// both produce byte-identical transactions (checked in the tests).
public enum TxBuilder {

    /// Upper bound of a signed P2PKH input: outpoint 36 + len 1 + push(72) + push(33) + sequence 4.
    public static let p2pkhInputSize = 148
    /// lbcd refuses transactions above ~675 P2PKH inputs.
    public static let maxInputs = 600

    public struct Recipient: Equatable, Sendable {
        public let script: [UInt8]
        public let value: UInt64
        public init(script: [UInt8], value: UInt64) {
            self.script = script
            self.value = value
        }
    }

    public struct Selection: Equatable, Sendable {
        public let inputs: [UTXO]
        public let fee: UInt64
        public let change: UInt64
        public let size: Int
    }

    public static func outputSize(_ script: [UInt8]) -> Int {
        8 + varIntSize(script.count) + script.count
    }

    public static func estimateSize(inputCount: Int, outputScripts: [[UInt8]]) -> Int {
        4 + varIntSize(inputCount) + inputCount * p2pkhInputSize
            + varIntSize(outputScripts.count) + outputScripts.reduce(0) { $0 + outputSize($1) } + 4
    }

    public static func fee(size: Int, feePerByte: UInt64) -> UInt64 {
        UInt64(size) * feePerByte
    }

    /// Chooses inputs covering the recipients plus fee: first the smallest single coin
    /// that covers it, otherwise largest-first. Confirmed coins come before unconfirmed;
    /// change below the dust threshold goes to the fee.
    public static func selectCoins(
        _ utxos: [UTXO], recipients: [Recipient], changeScript: [UInt8],
        feePerByte: UInt64 = LBCNetwork.defaultFeePerByte
    ) throws -> Selection {
        let target = recipients.reduce(UInt64(0)) { $0 + $1.value }
        let outScripts = recipients.map(\.script)
        let available = utxos.reduce(UInt64(0)) { $0 + $1.value }

        func evaluate(_ inputs: [UTXO]) -> Selection? {
            let total = inputs.reduce(UInt64(0)) { $0 + $1.value }
            let sizeWithChange = estimateSize(inputCount: inputs.count, outputScripts: outScripts + [changeScript])
            let feeWithChange = fee(size: sizeWithChange, feePerByte: feePerByte)
            if total >= target + feeWithChange {
                let change = total - target - feeWithChange
                if change >= LBCNetwork.dustThreshold {
                    return Selection(inputs: inputs, fee: feeWithChange, change: change, size: sizeWithChange)
                }
            }
            let sizeNoChange = estimateSize(inputCount: inputs.count, outputScripts: outScripts)
            let feeNoChange = fee(size: sizeNoChange, feePerByte: feePerByte)
            if total >= target, total - target >= feeNoChange {
                return Selection(inputs: inputs, fee: total - target, change: 0, size: sizeNoChange)
            }
            return nil
        }

        // Stable sorts, matching JavaScript's Array.sort.
        func byValue(_ list: [UTXO], ascending: Bool) -> [UTXO] {
            list.enumerated().sorted { a, b in
                if a.element.value != b.element.value {
                    return ascending ? a.element.value < b.element.value : a.element.value > b.element.value
                }
                return a.offset < b.offset
            }.map(\.element)
        }
        let confirmed = utxos.filter { $0.height > 0 }
        let unconfirmed = utxos.filter { $0.height <= 0 }

        for coin in byValue(confirmed, ascending: true) + byValue(unconfirmed, ascending: true) {
            if let s = evaluate([coin]) { return s }
        }

        let largestFirst = byValue(confirmed, ascending: false) + byValue(unconfirmed, ascending: false)
        var accumulated: [UTXO] = []
        for coin in largestFirst {
            if accumulated.count >= maxInputs { throw TxBuilderError.tooManyInputs(max: maxInputs, coins: largestFirst.count) }
            accumulated.append(coin)
            if let s = evaluate(accumulated) { return s }
        }

        let estimate = fee(size: estimateSize(inputCount: max(largestFirst.count, 1), outputScripts: outScripts + [changeScript]),
                           feePerByte: feePerByte)
        throw TxBuilderError.insufficientFunds(needed: target + estimate, available: available)
    }

    /// Unsigned transaction: recipients in order, change last.
    public static func assemble(inputs: [UTXO], recipients: [Recipient], change: Recipient?) -> Transaction {
        var tx = Transaction()
        tx.inputs = inputs.map { Transaction.Input(txid: $0.txid, vout: $0.vout) }
        tx.outputs = recipients.map { Transaction.Output(value: $0.value, script: $0.script) }
        if let change, change.value > 0 {
            tx.outputs.append(Transaction.Output(value: change.value, script: change.script))
        }
        return tx
    }

    /// Signs every input with `privateKey(for:)`, then verifies each signature before
    /// returning, so a bad key or bug can never broadcast junk.
    public static func sign(
        _ unsigned: Transaction, spending inputs: [UTXO],
        privateKey: (UTXO) throws -> [UInt8]
    ) throws -> Transaction {
        var tx = unsigned
        for (i, utxo) in inputs.enumerated() {
            let key = try privateKey(utxo)
            let publicKey = try Secp256k1.publicKey(privateKey: key)
            guard Script.p2pkhHash(utxo.script) == LBRYHash.hash160(publicKey) else {
                throw TxBuilderError.keyMismatch(input: i)
            }
            let digest = tx.legacySighash(inputIndex: i, scriptCode: utxo.script)
            let signature = try Secp256k1.sign(digest: digest, privateKey: key) + [0x01]
            tx.inputs[i].scriptSig = Script.pushData(signature) + Script.pushData(publicKey)
        }
        for (i, utxo) in inputs.enumerated() where !verify(tx, input: i, prevScript: utxo.script) {
            throw TxBuilderError.signatureCheckFailed(input: i)
        }
        return tx
    }

    static func verify(_ tx: Transaction, input i: Int, prevScript: [UInt8]) -> Bool {
        let sigScript = tx.inputs[i].scriptSig
        guard let sigLength = sigScript.first.map(Int.init), sigLength > 1, sigScript.count > sigLength + 1 else { return false }
        let sigWithType = Array(sigScript[1...sigLength])
        let keyLength = Int(sigScript[sigLength + 1])
        guard sigScript.count == sigLength + 2 + keyLength, sigWithType.last == 0x01 else { return false }
        let publicKey = Array(sigScript[(sigLength + 2)...])
        guard Script.p2pkhHash(prevScript) == LBRYHash.hash160(publicKey) else { return false }
        let digest = tx.legacySighash(inputIndex: i, scriptCode: prevScript)
        return Secp256k1.verify(signature: Array(sigWithType.dropLast()), digest: digest, publicKey: publicKey)
    }

    private static func varIntSize(_ n: Int) -> Int {
        n < 0xFD ? 1 : n <= 0xFFFF ? 3 : 5
    }
}
