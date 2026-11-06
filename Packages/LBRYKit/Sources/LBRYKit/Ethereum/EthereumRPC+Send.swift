import Foundation

/// A transaction ready to sign, with what it will cost.
public struct PreparedEthereumTx: Sendable, Equatable {
    public let transaction: EthereumTransaction
    /// Likely fee: gas estimate × (base fee + tip).
    public let expectedFee: UInt256
    /// Worst case: gas limit × max fee per gas. The wallet must hold this plus `value`.
    public var maxFee: UInt256 { transaction.maxFee }

    public var expectedFeeETH: String { expectedFee.formatted(decimals: 18, maxFractionDigits: 6) }
    public var maxFeeETH: String { maxFee.formatted(decimals: 18, maxFractionDigits: 6) }
}

public struct EthereumReceipt: Sendable, Equatable {
    public let hash: String
    public let blockNumber: UInt64
    public let succeeded: Bool
    public let gasUsed: UInt256
}

extension EthereumRPC {

    public func blockNumber() async throws -> UInt64 {
        try quantity(await call("eth_blockNumber", []), "eth_blockNumber")
    }

    /// Next nonce, counting transactions still in the mempool.
    public func nonce(of address: String) async throws -> UInt64 {
        try quantity(await call("eth_getTransactionCount", [address, "pending"]), "eth_getTransactionCount")
    }

    public func estimateGas(from: String, call: EthereumCall) async throws -> UInt64 {
        var tx: [String: Any] = ["from": from, "to": call.to, "value": call.value.hexQuantity]
        if !call.data.isEmpty { tx["data"] = "0x" + call.data.hex }
        return try quantity(await self.call("eth_estimateGas", [tx]), "eth_estimateGas")
    }

    /// Latest base fee and a tip from `eth_maxPriorityFeePerGas` (floored at 0.05 gwei,
    /// capped at 3 gwei so a spiky node can't make us overpay).
    public func feeEstimate() async throws -> (baseFee: UInt256, priorityFee: UInt256) {
        guard let block = try await call("eth_getBlockByNumber", ["latest", false]) as? [String: Any],
              let baseHex = block["baseFeePerGas"] as? String, let baseFee = UInt256(hex: baseHex) else {
            throw EthereumRPCError.badResponse("baseFeePerGas")
        }
        let floor = UInt256(50_000_000), cap = UInt256(3_000_000_000)
        var tip = UInt256(1_000_000_000)
        if let hex = try? await call("eth_maxPriorityFeePerGas", []) as? String, let suggested = UInt256(hex: hex) {
            tip = suggested
        }
        return (baseFee, max(floor, min(cap, tip)))
    }

    /// Builds the transaction: nonce, gas (estimate + 20%), fees, and checks the
    /// wallet has the ETH for value plus the worst-case fee.
    public func prepare(_ call: EthereumCall, from: String, chainID: UInt64 = 1) async throws -> PreparedEthereumTx {
        async let nonceValue = nonce(of: from)
        async let feeValue = feeEstimate()
        async let balanceValue = self.call("eth_getBalance", [from, "latest"])
        let gasEstimate: UInt64
        do {
            gasEstimate = try await estimateGas(from: from, call: call)
        } catch let error as EthereumRPCError {
            // Estimation runs the call: a node-reported error (usually a revert) means it
            // would fail on-chain too, so stop. Only a network hiccup falls back.
            if case .rpc = error { throw error }
            gasEstimate = call.fallbackGas
        } catch {
            gasEstimate = call.fallbackGas
        }
        let gasLimit = gasEstimate == 21_000 ? 21_000 : gasEstimate + gasEstimate / 5
        let (baseFee, tip) = try await feeValue
        let fees = EthereumFees.suggested(baseFee: baseFee, priorityFee: tip)
        let tx = call.transaction(nonce: try await nonceValue, fees: fees, gasLimit: gasLimit, chainID: chainID)
        guard let balanceHex = try await balanceValue as? String, let balance = UInt256(hex: balanceHex) else {
            throw EthereumRPCError.badResponse("eth_getBalance")
        }
        let needed = tx.value.adding(tx.maxFee)
        guard balance >= needed else {
            throw EthereumTxError.insufficientETH(needed: needed.formatted(decimals: 18, maxFractionDigits: 6),
                                                  available: balance.formatted(decimals: 18, maxFractionDigits: 6))
        }
        let expected = baseFee.adding(tip).multiplied(by: gasEstimate)
        return PreparedEthereumTx(transaction: tx, expectedFee: expected)
    }

    /// Broadcasts a signed transaction; returns its hash.
    public func sendRawTransaction(_ raw: [UInt8]) async throws -> String {
        guard let hash = try await call("eth_sendRawTransaction", ["0x" + raw.hex]) as? String else {
            throw EthereumRPCError.badResponse("eth_sendRawTransaction")
        }
        return hash
    }

    /// Nil while the transaction is still pending.
    public func receipt(_ hash: String) async throws -> EthereumReceipt? {
        let result = try await call("eth_getTransactionReceipt", [hash])
        guard let r = result as? [String: Any] else { return nil }
        guard let block = (r["blockNumber"] as? String).flatMap({ UInt256(hex: $0) }) else { return nil }
        return EthereumReceipt(hash: hash, blockNumber: block.limbs[0],
                               succeeded: r["status"] as? String == "0x1",
                               gasUsed: (r["gasUsed"] as? String).flatMap { UInt256(hex: $0) } ?? .zero)
    }

    /// Polls until the transaction is mined (every 6 s, giving up after `timeout`).
    public func waitForReceipt(_ hash: String, timeout: TimeInterval = 600) async throws -> EthereumReceipt? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let mined = try? await receipt(hash) { return mined }
            try await Task.sleep(nanoseconds: 6_000_000_000)
        }
        return nil
    }

    private func quantity(_ value: Any, _ method: String) throws -> UInt64 {
        guard let hex = value as? String, let n = UInt256(hex: hex), n.bitWidth <= 64 else {
            throw EthereumRPCError.badResponse(method)
        }
        return n.limbs[0]
    }
}
