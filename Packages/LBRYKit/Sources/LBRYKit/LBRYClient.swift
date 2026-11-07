import Foundation

/// Thin JSON-RPC client for an `lbrynet` daemon (or a proxy in front of one,
/// such as Odysee's). Every protocol call goes through `call(_:params:)`.
public actor LBRYClient {

    public enum Endpoint {
        /// Odysee's public SDK proxy. Fine for prototyping; swap for our own node.
        public static let odyseeProxy = URL(string: "https://api.na-backend.odysee.com/api/v1/proxy")!
        /// Odysee's Lighthouse full-text search. (claim_search takes `text` too, but ranks
        /// poorly and returns unlisted claims; see docs/SEARCH.md.)
        public static let odyseeLighthouse = URL(string: "https://lighthouse.odysee.tv/search")!
    }

    public let rpcURL: URL
    public let searchURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private var nextID = 1

    public init(
        rpcURL: URL = Endpoint.odyseeProxy,
        searchURL: URL = Endpoint.odyseeLighthouse,
        session: URLSession = .shared
    ) {
        self.rpcURL = rpcURL
        self.searchURL = searchURL
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Protocol calls

    /// Resolve one or more `lbry://` URLs. URLs that fail to resolve are omitted.
    public func resolve(_ urls: [String]) async throws -> [String: Claim] {
        let raw: [String: ResolveEntry] = try await call("resolve", params: ResolveParams(urls: urls))
        return raw.compactMapValues(\.claim)
    }

    public func resolve(_ url: String) async throws -> Claim? {
        try await resolve([url])[url]
    }

    public func claimSearch(_ params: ClaimSearchParams) async throws -> Page<Claim> {
        try await call("claim_search", params: params)
    }

    /// Ask the daemon for a stream. Returns the HTTP URL AVPlayer can play.
    public func streamingURL(for uri: String) async throws -> URL {
        let info: GetResult = try await call("get", params: GetParams(uri: uri, save_file: false))
        guard let url = info.streaming_url.flatMap(URL.init(string:)) else {
            throw LBRYError.noStreamingURL(uri)
        }
        return url
    }

    /// One page of Lighthouse hits, in its ranking order, before resolving.
    /// `SearchFeed` turns these into claims.
    public func lighthouse(_ query: LighthouseQuery) async throws -> [LighthouseHit] {
        let (data, response) = try await session.data(from: query.url(base: searchURL))
        // A bad request comes back as {"success": false, "error": "Extraneous params: …"}.
        if let failure = try? decoder.decode(LighthouseFailure.self, from: data), let message = failure.error {
            throw LBRYError.search(message)
        }
        try Self.checkHTTP(response)
        return try decoder.decode([LighthouseHit].self, from: data)
    }

    // MARK: - JSON-RPC plumbing

    public func call<P: Encodable, R: Decodable>(_ method: String, params: P) async throws -> R {
        let id = nextID
        nextID += 1

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))

        let (data, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
        let envelope = try decoder.decode(RPCResponse<R>.self, from: data)
        if let error = envelope.error {
            throw LBRYError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            throw LBRYError.emptyResult(method)
        }
        return result
    }

    private static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LBRYError.http(http.statusCode)
        }
    }
}

public enum LBRYError: Error, Equatable {
    case http(Int)
    case rpc(code: Int, message: String)
    case emptyResult(String)
    case noStreamingURL(String)
    /// Lighthouse refused the request (its message).
    case search(String)
}

// MARK: - Wire types

struct RPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

struct RPCResponse<R: Decodable>: Decodable {
    let result: R?
    let error: RPCErrorBody?
}

struct RPCErrorBody: Decodable {
    let code: Int
    let message: String
}

struct ResolveParams: Encodable { let urls: [String] }

struct GetParams: Encodable {
    let uri: String
    let save_file: Bool
}

struct GetResult: Decodable { let streaming_url: String? }

/// `resolve` returns either a claim or `{"error": {...}}` per URL.
struct ResolveEntry: Decodable {
    let claim: Claim?
    init(from decoder: Decoder) throws {
        claim = try? Claim(from: decoder)
    }
}

/// A Lighthouse search hit: enough to resolve the claim, plus its channel's id.
public struct LighthouseHit: Decodable, Hashable, Sendable {
    public let name: String
    public let claimId: String
    /// The signing channel's claim id; nil for channels and anonymous uploads.
    public let channelClaimId: String?

    public var lbryURL: String { "lbry://\(name)#\(claimId)" }

    public init(name: String, claimId: String, channelClaimId: String? = nil) {
        self.name = name
        self.claimId = claimId
        self.channelClaimId = channelClaimId
    }

    enum CodingKeys: String, CodingKey {
        case name, claimId
        case channelClaimId = "channel_claim_id"
    }
}

struct LighthouseFailure: Decodable {
    let success: Bool?
    let error: String?
}
