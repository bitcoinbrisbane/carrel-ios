import Foundation

/// Builds the "For you" home: a featured video and Netflix-style rows, all ranked
/// on device with `FeedRanker` against the viewer's taste and library.
///
/// Rows (each only when it has something to show):
/// - Continue watching (from history)
/// - New from channels you follow
/// - Because you liked @channel (your top channel)
/// - More #tag (your top topic)
/// - Trending on LBRY
/// - Fresh on LBRY (new to you: the exploration row)
///
/// A video appears in at most one row; the featured video in none.
public struct HomeFeed: Sendable {

    public enum Source: Hashable, Sendable {
        case trending
        case following
        case channel(id: String, name: String)
        case topic(String)
    }

    public struct Query: Sendable {
        public let source: Source
        public let params: ClaimSearchParams
    }

    public struct Row: Identifiable, Sendable {
        public enum Style: Sendable { case standard, continueWatching }
        public let id: String
        public let title: String
        public let subtitle: String?
        public let items: [RankedClaim]
        public let style: Style
    }

    public struct Page: Sendable {
        public let featured: RankedClaim?
        public let featuredMatch: Int?
        public let rows: [Row]
    }

    public var ranker = FeedRanker()
    public var rowLength = 12
    /// Home is for longer videos; Shorts has the rest.
    public var minDuration = 181

    public init() {}

    /// Home's side of the Shorts split: a known length over 3 minutes. (The server's
    /// `duration >=181` already excludes unknown lengths; this keeps chips and rows honest.)
    public func isLong(_ claim: Claim) -> Bool {
        (claim.duration ?? 0) >= minDuration
    }

    // MARK: Queries

    public func queries(taste: TasteProfile, library: UserLibrary, blockedTags: [String]) -> [Query] {
        var base = ClaimSearchParams()
        base.duration = ">=\(minDuration)"
        base.notTags = blockedTags + taste.mutedTopics.sorted()
        base.pageSize = 30

        var out: [Query] = []

        var trending = base
        trending.orderBy = ["trending_group", "trending_mixed"]
        out.append(Query(source: .trending, params: trending))

        let followed = library.followedChannelIDs.filter { !taste.mutedChannels.contains($0) }
        if !followed.isEmpty {
            var q = base
            q.channelIDs = Array(followed.prefix(50))
            q.orderBy = ["release_time"]
            out.append(Query(source: .following, params: q))
        }

        if let top = taste.topChannels(1).first, let name = taste.channelNames[top.id], !followed.contains(top.id) || followed.count > 1 {
            var q = base
            q.channelIDs = [top.id]
            q.orderBy = ["release_time"]
            out.append(Query(source: .channel(id: top.id, name: name), params: q))
        }

        if let tag = taste.topTopics(1).first?.tag {
            var q = base
            q.anyTags = [tag]
            q.orderBy = ["trending_group", "trending_mixed"]
            out.append(Query(source: .topic(tag), params: q))
        }
        return out
    }

    /// Single-list queries for the filter chips.
    public func chipQuery(_ chip: Source, taste: TasteProfile, library: UserLibrary, blockedTags: [String]) -> ClaimSearchParams {
        var q = ClaimSearchParams()
        q.duration = ">=\(minDuration)"
        q.notTags = blockedTags + taste.mutedTopics.sorted()
        q.pageSize = 40
        switch chip {
        case .trending:
            q.orderBy = ["trending_group", "trending_mixed"]
        case .following:
            q.channelIDs = library.followedChannelIDs
            q.orderBy = ["release_time"]
        case .channel(let id, _):
            q.channelIDs = [id]
            q.orderBy = ["release_time"]
        case .topic(let tag):
            q.anyTags = [tag]
            q.orderBy = ["trending_group", "trending_mixed"]
        }
        return q
    }

    // MARK: Rows

