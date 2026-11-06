import Foundation

/// Client for lbc.exchange, the LBC ⇄ wLBC bridge (github.com/bitcoinbrisbane/lbry.exchange).
///
/// Wrap: ask for this wallet's LBC deposit address, check the bridge signed it,
/// send LBC there, watch it confirm, then mint wLBC with `Bridge.wrap`.
/// Unwrap: `Bridge.unwrap(amount, lbcAddress)` from the Ethereum wallet.
public struct LBCBridge: Sendable {

    public static let defaultAPI = URL(string: "https://faas-syd1-c274eac6.doserverless.co/api/v1/web/fn-c50fc3e2-222d-4f13-ab7e-6eca05bd715d/bridge")!
    public static let bridgeContract = "0xa3A3E8304C88b017153bA5dFCCDACCB7116a185f"
    public static let website = URL(string: "https://lbc.exchange")!

    public let api: URL
    public let bridgeAddress: String
    public let chainID: Int
    private let session: URLSession

    public init(api: URL = LBCBridge.defaultAPI, bridgeAddress: String = LBCBridge.bridgeContract,
                chainID: Int = 1, session: URLSession = .shared) {
        self.api = api
        self.bridgeAddress = bridgeAddress
        self.chainID = chainID
        self.session = session
    }

    public enum BridgeError: Error, Equatable, LocalizedError {
        case http(Int, String?)
        case badResponse
        case untrustedAddress(String)

        public var errorDescription: String? {
            switch self {
            case .http(_, let message?): return message
            case .http(let code, nil): return "The bridge returned an error (\(code))."
            case .badResponse: return "The bridge sent something unexpected."
            case .untrustedAddress(let why): return "Carrel couldn't verify the bridge's deposit address: \(why)"
            }
        }
    }

    // MARK: Deposit address

    public struct DepositOffer: Sendable, Equatable {
        public let depositAddress: String
        public let ethAddress: String
        public let minConfirmations: Int
        public let message: String
        public let signature: String
        public let signer: String
    }

    /// This wallet's next LBC deposit address, signed by the bridge.
    public func depositOffer(for ethAddress: String) async throws -> DepositOffer {
        let json = try await get("wrap", ["ethAddress": ethAddress])
        guard let deposit = json["depositAddress"] as? String,
              let message = json["message"] as? String,
              let signature = json["signature"] as? String,
              let signer = json["signer"] as? String else { throw BridgeError.badResponse }
        return DepositOffer(depositAddress: deposit, ethAddress: ethAddress,
                            minConfirmations: json["minConfirmations"] as? Int ?? 6,
                            message: message, signature: signature, signer: signer)
    }

    /// The statement the bridge signs for a deposit address (mirrors `depositAddressMessage`).
    public func expectedMessage(depositAddress: String, ethAddress: String) -> String {
        [
            "lbry.exchange deposit address",
            "LBC address: \(depositAddress)",
            "Mints wLBC to: \(EthereumAddress.checksummed(ethAddress))",
            "Bridge: \(EthereumAddress.checksummed(bridgeAddress))",
            "Chain: \(chainID)",
        ].joined(separator: "\n")
    }

    /// Only trust a deposit address if the signed statement is the one we expect,
    /// for our own Ethereum address, and was signed by the key the contract names
    /// (`onChainSigner`, read from `Bridge.signer()` on Ethereum, not from the API).
    public func verify(_ offer: DepositOffer, onChainSigner: String) throws {
        guard LBCAddress.isValid(offer.depositAddress) else {
            throw BridgeError.untrustedAddress("not an LBC address")
        }
        guard offer.message == expectedMessage(depositAddress: offer.depositAddress, ethAddress: offer.ethAddress) else {
            throw BridgeError.untrustedAddress("the signed statement doesn't match")
        }
        guard let recovered = PersonalMessage.signer(of: offer.message, signature: offer.signature) else {
            throw BridgeError.untrustedAddress("bad signature")
        }
        guard recovered.lowercased() == onChainSigner.lowercased() else {
            throw BridgeError.untrustedAddress("signed by \(recovered), but the bridge contract's signer is \(onChainSigner)")
        }
    }

    // MARK: Status

    public struct Deposit: Sendable, Equatable, Identifiable {
        public enum Status: String, Sendable { case pending, ready, minted }
        public let lbcTxid: String
        public let depositAddress: String
        public let amount: UInt64
        public let confirmations: Int
        public let status: Status
        public var id: String { lbcTxid }
    }

    public func deposits(for ethAddress: String) async throws -> [Deposit] {
        let json = try await get("status", ["ethAddress": ethAddress])
        guard let list = json["deposits"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let txid = d["lbcTxid"] as? String, let address = d["depositAddress"] as? String else { return nil }
            let amount = (d["amount"] as? String).flatMap(UInt64.init) ?? (d["amount"] as? NSNumber)?.uint64Value ?? 0
            return Deposit(lbcTxid: txid, depositAddress: address, amount: amount,
                           confirmations: d["confirmations"] as? Int ?? 0,
                           status: Deposit.Status(rawValue: d["status"] as? String ?? "") ?? .pending)
        }
    }

    // MARK: HTTP

    func get(_ function: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: api.appendingPathComponent(function), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await send(URLRequest(url: components.url!))
    }

    func post(_ function: String, _ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: api.appendingPathComponent(function))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BridgeError.http(http.statusCode, json?["error"] as? String)
        }
        guard let json else { throw BridgeError.badResponse }
        return json
    }
}
