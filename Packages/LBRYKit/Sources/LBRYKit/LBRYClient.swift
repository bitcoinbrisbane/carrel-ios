import Foundation

/// Thin JSON-RPC client for an `lbrynet` daemon (or a proxy in front of one,
/// such as Odysee's). Every protocol call goes through `call(_:params:)`.
public actor LBRYClient {

    public enum Endpoint {
        /// Odysee's public SDK proxy. Fine for prototyping; swap for our own node.
        public static let odyseeProxy = URL(string: "https://api.na-backend.odysee.com/api/v1/proxy")!
        /// Odysee's Lighthouse full-text search (claim_search has no text search).
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

    /// Full-text search via Lighthouse, then resolve the hits into claims.
    public func search(_ text: String, size: Int = 20, from: Int = 0) async throws -> [Claim] {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "s", value: text),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "mediaType", value: "video"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Self.checkHTTP(response)
        let hits = try decoder.decode([LighthouseHit].self, from: data)
        let urls = hits.map { "lbry://\($0.name)#\($0.claimId)" }
        guard !urls.isEmpty else { return [] }
        let resolved = try await resolve(urls)
        return urls.compactMap { resolved[$0] }   // keep Lighthouse's ranking order
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

struct LighthouseHit: Decodable {
    let name: String
    let claimId: String
}
