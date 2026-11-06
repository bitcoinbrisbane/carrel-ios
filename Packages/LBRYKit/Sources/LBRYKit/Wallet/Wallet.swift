import Foundation

/// What the wallet needs from an LBRY hub. `HubClient` conforms; tests use a fake.
public protocol WalletBackend: Sendable {
    func history(of address: String) async throws -> [(txid: String, height: Int)]
    /// Raw transactions with their height and, when the hub sends one, a merkle branch.
    func transactions(_ txids: [String]) async throws -> [String: FetchedTransaction]
    func broadcast(_ rawHex: String) async throws -> String
}

public struct FetchedTransaction: Sendable, Equatable {
    public let hex: String
    /// 0 or less when unconfirmed.
    public let height: Int
    public let merkleBranch: [String]?
    public let merklePosition: Int?

    public init(hex: String, height: Int, merkleBranch: [String]? = nil, merklePosition: Int? = nil) {
        self.hex = hex
        self.height = height
        self.merkleBranch = merkleBranch
        self.merklePosition = merklePosition
    }
}

public enum WalletError: Error, Equatable {
    case watchOnly
    case hubMismatch(String)
    case merkleProofFailed(txid: String)
    case unknownAddress(String)
}

/// The wallet as seen after a scan: coins, balance and activity.
public struct WalletSnapshot: Sendable, Equatable {

    public struct Activity: Sendable, Equatable, Identifiable {
        public let txid: String
        public let height: Int
        /// Positive for money in, negative for money out (fee included).
        public let net: Int64
        /// Value this transaction put into supports or tips.
        public let supported: UInt64
        /// Verified against CarrelChain's headers (only possible inside the header window).
        public let verified: Bool
        public var id: String { txid }
        public var isConfirmed: Bool { height > 0 }
    }

    /// Plain coins the wallet can spend.
    public let spendable: [UTXO]
    /// Support/tip outputs that pay back to this wallet (your own supports, or tips you received).
    public let supports: [UTXO]
    public let activity: [Activity]
    /// Next unused receive address.
    public let receiveAddress: String
    public let usedAddressCount: Int

    public var confirmedBalance: UInt64 { spendable.filter { $0.height > 0 }.reduce(0) { $0 + $1.value } }
    public var pendingBalance: UInt64 { spendable.filter { $0.height <= 0 }.reduce(0) { $0 + $1.value } }
    public var supportedBalance: UInt64 { supports.reduce(0) { $0 + $1.value } }
}

