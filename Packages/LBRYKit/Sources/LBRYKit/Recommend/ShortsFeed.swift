import Foundation

/// Builds the Shorts feed: gathers candidates from a few `claim_search` queries
/// shaped by the viewer's taste, then ranks them locally with `FeedRanker`.
/// The queries reveal only broad interests (top tags/channels) to the server;
/// the profile itself never leaves the device.
public struct ShortsFeed: Sendable {

    public var maxDuration = 180          // seconds; "short" = 3 minutes or less
    public var pageSize = 20
    public var ranker = FeedRanker()

    public init() {}

    /// The server filter (`duration <=180`) is honoured by the hubs, but a video with
    /// no duration in its metadata is indexed as 0 and slips through, so check here too:
    /// a known length of 1–180 seconds.
    public func isShort(_ claim: Claim) -> Bool {
        guard let seconds = claim.duration else { return false }
        return (1...maxDuration).contains(seconds)
    }

    /// Candidate queries for one page of feed.
    public func queries(for taste: TasteProfile, page: Int, blockedTags: [String]) -> [ClaimSearchParams] {
        var base = ClaimSearchParams()
        base.duration = "<=\(maxDuration)"
        base.notTags = blockedTags + taste.mutedTopics.sorted()
        base.page = page
        base.pageSize = pageSize

        var trending = base
        trending.orderBy = ["trending_group", "trending_mixed"]

        var queries = [trending]

        let channels = taste.topChannels(5).map { $0.id }
        if !channels.isEmpty {
            var fromChannels = base
            fromChannels.channelIDs = channels
            fromChannels.orderBy = ["release_time"]
            queries.append(fromChannels)
        }

        let tags = taste.topTopics(3).map { $0.tag }
        if !tags.isEmpty {
            var byTopic = base
            byTopic.anyTags = tags
            byTopic.orderBy = ["release_time"]
            queries.append(byTopic)
        }
        return queries
    }

    // MARK: Following

    /// Short videos from followed channels, newest first. Nil when nothing is followed.
    public func followingQuery(library: UserLibrary, taste: TasteProfile, page: Int, blockedTags: [String]) -> ClaimSearchParams? {
        let channels = library.followedChannelIDs.filter { !taste.mutedChannels.contains($0) }
        guard !channels.isEmpty else { return nil }
        var q = ClaimSearchParams()
        q.channelIDs = Array(channels.prefix(50))
        q.duration = "<=\(maxDuration)"
        q.notTags = blockedTags + taste.mutedTopics.sorted()
        q.orderBy = ["release_time"]
        q.page = page
        q.pageSize = pageSize
        return q
    }

    /// The Following timeline: newest first, mutes respected, and (unlike For you)
    /// clips already seen stay in, because this is a timeline rather than a recommendation.
    public func followingTimeline(_ claims: [Claim], taste: TasteProfile, filter: ContentFilter) -> [RankedClaim] {
        var seen = Set<String>()
        return filter.apply(claims)
            .filter { claim in
                guard isShort(claim), seen.insert(claim.claimId).inserted else { return false }
                if let channel = claim.signingChannel, taste.mutedChannels.contains(channel.claimId) { return false }
                return !TasteProfile.tags(of: claim).contains { taste.mutedTopics.contains($0) }
            }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
            .map { RankedClaim(claim: $0, score: 0, reason: .following($0.signingChannel?.name ?? "this channel")) }
    }

    public func loadFollowing(
        page: Int, library: UserLibrary, taste: TasteProfile, filter: ContentFilter, client: LBRYClient
    ) async throws -> [RankedClaim] {
        guard let query = followingQuery(library: library, taste: taste, page: page, blockedTags: Array(filter.blockedTags)) else {
            return []
        }
        return followingTimeline(try await client.claimSearch(query).items, taste: taste, filter: filter)
    }

    /// Fetch and rank one page. Failed queries are skipped; throws only if all fail.
    public func load(
        page: Int,
        taste: TasteProfile,
        filter: ContentFilter,
        client: LBRYClient,
        now: Date = Date()
    ) async throws -> [RankedClaim] {
        let queries = queries(for: taste, page: page, blockedTags: Array(filter.blockedTags))
        var candidates: [Claim] = []
        var lastError: Error?

        try await withThrowingTaskGroup(of: [Claim]?.self) { group in
            for query in queries {
                group.addTask {
                    do { return try await client.claimSearch(query).items } catch { return nil }
                }
            }
            for try await result in group {
                if let result { candidates += result } else { lastError = LBRYError.emptyResult("claim_search") }
            }
        }
        if candidates.isEmpty, let lastError { throw lastError }
        return ranker.rank(filter.apply(candidates).filter(isShort), taste: taste, now: now)
    }
}