    public func page(
        results: [Source: [Claim]],
        taste: TasteProfile,
        library: UserLibrary,
        filter: ContentFilter = ContentFilter(),
        now: Date = Date()
    ) -> Page {
        var used = Set<String>()
        let watched = Set(library.history.map { $0.claim.claimId })

        // Home ranks with the viewer's weights and mutes, but without Shorts' "already
        // shown" list or exploration slots: rows decide placement themselves.
        var homeTaste = TasteProfile()
        homeTaste.topics = taste.topics
        homeTaste.channels = taste.channels
        homeTaste.channelNames = taste.channelNames
        homeTaste.mutedTopics = taste.mutedTopics
        homeTaste.mutedChannels = taste.mutedChannels
        homeTaste.exploration = 0

        func ranked(_ claims: [Claim]) -> [RankedClaim] {
            // Skip videos already watched here (Continue watching covers unfinished ones).
            let candidates = filter.apply(claims).filter { isLong($0) && !watched.contains($0.claimId) }
            var rng = SeededGenerator(seed: 7)
            return ranker.rank(candidates, taste: homeTaste, now: now, using: &rng)
        }

        func take(_ items: [RankedClaim]) -> [RankedClaim] {
            var out: [RankedClaim] = []
            for item in items where !used.contains(item.id) {
                out.append(item)
                used.insert(item.id)
                if out.count == rowLength { break }
            }
            return out
        }

        // Featured: the best-scoring video anywhere, if it's a real match.
        let everything = ranked(results.values.flatMap { $0 })
        var featured: RankedClaim?
        var featuredMatch: Int?
        if let best = everything.first {
            let match = Self.matchPercent(best.score)
            if match >= 70 || library.history.isEmpty {
                featured = best
                featuredMatch = match >= 70 ? match : nil
                used.insert(best.id)
            }
        }

        var rows: [Row] = []

        let resume = library.continueWatching()
        if !resume.isEmpty {
            let items = resume.map { RankedClaim(claim: $0.claim, score: 0, reason: .trending) }
            rows.append(Row(id: "continue", title: "Continue watching", subtitle: "Saved on this phone",
                            items: items, style: .continueWatching))
            items.forEach { used.insert($0.id) }
        }

        if let claims = results[.following] {
            let items = take(ranked(claims).sorted { ($0.claim.releaseDate ?? .distantPast) > ($1.claim.releaseDate ?? .distantPast) })
            if !items.isEmpty {
                rows.append(Row(id: "following", title: "New from channels you follow", subtitle: nil, items: items, style: .standard))
            }
        }

        for (source, claims) in results {
            guard case let .channel(_, name) = source else { continue }
            let items = take(ranked(claims))
            if !items.isEmpty {
                rows.append(Row(id: "channel", title: "Because you liked \(name)", subtitle: nil, items: items, style: .standard))
            }
        }

        for (source, claims) in results {
            guard case let .topic(tag) = source else { continue }
            let items = take(ranked(claims))
            if !items.isEmpty {
                rows.append(Row(id: "topic", title: "More #\(tag)", subtitle: "Your top topic", items: items, style: .standard))
            }
        }

        if let claims = results[.trending] {
            let all = ranked(claims)
            // Fresh: trending clips from channels and topics the viewer has no opinion on yet.
            let fresh = take(all.filter { !ranker.isFamiliar($0.claim, taste: taste) }.map {
                RankedClaim(claim: $0.claim, score: $0.score, reason: .exploring)
            })
            let trending = take(all)
            if !trending.isEmpty {
                rows.append(Row(id: "trending", title: "Trending on LBRY", subtitle: nil, items: trending, style: .standard))
            }
            if !fresh.isEmpty, !taste.topics.isEmpty {
                rows.append(Row(id: "fresh", title: "Fresh on LBRY", subtitle: "New to you", items: fresh, style: .standard))
            }
        }

        return Page(featured: featured, featuredMatch: featuredMatch, rows: rows)
    }

    // MARK: Discover shelves

    /// A row of more videos to browse below the personal rows (Apple TV's Home, where
    /// there's room for many). Loaded lazily, one query each.
    public struct Shelf: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let params: ClaimSearchParams
    }

    /// Popular LBRY topics, for shelves after the viewer's own top topics.
    public static let discoverTopics = [
        "news", "technology", "science", "education", "gaming", "music", "comedy",
        "documentary", "history", "cryptocurrency", "outdoors", "cooking", "art", "sports",
    ]

    /// Top this week and month (most LBC staked), then a shelf per topic: the viewer's
    /// strongest topics first, then popular ones. Muted or turned-down topics are skipped, as is the
    /// topic already shown as "More #topic".
    public func discoverShelves(taste: TasteProfile, blockedTags: [String], topicCount: Int = 10, now: Date = Date()) -> [Shelf] {
        var base = ClaimSearchParams()
        base.duration = ">=\(minDuration)"
        base.notTags = blockedTags + taste.mutedTopics.sorted()
        base.pageSize = 30

        var shelves: [Shelf] = []
        let nowSeconds = Int(now.timeIntervalSince1970)
        for (id, title, days) in [("top-week", "Top this week", 7), ("top-month", "Top this month", 30)] {
            var q = base
            q.orderBy = ["effective_amount"]
            q.releaseTime = ">\(nowSeconds - days * 86_400)"
            shelves.append(Shelf(id: id, title: title, subtitle: "Most supported with LBC", params: q))
        }

        let alreadyShown = taste.topTopics(1).first?.tag
        let personal = taste.topTopics(6).map(\.tag)
        var seen: Set<String> = []
        var topics: [(tag: String, yours: Bool)] = []
        for tag in personal where tag != alreadyShown && seen.insert(tag).inserted { topics.append((tag, true)) }
        for tag in Self.discoverTopics
        where !taste.mutedTopics.contains(tag) && (taste.topics[tag] ?? 0) >= 0 && tag != alreadyShown && seen.insert(tag).inserted {
            topics.append((tag, false))
        }
        for topic in topics.prefix(topicCount) {
            var q = base
            q.anyTags = [topic.tag]
            q.orderBy = ["trending_group", "trending_mixed"]
            shelves.append(Shelf(id: "topic-\(topic.tag)", title: "#\(topic.tag)",
                                 subtitle: topic.yours ? "You watch a lot of this" : nil, params: q))
        }
        return shelves
    }

    /// The endless grid at the bottom: trending, page by page (page 1 already fed the rows).
    public func moreToWatchQuery(page: Int, taste: TasteProfile, blockedTags: [String]) -> ClaimSearchParams {
        var q = ClaimSearchParams()
        q.duration = ">=\(minDuration)"
        q.notTags = blockedTags + taste.mutedTopics.sorted()
        q.pageSize = 40
        q.page = page
        return q
    }

    /// Ranker score → a friendly "% match" (50% = no opinion either way).
    public static func matchPercent(_ score: Double) -> Int {
        Int((50 + 49 * tanh(score)).rounded())
    }
}
