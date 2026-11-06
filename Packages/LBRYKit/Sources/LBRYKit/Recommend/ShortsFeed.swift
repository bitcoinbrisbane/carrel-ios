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
        return ranker.rank(filter.apply(candidates), taste: taste, now: now)
    }
}
