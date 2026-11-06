import Foundation

/// Minting (LBC → wLBC) and unwrapping (wLBC → LBC) with lbc.exchange.
extension LBCBridge {

    // MARK: Mint

    /// Arguments for `Bridge.wrap`, as the bridge's `wrapArgs` returns them.
    public struct WrapArgs: Sendable, Equatable, Decodable {
        public let to: String
        /// wLBC base units (8 decimals, so the same number as dewies), as a decimal string.
        public let amount: String
        /// The LBC txid as bytes32 ("0x…").
        public let lbcTxid: String
        /// The bridge signer's personal-sign over `wrapMessageHash`.
        public let signature: String

        public init(to: String, amount: String, lbcTxid: String, signature: String) {
            self.to = to
            self.amount = amount
            self.lbcTxid = lbcTxid
            self.signature = signature
        }

        public var dewies: UInt64 { UInt64(amount) ?? 0 }
    }

    public enum MintApproval: Sendable, Equatable {
        case approved(WrapArgs)
        case waiting(confirmations: Int, required: Int)
        case alreadyMinted
    }

    /// `POST wrap {ethAddress, lbcTxid}`: a signed approval once the deposit has enough
    /// LBC confirmations.
    public func mintApproval(ethAddress: String, lbcTxid: String) async throws -> MintApproval {
        let json: [String: Any]
        do {
            json = try await post("wrap", ["ethAddress": ethAddress, "lbcTxid": lbcTxid])
        } catch BridgeError.http(409, _) {
            return .alreadyMinted
        }
        if let args = json["wrapArgs"] as? [String: Any],
           let to = args["to"] as? String, let lbcTxid = args["lbcTxid"] as? String,
           let signature = args["signature"] as? String,
           let amount = (args["amount"] as? String) ?? (args["amount"] as? NSNumber)?.stringValue {
            return .approved(WrapArgs(to: to, amount: amount, lbcTxid: lbcTxid, signature: signature))
        }
        if json["status"] as? String == "pending" {
            return .waiting(confirmations: json["confirmations"] as? Int ?? 0,
                            required: json["minConfirmations"] as? Int ?? 6)
        }
        throw BridgeError.badResponse
    }

    /// `keccak256(abi.encodePacked(chainid, bridge, to, amount, lbcTxid))`, as `Bridge.wrapMessageHash`.
    public func wrapMessageHash(_ args: WrapArgs) throws -> [UInt8] {
        guard let bridge = EthereumAddress.bytes(bridgeAddress), let to = EthereumAddress.bytes(args.to),
              let amount = UInt256(decimal: args.amount),
              let txid = [UInt8](hex: args.lbcTxid.replacingOccurrences(of: "0x", with: "").lowercased()), txid.count == 32
        else { throw BridgeError.badResponse }
        return Keccak256.hash(UInt256(UInt64(chainID)).bigEndian32 + bridge + to + amount.bigEndian32 + txid)
    }

    /// Check an approval before spending gas on it: it mints to us, and the contract's
    /// signer (read from Ethereum, not the API) signed exactly these arguments.
    public func verify(_ args: WrapArgs, ethAddress: String, onChainSigner: String) throws {
        guard args.to.lowercased() == ethAddress.lowercased() else {
            throw BridgeError.untrustedAddress("the approval mints to \(args.to), not this wallet")
        }
        let digest = try wrapMessageHash(args)
        guard let recovered = PersonalMessage.signer(ofBytes: digest, signature: args.signature),
              recovered.lowercased() == onChainSigner.lowercased() else {
            throw BridgeError.untrustedAddress("the mint approval isn't signed by the bridge contract's signer")
        }
    }

    // MARK: Unwrap

    public struct UnwrapStatus: Sendable, Equatable {
        public enum State: String, Sendable { case pending, ready, paid, reverted, notFound = "not_found", noEvent = "no_unwrap_event", failed }
        public let state: State
        public let confirmations: Int
        public let required: Int
        /// LBC payout txids, once sent.
        public let payoutTxids: [String]
        /// Why the bridge couldn't pay, when `state == .failed`.
        public var error: String? = nil
    }

    /// `POST unwrap {burnTxid}`: asks the bridge to pay the LBC (it waits for 12 Ethereum
    /// confirmations, and never pays the same burn twice, so calling again is safe).
    public func requestPayout(burnTxid: String) async throws -> UnwrapStatus {
        Self.unwrapStatus(from: try await post("unwrap", ["burnTxid": burnTxid]))
    }

    /// `GET status?burnTxid=`.
    public func unwrapStatus(burnTxid: String) async throws -> UnwrapStatus {
        Self.unwrapStatus(from: try await get("status", ["burnTxid": burnTxid]))
    }

    static func unwrapStatus(from json: [String: Any]) -> UnwrapStatus {
        let payouts = json["payouts"] as? [[String: Any]] ?? []
        let payoutStates = payouts.map { $0["status"] as? String ?? "" }
        let state: UnwrapStatus.State
        if payoutStates.contains(where: { $0 == "invalid_address" || $0 == "below_dust" }) {
            state = .failed     // the bridge can't pay this one; the error says why
        } else if let s = UnwrapStatus.State(rawValue: json["status"] as? String ?? "") {
            state = s
        } else {
            state = payouts.isEmpty ? .pending : payoutStates.allSatisfy { $0 == "paid" } ? .paid : .ready
        }
        return UnwrapStatus(state: state,
                            confirmations: json["confirmations"] as? Int ?? 0,
                            required: (json["minConfirmations"] as? Int) ?? (json["required"] as? Int) ?? 12,
                            payoutTxids: payouts.compactMap { $0["lbcTxid"] as? String },
                            error: payouts.compactMap { $0["error"] as? String }.first)
    }
}
