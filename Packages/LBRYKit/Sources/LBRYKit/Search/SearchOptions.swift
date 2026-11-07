import Foundation

/// Sort, upload date and length for a text search.
public struct SearchOptions: Hashable, Sendable {

    public enum Sort: String, CaseIterable, Sendable {
        /// Lighthouse's own ranking.
        case relevance
        case newest
        /// Most LBC staked on the claim.
        case mostSupported
    }

    public enum Uploaded: String, CaseIterable, Sendable {
        case any, today, thisWeek, thisMonth, thisYear
    }

    public enum Length: String, CaseIterable, Sendable {
        case any
        /// Up to `shortMaxSeconds`: the same cutoff as the Shorts tab.
        case short
        /// At least `longMinSeconds`.
        case long
    }

    public static let shortMaxSeconds = 180
    public static let longMinSeconds = 20 * 60

    public var sort: Sort
    public var uploaded: Uploaded
    public var length: Length

    public init(sort: Sort = .relevance, uploaded: Uploaded = .any, length: Length = .any) {
        self.sort = sort
        self.uploaded = uploaded
        self.length = length
    }
}

/// One Lighthouse request's parameters.
///
/// Lighthouse rejects parameters it doesn't know ("Extraneous params", HTTP 400),
/// so only ones checked against lighthouse.odysee.tv are used; see docs/SEARCH.md.
/// Every request sends `nsfw=false`, so mature claims are left out on the server
/// rather than dropped on the device (which left pages short).
public struct LighthouseQuery: Hashable, Sendable {
    public private(set) var parameters: [String: String]

    /// Videos matching `text`, optionally only from one channel.
    public static func videos(
        _ text: String, options: SearchOptions = SearchOptions(), size: Int, from: Int, channelID: String? = nil
    ) -> Self {
        var p = base(text, size: size, from: from)
        p["mediaType"] = "video"
        switch options.sort {
        case .relevance: break
        case .newest: p["sort_by"] = "release_time"
        case .mostSupported: p["sort_by"] = "effective_amount"
        }
        switch options.uploaded {
        case .any: break
        case .today: p["time_filter"] = "today"
        case .thisWeek: p["time_filter"] = "thisweek"
        case .thisMonth: p["time_filter"] = "thismonth"
        case .thisYear: p["time_filter"] = "thisyear"
        }
        switch options.length {
        case .any: break
        case .short: p["max_duration"] = String(SearchOptions.shortMaxSeconds)
        case .long: p["min_duration"] = String(SearchOptions.longMinSeconds)
        }
        if let channelID { p["channel_id"] = channelID }
        return Self(parameters: p)
    }

    /// Channels matching `text`.
    public static func channels(_ text: String, size: Int, from: Int = 0) -> Self {
        var p = base(text, size: size, from: from)
        p["claimType"] = "channel"
        return Self(parameters: p)
    }

    private static func base(_ text: String, size: Int, from: Int) -> [String: String] {
        ["s": text, "size": String(size), "from": String(from), "nsfw": "false"]
    }

    /// The request URL, parameters in a fixed order. Values are fully percent-encoded
    /// (URLQueryItem leaves `+` alone, which servers read as a space: "c++" → "c  ").
    public func url(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "")" }
            .joined(separator: "&")
        return components.url!
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}
