import Foundation

public enum EthereumRPCError: Error, Equatable {
    case http(Int)
    case rpc(String)
    case badResponse(String)
}

/// Minimal read-only Ethereum JSON-RPC client.
public actor EthereumRPC {

    /// The same public endpoint lbc.exchange reads from.
    public static let defaultURL = URL(string: "https://ethereum-rpc.publicnode.com")!

    public let url: URL
    private let session: URLSession
    private var nextID = 1

    public init(url: URL = EthereumRPC.defaultURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func call(_ method: String, _ params: [Any]) async throws -> Any {
        let id = nextID
        nextID += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EthereumRPCError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EthereumRPCError.badResponse(method)
        }
        if let error = object["error"] as? [String: Any] {
            throw EthereumRPCError.rpc(error["message"] as? String ?? "\(error)")
        }
        guard let result = object["result"] else { throw EthereumRPCError.badResponse(method) }
        return result
    }

    /// `eth_call` at the latest block; returns the raw hex result.
    public func ethCall(to: String, data: String) async throws -> String {
        guard let hex = try await call("eth_call", [["to": to, "data": data], "latest"]) as? String else {
            throw EthereumRPCError.badResponse("eth_call")
        }
        return hex
    }

    public func ethBalance(of address: String) async throws -> TokenAmount {
        guard let hex = try await call("eth_getBalance", [address, "latest"]) as? String,
              let amount = TokenAmount(hex: hex, decimals: 18) else { throw EthereumRPCError.badResponse("eth_getBalance") }
        return amount
    }

    public func tokenBalance(_ token: ERC20Token, of address: String) async throws -> TokenAmount {
        guard let owner = EthereumAddress.bytes(address) else { throw EthereumRPCError.badResponse("bad address") }
        let data = "0x" + ABI.selector("balanceOf(address)").hex + ABI.word(address: owner).hex
        let hex = try await ethCall(to: token.contract, data: data)
        guard let amount = TokenAmount(hex: hex == "0x" ? "0x0" : hex, decimals: token.decimals) else {
            throw EthereumRPCError.badResponse("balanceOf")
        }
        return amount
    }

    /// Reads an `address` returned by a no-argument view function (e.g. `signer()`).
    public func readAddress(contract: String, function: String) async throws -> String {
        let hex = try await ethCall(to: contract, data: "0x" + ABI.selector(function).hex)
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard body.count >= 64 else { throw EthereumRPCError.badResponse(function) }
        return EthereumAddress.checksummed(String(body.suffix(40)))
    }
}

/// The few ABI pieces read-only calls need.
public enum ABI {
    public static func selector(_ signature: String) -> [UInt8] {
        Array(Keccak256.hash(signature).prefix(4))
    }

    static func word(address: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + address
    }
}

/// ETH plus token balances for one address, fetched together.
public struct EthereumBalances: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let symbol: String
        public let name: String
        public let amount: TokenAmount?
        public var id: String { symbol }
    }

    public let address: String
    public let rows: [Row]

    public static func fetch(for address: String, tokens: [ERC20Token] = ERC20Token.mainnetDefaults,
                             rpc: EthereumRPC) async -> EthereumBalances {
        async let eth = try? rpc.ethBalance(of: address)
        var tokenRows: [Row] = []
        await withTaskGroup(of: (Int, Row).self) { group in
            for (i, token) in tokens.enumerated() {
                group.addTask {
                    (i, Row(symbol: token.symbol, name: token.name, amount: try? await rpc.tokenBalance(token, of: address)))
                }
            }
            var collected: [(Int, Row)] = []
            for await item in group { collected.append(item) }
            tokenRows = collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let ethRow = Row(symbol: "ETH", name: "Ether", amount: await eth)
        return EthereumBalances(address: address, rows: [ethRow] + tokenRows)
    }
}
