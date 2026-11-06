import Foundation

/// A claim as returned by `resolve` / `claim_search`. Only the fields the app
/// uses are modelled; everything else in the SDK response is ignored.
public struct Claim: Decodable, Identifiable, Hashable, Sendable {
    public let claimId: String
    public let name: String
    public let canonicalURL: String?
    public let permanentURL: String?
    public let valueType: String?          // "stream", "channel", "collection", "repost"
    public let timestamp: Int?
    public let signingChannel: ChannelRef?
    public let value: ClaimValue?
    /// The address that owns the claim. Tips are support outputs paying this address.
    public var address: String? = nil

    public var id: String { claimId }

    /// Best URL to pass back to the SDK (`get`, `resolve`).
    public var lbryURL: String { canonicalURL ?? permanentURL ?? "lbry://\(name)#\(claimId)" }

    public var title: String { value?.title ?? name }
    public var thumbnailURL: URL? { value?.thumbnail?.url.flatMap(URL.init(string:)) }
    public var duration: Int? { value?.video?.duration ?? value?.audio?.duration }
    public var tags: [String] { value?.tags ?? [] }

    public var releaseDate: Date? {
        if let raw = value?.releaseTime, let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case name
        case canonicalURL = "canonical_url"
        case permanentURL = "permanent_url"
        case valueType = "value_type"
        case timestamp
        case signingChannel = "signing_channel"
        case value
        case address
    }
}

public struct ChannelRef: Decodable, Hashable, Sendable {
    public let claimId: String
    public let name: String
    public let canonicalURL: String?
    public let value: ClaimValue?

    public var title: String { value?.title ?? name }
    public var thumbnailURL: URL? { value?.thumbnail?.url.flatMap(URL.init(string:)) }

    enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case name
        case canonicalURL = "canonical_url"
        case value
    }
}

public struct ClaimValue: Decodable, Hashable, Sendable {
    public let title: String?
    public let description: String?
    public let thumbnail: Media?
    public let cover: Media?
    public let tags: [String]?
    public let releaseTime: String?        // SDK sends this as a string of epoch seconds
    public let streamType: String?
    public let video: AV?
    public let audio: AV?
    public let source: Source?

    public struct Media: Decodable, Hashable, Sendable { public let url: String? }
    public struct AV: Decodable, Hashable, Sendable { public let duration: Int? }
    public struct Source: Decodable, Hashable, Sendable {
        public let sdHash: String?
        public let mediaType: String?
        enum CodingKeys: String, CodingKey {
            case sdHash = "sd_hash"
            case mediaType = "media_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, description, thumbnail, cover, tags, video, audio, source
        case releaseTime = "release_time"
        case streamType = "stream_type"
    }
}

public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let page: Int
    public let pageSize: Int
    public let totalPages: Int?
    public let totalItems: Int?

    enum CodingKeys: String, CodingKey {
        case items, page
        case pageSize = "page_size"
        case totalPages = "total_pages"
        case totalItems = "total_items"
    }
}

/// Subset of `claim_search` parameters. Nil fields are omitted from the request.
public struct ClaimSearchParams: Encodable, Sendable {
    public var claimType: [String]? = ["stream"]
    public var streamTypes: [String]? = ["video"]
    public var channelIDs: [String]?
    public var anyTags: [String]?
    public var notTags: [String]?
    public var orderBy: [String]? = ["trending_group", "trending_mixed"]
    public var hasSource: Bool? = true
    /// Duration filter in seconds with an optional operator, e.g. "<=180".
    public var duration: String?
    public var page: Int = 1
    public var pageSize: Int = 20

    public init() {}

    public static func trending(page: Int = 1, notTags: [String] = ContentFilter.defaultBlockedTags) -> Self {
        var p = Self()
        p.page = page
        p.notTags = notTags
        return p
    }

    public static func latest(fromChannels ids: [String], page: Int = 1) -> Self {
        var p = Self()
        p.channelIDs = ids
        p.orderBy = ["release_time"]
        p.page = page
        return p
    }

    enum CodingKeys: String, CodingKey {
        case claimType = "claim_type"
        case streamTypes = "stream_types"
        case channelIDs = "channel_ids"
        case anyTags = "any_tags"
        case notTags = "not_tags"
        case orderBy = "order_by"
        case hasSource = "has_source"
        case duration
        case page
        case pageSize = "page_size"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claimType, forKey: .claimType)
        try c.encodeIfPresent(streamTypes, forKey: .streamTypes)
        try c.encodeIfPresent(channelIDs, forKey: .channelIDs)
        try c.encodeIfPresent(anyTags, forKey: .anyTags)
        try c.encodeIfPresent(notTags, forKey: .notTags)
        try c.encodeIfPresent(orderBy, forKey: .orderBy)
        try c.encodeIfPresent(hasSource, forKey: .hasSource)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(page, forKey: .page)
        try c.encode(pageSize, forKey: .pageSize)
    }
}
