import Foundation
import libsecp256k1

// MARK: - RLP

/// Recursive Length Prefix encoding (Ethereum's serialisation).
public enum RLP {
    public indirect enum Item: Equatable {
        case bytes([UInt8])
        case list([Item])

        public static func uint(_ v: UInt64) -> Item { .bytes(UInt256(v).minimalBigEndian) }
        public static func uint(_ v: UInt256) -> Item { .bytes(v.minimalBigEndian) }
    }

    public static func encode(_ item: Item) -> [UInt8] {
        switch item {
        case .bytes(let b):
            if b.count == 1, b[0] < 0x80 { return b }
            return header(b.count, offset: 0x80) + b
        case .list(let items):
            let body = items.flatMap(encode)
            return header(body.count, offset: 0xC0) + body
        }
    }

    private static func header(_ length: Int, offset: UInt8) -> [UInt8] {
        if length < 56 { return [offset + UInt8(length)] }
        let lengthBytes = UInt256(UInt64(length)).minimalBigEndian
        return [offset + 55 + UInt8(lengthBytes.count)] + lengthBytes
    }
}

// MARK: - ABI

/// Solidity ABI encoding for the argument types Carrel calls with.
public enum ABIValue {
    case address(String)
    case uint(UInt256)
    case bytes32([UInt8])
    case bytes([UInt8])
    case string(String)

    var isDynamic: Bool {
        switch self {
        case .bytes, .string: return true
        default: return false
        }
    }
}

extension ABI {
    /// `selector(signature) ‖ encode(args)`.
    public static func call(_ signature: String, _ args: [ABIValue]) throws -> [UInt8] {
        selector(signature) + (try encode(args))
    }

    public static func encode(_ args: [ABIValue]) throws -> [UInt8] {
        var head: [UInt8] = []
        var tail: [UInt8] = []
        let headSize = 32 * args.count
        for arg in args {
            switch arg {
            case .address(let a):
                guard let bytes = EthereumAddress.bytes(a) else { throw EthereumTxError.badAddress(a) }
                head += word(address: bytes)
            case .uint(let v):
                head += v.bigEndian32
            case .bytes32(let b):
                guard b.count == 32 else { throw EthereumTxError.badArgument("bytes32 needs 32 bytes") }
                head += b
            case .bytes(let b):
                head += UInt256(UInt64(headSize + tail.count)).bigEndian32
                tail += UInt256(UInt64(b.count)).bigEndian32 + padded(b)
            case .string(let s):
                let b = Array(s.utf8)
                head += UInt256(UInt64(headSize + tail.count)).bigEndian32
                tail += UInt256(UInt64(b.count)).bigEndian32 + padded(b)
            }
        }
        return head + tail
    }

    private static func padded(_ b: [UInt8]) -> [UInt8] {
        b + [UInt8](repeating: 0, count: (32 - b.count % 32) % 32)
    }
}

// MARK: - Transactions

public enum EthereumTxError: Error, Equatable, LocalizedError {
    case badAddress(String)
    case badArgument(String)
    case signingFailed
    case insufficientETH(needed: String, available: String)
    case reverted(String)

    public var errorDescription: String? {
        switch self {
        case .badAddress: return "That isn't a valid Ethereum address."
        case .badArgument(let why): return why
        case .signingFailed: return "Couldn't sign the transaction."
        case .insufficientETH(let needed, let available):
            return "Not enough ETH for this and its network fee: needs \(needed) ETH, the wallet has \(available) ETH."
        case .reverted(let hash): return "The transaction failed on Ethereum (\(hash.prefix(10))…)."
        }
    }
}

/// An EIP-1559 (type 2) transaction.
public struct EthereumTransaction: Equatable, Sendable {
    public var chainID: UInt64 = 1
    public var nonce: UInt64
    public var maxPriorityFeePerGas: UInt256
    public var maxFeePerGas: UInt256
    public var gasLimit: UInt64
    public var to: String
    public var value: UInt256
    public var data: [UInt8]

