import Foundation

/// Search results for both apps (docs/SEARCH.md): a row of channels, videos from
/// channels the viewer follows, then everything else in Lighthouse's order, a page
/// at a time.
///
/// Lighthouse finds; the SDK's `resolve` fills in the claims. Muted and blocked
/// channels are dropped before resolving (each hit carries its channel id, so no
/// resolve is spent on them), the content filter and muted topics after. Nothing is
/// re-ranked: search should be predictable, and taste only decides what's left out.
public struct SearchFeed: Sendable {
    /// Lighthouse hits per page.
    public var pageSize = 20
    /// Channels in the row above a text search's videos.
    public var channelRowLimit = 5
    /// Channels for an `@name` search, where they're the whole result.
    public var channelListLimit = 20
    /// When filtering leaves fewer new videos than this, fetch the next page too…
    public var minimumPerLoad = 8
    /// …up to this many Lighthouse pages per load.
    public var maxPagesPerLoad = 3

    public init() {}

    public struct Results: Equatable, Sendable {
        public var channels: [Claim] = []
        /// Videos from channels the viewer follows, lifted out of the first page.
        public var following: [Claim] = []
        public var videos: [Claim] = []
        /// Lighthouse offset of the next page; nil when there's nothing more.
        public var nextFrom: Int? = 0
        /// Claims already in the results, so later pages don't repeat them.
        public var shown: Set<String> = []

        public init() {}

        public var isEmpty: Bool { channels.isEmpty && following.isEmpty && videos.isEmpty }
        public var hasMore: Bool { nextFrom != nil }
    }

    /// The two network calls search makes. Swappable so tests run without a network.
    public struct Fetcher: Sendable {
        public var hits: @Sendable (LighthouseQuery) async throws -> [LighthouseHit]
        public var resolve: @Sendable ([String]) async throws -> [String: Claim]

        public init(
            hits: @escaping @Sendable (LighthouseQuery) async throws -> [LighthouseHit],
            resolve: @escaping @Sendable ([String]) async throws -> [String: Claim]
        ) {
            self.hits = hits
            self.resolve = resolve
        }

        public static func client(_ client: LBRYClient) -> Fetcher {
            Fetcher(hits: { try await client.lighthouse($0) }, resolve: { try await client.resolve($0) })
        }
    }

    // MARK: Loading

    /// Run a search from the start. A text search loads its channel row alongside
    /// the first page of videos; a failed channel row leaves the row empty rather
    /// than failing the search.
    public func start(
        _ query: SearchQuery,
        options: SearchOptions = SearchOptions(),
        filter: ContentFilter,
        taste: TasteProfile,
        following: Set<String>,
        fetcher: Fetcher
    ) async throws -> Results {
        var results = Results()
        if query.isTooShort {
            // Lighthouse refuses it, but an exact channel name ("@tv") can still resolve.
            results.nextFrom = nil
            if let name = query.exactChannelName,
               let claim = try await fetcher.resolve(["lbry://@\(name)"])["lbry://@\(name)"],
               allowsChannel(claim, taste: taste, filter: filter) {
                results.channels = [claim]
            }
            return results
        }
        switch query {
        case .link(let uri):
            // Asked for by link: the content filter applies, taste mutes don't.
            results.nextFrom = nil
            guard let claim = try await fetcher.resolve([uri])[uri], filter.allows(claim) else { return results }
            if claim.valueType == "channel" {
                results.channels = [claim]
            } else {
                results.videos = [claim]
            }
            results.shown = [claim.claimId]
            return results

        case .channel(let name):
            results.nextFrom = nil
            results.channels = try await channels(
                name, exactName: query.exactChannelName, limit: channelListLimit,
                filter: filter, taste: taste, fetcher: fetcher
            )
            return results

        case .text(let text):
            async let row = channelRow(text, exactName: query.exactChannelName, filter: filter, taste: taste, fetcher: fetcher)
            results = try await loadMore(results, for: text, options: options, filter: filter, taste: taste, fetcher: fetcher)
            // Lift videos from followed channels into their own section, unless that's all of them.
            let mine = results.videos.filter { video in
                video.signingChannel.map { following.contains($0.claimId) } ?? false
            }
            if !mine.isEmpty, mine.count < results.videos.count {
                let ids = Set(mine.map(\.claimId))
                results.following = mine
                results.videos.removeAll { ids.contains($0.claimId) }
            }
            results.channels = await row
            return results
        }
    }