/// The wallet: scans the account's addresses through a hub, builds and signs
/// sends, tips and supports, and broadcasts them.
public actor Wallet {

    public let account: WalletAccount
    private let backend: WalletBackend
    private let feePerByte: UInt64

    /// Addresses we know about, by string.
    private var known: [String: WalletAccount.Address] = [:]
    public private(set) var snapshot: WalletSnapshot?

    public init(account: WalletAccount, backend: WalletBackend, feePerByte: UInt64 = LBCNetwork.defaultFeePerByte) {
        self.account = account
        self.backend = backend
        self.feePerByte = feePerByte
    }

    // MARK: Scanning

    /// Walks receive and change addresses until a full gap of unused ones, fetches
    /// every transaction once, and works out coins and activity.
    /// When `headers` is given, confirmed transactions inside its window must carry
    /// a merkle proof that matches our own validated header, or the scan fails.
    @discardableResult
    public func scan(headers: HeaderChain? = nil) async throws -> WalletSnapshot {
        var histories: [String: [(txid: String, height: Int)]] = [:]
        var firstUnusedReceive: WalletAccount.Address?

        let chains: [(WalletAccount.Chain, Int)] = [(.receive, WalletAccount.receiveGap), (.change, WalletAccount.changeGap)]
        for (chain, gap) in chains {
            var index: UInt32 = 0
            var unusedRun = 0
            while unusedRun < gap {
                let batch = try account.addresses(chain, index..<index + UInt32(gap))
                for address in batch {
                    known[address.address] = address
                    let history = try await backend.history(of: address.address)
                    if history.isEmpty {
                        unusedRun += 1
                        if chain == .receive, firstUnusedReceive == nil { firstUnusedReceive = address }
                    } else {
                        unusedRun = 0
                        histories[address.address] = history
                        if chain == .receive { firstUnusedReceive = nil }
                    }
                    if unusedRun >= gap { break }
                }
                index += UInt32(gap)
            }
        }

        usedAddresses = Set(histories.keys)

        // Fetch each transaction once.
        var heights: [String: Int] = [:]
        for entries in histories.values { for e in entries { heights[e.txid] = e.height } }
        let fetched = heights.isEmpty ? [:] : try await backend.transactions(Array(heights.keys))

        var txs: [String: (tx: Transaction, height: Int, verified: Bool)] = [:]
        for (txid, item) in fetched {
            let tx = try Transaction(hex: item.hex)
            guard tx.txid == txid else { throw WalletError.hubMismatch("transaction \(txid) hashes to \(tx.txid)") }
            let height = item.height > 0 ? item.height : max(heights[txid] ?? 0, 0)
            var verified = false
            if height > 0, let headers, let header = headers.header(at: height) {
                guard let branch = item.merkleBranch, let position = item.merklePosition,
                      MerkleProof.verify(txid: txid, branch: branch, position: position, merkleRoot: header.merkleRoot) else {
                    throw WalletError.merkleProofFailed(txid: txid)
                }
                verified = true
            }
            txs[txid] = (tx, height, verified)
        }

        // Outputs paying us, minus those any of our transactions spend.
        var outputs: [String: UTXO] = [:]
        for (txid, entry) in txs {
            for (vout, output) in entry.tx.outputs.enumerated() {
                guard let address = LBCAddress.address(for: output.script), known[address] != nil else { continue }
                outputs["\(txid):\(vout)"] = UTXO(txid: txid, vout: UInt32(vout), value: output.value,
                                                  script: output.script, address: address, height: entry.height)
            }
        }
        var unspent = outputs
        for entry in txs.values {
            for input in entry.tx.inputs { unspent.removeValue(forKey: "\(input.txid):\(input.vout)") }
        }

        let activity: [WalletSnapshot.Activity] = txs.map { txid, entry in
            let received = entry.tx.outputs.enumerated().reduce(Int64(0)) { sum, item in
                outputs["\(txid):\(item.offset)"].map { sum + Int64($0.value) } ?? sum
            }
            let spent = entry.tx.inputs.reduce(Int64(0)) { sum, input in
                outputs["\(input.txid):\(input.vout)"].map { sum + Int64($0.value) } ?? sum
            }
            let supported = entry.tx.outputs.filter { Script.isClaimOrSupport($0.script) }.reduce(UInt64(0)) { $0 + $1.value }
            return .init(txid: txid, height: entry.height, net: received - spent,
                         supported: spent > 0 ? supported : 0, verified: entry.verified)
        }
        .sorted { ($0.height <= 0 ? Int.max : $0.height, $0.txid) > ($1.height <= 0 ? Int.max : $1.height, $1.txid) }

        let coins = Array(unspent.values)
        let receive = try firstUnusedReceive ?? account.address(.receive, UInt32(histories.count))
        let snap = WalletSnapshot(
            spendable: coins.filter { !Script.isClaimOrSupport($0.script) },
            supports: coins.filter { Script.isClaimOrSupport($0.script) },
            activity: activity,
            receiveAddress: receive.address,
            usedAddressCount: histories.count
        )
        snapshot = snap
        return snap
    }

    // MARK: Building

    public struct Prepared: Sendable {
        public let transaction: Transaction
        public let fee: UInt64
        public let amount: UInt64
    }

    /// Plain send to an LBC address.
    public func prepareSend(to address: String, amount: UInt64) throws -> Prepared {
        try prepare(recipient: .init(script: try LBCAddress.script(for: address), value: amount))
    }

    /// Tip a claim: a support output paying the claim's owner (`ownerAddress`, the
    /// address on the claim or its channel), so it shows as a tip on their content.
    public func prepareTip(claimName: String, claimID: String, ownerAddress: String, amount: UInt64) throws -> Prepared {
        let script = try Script.support(name: claimName, claimID: claimID, payee: try LBCAddress.script(for: ownerAddress))
        return try prepare(recipient: .init(script: script, value: amount))
    }

    /// Support a claim with your own LBC (you keep it and can withdraw later).
    public func prepareSupport(claimName: String, claimID: String, amount: UInt64) throws -> Prepared {
        let me = try account.address(.receive, 0).address
        let script = try Script.support(name: claimName, claimID: claimID, payee: try LBCAddress.script(for: me))
        return try prepare(recipient: .init(script: script, value: amount))
    }

    private func prepare(recipient: TxBuilder.Recipient) throws -> Prepared {
        guard account.canSign else { throw WalletError.watchOnly }
        let coins = snapshot?.spendable ?? []
        let change = try account.address(.change, nextChangeIndex())
        let changeScript = try LBCAddress.script(for: change.address)
        let selection = try TxBuilder.selectCoins(coins, recipients: [recipient], changeScript: changeScript, feePerByte: feePerByte)
        let unsigned = TxBuilder.assemble(inputs: selection.inputs, recipients: [recipient],
                                          change: .init(script: changeScript, value: selection.change))
        let signed = try TxBuilder.sign(unsigned, spending: selection.inputs) { utxo in
            guard let address = known[utxo.address] else { throw WalletError.unknownAddress(utxo.address) }
            return try account.privateKey(for: address)
        }
        return Prepared(transaction: signed, fee: selection.fee, amount: recipient.value)
    }

    /// First change address with no history (reusing addresses hurts privacy).
    private func nextChangeIndex() -> UInt32 {
        var i: UInt32 = 0
        while i < 10_000, let a = try? account.address(.change, i), usedAddresses.contains(a.address) { i += 1 }
        return i
    }

    /// Addresses that have any history, from the last scan.
    private var usedAddresses: Set<String> = []

    // MARK: Broadcasting

    /// Broadcasts and returns the txid; refuses if the hub reports a different id.
    public func broadcast(_ prepared: Prepared) async throws -> String {
        let reported = try await backend.broadcast(prepared.transaction.hex)
        let txid = prepared.transaction.txid
        if !reported.isEmpty, reported != txid { throw WalletError.hubMismatch("hub reported \(reported) for \(txid)") }
        return txid
    }
}