    public init(chainID: UInt64 = 1, nonce: UInt64, maxPriorityFeePerGas: UInt256, maxFeePerGas: UInt256,
                gasLimit: UInt64, to: String, value: UInt256 = .zero, data: [UInt8] = []) {
        self.chainID = chainID
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    /// Most this can cost in fees: gas limit × max fee per gas.
    public var maxFee: UInt256 { maxFeePerGas.multiplied(by: gasLimit) }

    private func fields() throws -> [RLP.Item] {
        guard let toBytes = EthereumAddress.bytes(to) else { throw EthereumTxError.badAddress(to) }
        return [
            .uint(chainID), .uint(nonce), .uint(maxPriorityFeePerGas), .uint(maxFeePerGas),
            .uint(gasLimit), .bytes(toBytes), .uint(value), .bytes(data), .list([]),
        ]
    }

    /// keccak256(0x02 ‖ rlp([chainId, nonce, …, accessList])).
    public func signingHash() throws -> [UInt8] {
        Keccak256.hash([0x02] + RLP.encode(.list(try fields())))
    }

    /// Raw signed transaction (for `eth_sendRawTransaction`) and its hash.
    public func signed(privateKey: [UInt8]) throws -> (raw: [UInt8], hash: String) {
        let (r, s, recid) = try Secp256k1.signRecoverable(digest: signingHash(), privateKey: privateKey)
        let raw = [0x02] + RLP.encode(.list(try fields() + [
            .uint(UInt64(recid)),
            .bytes(Array(r.drop { $0 == 0 })),
            .bytes(Array(s.drop { $0 == 0 })),
        ]))
        return (raw, "0x" + Keccak256.hash(raw).hex)
    }
}

// MARK: - Calls Carrel makes

/// What to put in a transaction's `to`, `value` and `data` for each action.
public struct EthereumCall: Equatable, Sendable {
    public let to: String
    public let value: UInt256
    public let data: [UInt8]
    /// A safe ceiling if `eth_estimateGas` fails.
    public let fallbackGas: UInt64

    /// Plain ETH to an address.
    public static func sendETH(to: String, wei: UInt256) throws -> EthereumCall {
        guard EthereumAddress.isValid(to) else { throw EthereumTxError.badAddress(to) }
        return EthereumCall(to: to, value: wei, data: [], fallbackGas: 21_000)
    }

    /// ERC-20 `transfer(address,uint256)`. (USDT returns nothing rather than `true`;
    /// a successful receipt is the success signal for every token here.)
    public static func transfer(_ token: ERC20Token, to: String, amount: UInt256) throws -> EthereumCall {
        guard EthereumAddress.isValid(to) else { throw EthereumTxError.badAddress(to) }
        let data = try ABI.call("transfer(address,uint256)", [.address(to), .uint(amount)])
        return EthereumCall(to: token.contract, value: .zero, data: data, fallbackGas: 100_000)
    }

    /// `Bridge.wrap(to, amount, lbcTxid, signature)` with the bridge's signed approval.
    public static func bridgeWrap(_ args: LBCBridge.WrapArgs, bridge: String = LBCBridge.bridgeContract) throws -> EthereumCall {
        guard let amount = UInt256(decimal: args.amount) else { throw EthereumTxError.badArgument("Bad mint amount from the bridge.") }
        let txidHex = args.lbcTxid.hasPrefix("0x") ? String(args.lbcTxid.dropFirst(2)) : args.lbcTxid
        let sigHex = args.signature.hasPrefix("0x") ? String(args.signature.dropFirst(2)) : args.signature
        guard let txid = [UInt8](hex: txidHex.lowercased()), txid.count == 32,
              let signature = [UInt8](hex: sigHex.lowercased()), signature.count == 65 else {
            throw EthereumTxError.badArgument("Bad mint approval from the bridge.")
        }
        let data = try ABI.call("wrap(address,uint256,bytes32,bytes)",
                                [.address(args.to), .uint(amount), .bytes32(txid), .bytes(signature)])
        return EthereumCall(to: bridge, value: .zero, data: data, fallbackGas: 150_000)
    }

    /// `Bridge.unwrap(amount, lbcAddress)`: burns wLBC; the bridge pays LBC to the address.
    public static func bridgeUnwrap(amount: UInt256, lbcAddress: String, bridge: String = LBCBridge.bridgeContract) throws -> EthereumCall {
        guard LBCAddress.isValid(lbcAddress) else { throw ScriptError.badAddress }
        let data = try ABI.call("unwrap(uint256,string)", [.uint(amount), .string(lbcAddress)])
        return EthereumCall(to: bridge, value: .zero, data: data, fallbackGas: 120_000)
    }

    public func transaction(nonce: UInt64, fees: EthereumFees, gasLimit: UInt64, chainID: UInt64 = 1) -> EthereumTransaction {
        EthereumTransaction(chainID: chainID, nonce: nonce, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
                            maxFeePerGas: fees.maxFeePerGas, gasLimit: gasLimit, to: to, value: value, data: data)
    }
}

/// EIP-1559 fee caps.
public struct EthereumFees: Equatable, Sendable {
    public var maxPriorityFeePerGas: UInt256
    public var maxFeePerGas: UInt256

    public init(maxPriorityFeePerGas: UInt256, maxFeePerGas: UInt256) {
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
    }

    /// The usual wallet rule: max fee = 2 × base fee + tip, so the transaction stays
    /// valid through several full blocks of base-fee rises.
    public static func suggested(baseFee: UInt256, priorityFee: UInt256) -> EthereumFees {
        EthereumFees(maxPriorityFeePerGas: priorityFee, maxFeePerGas: baseFee.multiplied(by: 2).adding(priorityFee))
    }
}
