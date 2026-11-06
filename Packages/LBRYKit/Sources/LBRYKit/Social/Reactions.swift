import Foundation

/// Public like / dislike counts for a claim, as Odysee shows them.
public struct ReactionCounts: Sendable, Equatable, Codable {
    public let likes: Int
    public let dislikes: Int

    public init(likes: Int, dislikes: Int) {
        self.likes = likes
        self.dislikes = dislikes
    }

    /// "842", "1.2k", "3.4M".
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return trimmed(Double(n) / 1_000) + "k"
        default: return trimmed(Double(n) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ v: Double) -> String {
        let s = v >= 100 ? String(Int(v)) : String(format: "%.1f", (v * 10).rounded(.down) / 10)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

/// Reads public reaction counts from Odysee's API (`reaction/list`), the same
/// call odysee.com makes. Read-only: Carrel likes stay private taste signals.
///
/// Requests are batched and cached for a few minutes. If Odysee asks for an
/// auth token, an anonymous one is requested once (`user/new`) and kept via
/// `tokenStore`, as odysee.com does for signed-out visitors.
public actor OdyseeReactions {

    public static let defaultAPI = URL(string: "https://api.odysee.com")!

    public struct TokenStore: Sendable {
        public let load: @Sendable () -> String?
        public let save: @Sendable (String) -> Void
        public init(load: @escaping @Sendable () -> String?, save: @escaping @Sendable (String) -> Void) {
            self.load = load
            self.save = save
        }
        public static let inMemory: TokenStore = {
            final class Box: @unchecked Sendable { var token: String? }
            let box = Box()
            return TokenStore(load: { box.token }, save: { box.token = $0 })
        }()
    }

    public enum ReactionError: Error, Equatable {
        case http(Int)
        case api(String)
        case badResponse
    }

    private let api: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private let ttl: TimeInterval
    private var cache: [String: (counts: ReactionCounts, at: Date)] = [:]

    public init(api: URL = OdyseeReactions.defaultAPI, session: URLSession = .shared,
                tokenStore: TokenStore = .inMemory, ttl: TimeInterval = 300) {
        self.api = api
        self.session = session
        self.tokenStore = tokenStore
        self.ttl = ttl
    }

    /// Counts for the given claims; claims that fail or aren't known are simply absent.
    public func counts(for claimIDs: [String], now: Date = Date()) async -> [String: ReactionCounts] {
        var result: [String: ReactionCounts] = [:]
        var missing: [String] = []
        for id in Set(claimIDs) {
            if let hit = cache[id], now.timeIntervalSince(hit.at) < ttl { result[id] = hit.counts } else { missing.append(id) }
        }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let batch = Array(missing[start..<min(start + 50, missing.count)])
            guard let fetched = try? await fetch(batch) else { continue }
            for (id, counts) in fetched {
                result[id] = counts
                cache[id] = (counts, now)
            }
        }
        return result
    }

    public func counts(for claimID: String) async -> ReactionCounts? {
        await counts(for: [claimID])[claimID]
    }

    // MARK: Requests

    private func fetch(_ claimIDs: [String]) async throws -> [String: ReactionCounts] {
        var params = ["claim_ids": claimIDs.joined(separator: ",")]
        if let token = tokenStore.load() { params["auth_token"] = token }
        do {
            return try Self.parseList(try await post("reaction/list", params))
        } catch ReactionError.api(let message) where params["auth_token"] == nil && Self.looksLikeAuthError(message) {
            params["auth_token"] = try await anonymousToken()
            return try Self.parseList(try await post("reaction/list", params))
        }
    }

    private func anonymousToken() async throws -> String {
        let data = try await post("user/new", ["auth_token": "", "language": "en", "app_id": "carrel-ios-" + UUID().uuidString])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object["data"] as? [String: Any],
              let token = inner["auth_token"] as? String, !token.isEmpty else { throw ReactionError.badResponse }
        tokenStore.save(token)
        return token
    }

    private func post(_ path: String, _ params: [String: String]) async throws -> Data {
        var request = URLRequest(url: api.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        // Lbryio answers errors with a JSON body even on 4xx, so read that first.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["success"] as? Bool == false {
            throw ReactionError.api(object["error"] as? String ?? "request failed")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReactionError.http(http.statusCode)
        }
        return data
    }

    // MARK: Parsing

    /// `{"success": true, "data": {"others_reactions": {"<id>": {"like": n, "dislike": n}}, "my_reactions": {...}}}`
    static func parseList(_ data: Data) throws -> [String: ReactionCounts] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReactionError.badResponse }
        if object["success"] as? Bool == false { throw ReactionError.api(object["error"] as? String ?? "") }
        guard let inner = object["data"] as? [String: Any] else { throw ReactionError.badResponse }
        let others = inner["others_reactions"] as? [String: Any] ?? [:]
        var out: [String: ReactionCounts] = [:]
        for (id, value) in others {
            guard let counts = value as? [String: Any] else { continue }
            func int(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? Int(counts[key] as? String ?? "") ?? 0 }
            out[id] = ReactionCounts(likes: int("like"), dislikes: int("dislike"))
        }
        return out
    }

    static func looksLikeAuthError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("auth") || m.contains("token") || m.contains("user") || m.contains("logged")
    }
}