    /// Fetch the next page of a text search and append it. Pages that filtering
    /// empties are skipped (up to `maxPagesPerLoad`). If a later page fails, what
    /// this load already found is kept and the next load retries that page.
    public func loadMore(
        _ results: Results,
        for text: String,
        options: SearchOptions = SearchOptions(),
        filter: ContentFilter,
        taste: TasteProfile,
        fetcher: Fetcher
    ) async throws -> Results {
        var out = results
        var added = 0
        var pages = 0
        while let from = out.nextFrom, pages < maxPagesPerLoad, added < minimumPerLoad {
            pages += 1
            let fresh: [Claim]
            let isLast: Bool
            do {
                let hits = try await fetcher.hits(.videos(text, options: options, size: pageSize, from: from))
                isLast = hits.count < pageSize
                let wanted = preFilter(hits, shown: out.shown, taste: taste, filter: filter)
                if wanted.isEmpty {
                    fresh = []
                } else {
                    let resolved = try await fetcher.resolve(wanted.map(\.lbryURL))
                    // Keep Lighthouse's ranking order.
                    fresh = wanted.compactMap { resolved[$0.lbryURL] }.filter { allows($0, taste: taste, filter: filter) }
                }
            } catch {
                if added > 0 { break }
                throw error
            }
            out.nextFrom = isLast ? nil : from + pageSize
            for claim in fresh where out.shown.insert(claim.claimId).inserted {
                out.videos.append(claim)
                added += 1
            }
        }
        return out
    }

    /// Channels matching `text`: the exact name first if it resolves, then
    /// Lighthouse's matches, without muted or blocked channels.
    public func channels(
        _ text: String,
        exactName: String?,
        limit: Int,
        filter: ContentFilter,
        taste: TasteProfile,
        fetcher: Fetcher
    ) async throws -> [Claim] {
        // Ask for extra: some will be filtered out, or be the exact match again.
        let hits = try await fetcher.hits(.channels(text, size: limit * 2))
        let urls = (exactName.map { ["lbry://@\($0)"] } ?? []) + hits.map(\.lbryURL)
        guard !urls.isEmpty else { return [] }
        let resolved = try await fetcher.resolve(urls)
        var ids = Set<String>()
        let channels = urls.compactMap { resolved[$0] }.filter { claim in
            allowsChannel(claim, taste: taste, filter: filter) && ids.insert(claim.claimId).inserted
        }
        return Array(channels.prefix(limit))
    }

    private func channelRow(
        _ text: String, exactName: String?, filter: ContentFilter, taste: TasteProfile, fetcher: Fetcher
    ) async -> [Claim] {
        (try? await channels(text, exactName: exactName, limit: channelRowLimit, filter: filter, taste: taste, fetcher: fetcher)) ?? []
    }

    // MARK: Filtering

    /// Before resolving: hits already shown (or repeated within the page), blocked
    /// claims, and hits from muted or blocked channels are dropped.
    public func preFilter(
        _ hits: [LighthouseHit], shown: Set<String>, taste: TasteProfile, filter: ContentFilter
    ) -> [LighthouseHit] {
        var seen = shown
        return hits.filter { hit in
            guard !filter.blockedClaimIDs.contains(hit.claimId), seen.insert(hit.claimId).inserted else { return false }
            guard let channel = hit.channelClaimId else { return true }
            return !taste.mutedChannels.contains(channel) && !filter.blockedChannelIDs.contains(channel)
        }
    }

    /// After resolving: the content filter (tags, channels, claims), then the
    /// viewer's muted channels and topics, the same way the feeds apply them.
    public func allows(_ claim: Claim, taste: TasteProfile, filter: ContentFilter) -> Bool {
        guard filter.allows(claim) else { return false }
        if let channel = claim.signingChannel, taste.mutedChannels.contains(channel.claimId) { return false }
        return !TasteProfile.tags(of: claim).contains { taste.mutedTopics.contains($0) }
    }

    /// A channel claim the viewer hasn't muted or blocked.
    public func allowsChannel(_ claim: Claim, taste: TasteProfile, filter: ContentFilter) -> Bool {
        claim.valueType == "channel"
            && filter.allows(claim)
            && !filter.blockedChannelIDs.contains(claim.claimId)
            && !taste.mutedChannels.contains(claim.claimId)
    }
}
