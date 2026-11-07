import XCTest
@testable import LBRYKit

// MARK: - Helpers

private func video(_ id: String, channelID: String? = "ch-a", tags: [String] = []) -> Claim {
    Claim(
        claimId: id, name: id, canonicalURL: nil, permanentURL: nil, valueType: "stream", timestamp: nil,
        signingChannel: channelID.map { ChannelRef(claimId: $0, name: "@" + $0, canonicalURL: nil, value: nil) },
        value: ClaimValue(
            title: id, description: nil, thumbnail: nil, cover: nil, tags: tags,
            releaseTime: nil, streamType: "video", video: .init(duration: 600), audio: nil, source: nil
        )
    )
}

private func channel(_ id: String, name: String? = nil, tags: [String] = []) -> Claim {
    Claim(
        claimId: id, name: name ?? "@" + id, canonicalURL: nil, permanentURL: nil, valueType: "channel", timestamp: nil,
        signingChannel: nil,
        value: ClaimValue(
            title: id, description: nil, thumbnail: nil, cover: nil, tags: tags,
            releaseTime: nil, streamType: nil, video: nil, audio: nil, source: nil
        )
    )
}

private func hit(_ claim: Claim) -> LighthouseHit {
    LighthouseHit(name: claim.name, claimId: claim.claimId, channelClaimId: claim.signingChannel?.claimId)
}

/// A pretend Lighthouse and SDK: `videoPages[i]` answers the request with `from == i * 20`,
/// `channelHits` answers channel searches, and `resolve` knows every claim given.
private actor FakeBackend {
    var videoPages: [[Claim]]
    var channelHits: [Claim]
    var known: [String: Claim] = [:]
    var failVideoPages: Set<Int> = []
    var failChannels = false
    private(set) var queries: [LighthouseQuery] = []
    private(set) var resolved: [[String]] = []

    init(videoPages: [[Claim]] = [], channelHits: [Claim] = [], extra: [String: Claim] = [:]) {
        self.videoPages = videoPages
        self.channelHits = channelHits
        for claim in videoPages.flatMap({ $0 }) + channelHits { known[hit(claim).lbryURL] = claim }
        known.merge(extra) { a, _ in a }
    }

    func setFailVideoPages(_ pages: Set<Int>) { failVideoPages = pages }
    func setFailChannels(_ fail: Bool) { failChannels = fail }

    func hits(_ query: LighthouseQuery) throws -> [LighthouseHit] {
        queries.append(query)
        if query.parameters["claimType"] == "channel" {
            if failChannels { throw LBRYError.http(500) }
            return channelHits.map(hit)
        }
        let page = Int(query.parameters["from"] ?? "0")! / 20
        if failVideoPages.contains(page) { throw LBRYError.http(502) }
        return page < videoPages.count ? videoPages[page].map(hit) : []
    }

    func resolve(_ urls: [String]) -> [String: Claim] {
        resolved.append(urls)
        return known.filter { urls.contains($0.key) }
    }

    nonisolated var fetcher: SearchFeed.Fetcher {
        SearchFeed.Fetcher(hits: { try await self.hits($0) }, resolve: { await self.resolve($0) })
    }
}

private func page(_ prefix: String, count: Int = 20, channelID: String = "ch-a") -> [Claim] {
    (0..<count).map { video("\(prefix)\($0)", channelID: channelID) }
}

// MARK: - SearchQuery

final class SearchQueryTests: XCTestCase {

    func testLinksOpenDirectly() {
        XCTAssertEqual(SearchQuery("lbry://@chan#a/video#b"), .link("lbry://@chan#a/video#b"))
        XCTAssertEqual(SearchQuery("https://odysee.com/@chan:a/video:b"), .link("lbry://@chan#a/video#b"))
        XCTAssertEqual(SearchQuery("odysee.com/@chan:a/video:b"), .link("lbry://@chan#a/video#b"))
        XCTAssertEqual(SearchQuery("  @chan:a/video:b \n"), .link("lbry://@chan#a/video#b"))
        XCTAssertEqual(SearchQuery("@chan:a"), .link("lbry://@chan#a"))
    }

    func testBareChannelNameIsAChannelSearch() {
        XCTAssertEqual(SearchQuery("@bitcoin"), .channel("bitcoin"))
        XCTAssertEqual(SearchQuery("@bitcoin takeover"), .channel("bitcoin takeover"))
        XCTAssertNil(SearchQuery("@"))
        XCTAssertNil(SearchQuery("   "))
    }

    func testEverythingElseIsText() {
        XCTAssertEqual(SearchQuery("bitcoin takeover"), .text("bitcoin takeover"))
        XCTAssertEqual(SearchQuery("#bitcoin"), .text("#bitcoin"))
        // Links Carrel can't open are searched as text rather than refused.
        XCTAssertEqual(SearchQuery("https://youtube.com/watch?v=x"), .text("https://youtube.com/watch?v=x"))
    }

    func testExactChannelName() {
        XCTAssertEqual(SearchQuery.text("bitcoin takeover").exactChannelName, "bitcointakeover")
        XCTAssertEqual(SearchQuery.channel("Bitcoin").exactChannelName, "Bitcoin")
        XCTAssertNil(SearchQuery.text("what is #bitcoin?").exactChannelName)
        XCTAssertNil(SearchQuery.link("lbry://@chan#a").exactChannelName)
        XCTAssertNil(SearchQuery.text(String(repeating: "a", count: 65)).exactChannelName)
    }

    func testTooShortForLighthouse() {
        XCTAssertTrue(SearchQuery.text("ai").isTooShort)
        XCTAssertTrue(SearchQuery.channel("tv").isTooShort)
        XCTAssertFalse(SearchQuery.text("a b").isTooShort)
        XCTAssertFalse(SearchQuery.text("仮想通").isTooShort)
        XCTAssertFalse(SearchQuery.link("lbry://a").isTooShort)
    }
}

// MARK: - Lighthouse parameters

final class LighthouseQueryTests: XCTestCase {

    func testVideoSearchDefaults() {
        let q = LighthouseQuery.videos("bitcoin", size: 20, from: 40)
        XCTAssertEqual(q.parameters, ["s": "bitcoin", "size": "20", "from": "40", "nsfw": "false", "mediaType": "video"])
    }

    func testOptionsBecomeLighthouseParameters() {
        let newest = LighthouseQuery.videos("x", options: .init(sort: .newest, uploaded: .thisWeek, length: .short), size: 20, from: 0)
        XCTAssertEqual(newest.parameters["sort_by"], "release_time")
        XCTAssertEqual(newest.parameters["time_filter"], "thisweek")
        XCTAssertEqual(newest.parameters["max_duration"], "180")
        XCTAssertNil(newest.parameters["min_duration"])

        let top = LighthouseQuery.videos("x", options: .init(sort: .mostSupported, uploaded: .today, length: .long), size: 20, from: 0)
        XCTAssertEqual(top.parameters["sort_by"], "effective_amount")
        XCTAssertEqual(top.parameters["time_filter"], "today")
        XCTAssertEqual(top.parameters["min_duration"], "1200")

        let inChannel = LighthouseQuery.videos("x", size: 20, from: 0, channelID: "abc")
        XCTAssertEqual(inChannel.parameters["channel_id"], "abc")
    }

    func testChannelSearch() {
        let q = LighthouseQuery.channels("bitcoin", size: 10)
        XCTAssertEqual(q.parameters, ["s": "bitcoin", "size": "10", "from": "0", "nsfw": "false", "claimType": "channel"])
    }

    func testURLEncodesEverythingButUnreservedCharacters() {
        let url = LighthouseQuery.videos("c++ & rust", size: 2, from: 0).url(base: LBRYClient.Endpoint.odyseeLighthouse)
        XCTAssertEqual(
            url.absoluteString,
            "https://lighthouse.odysee.tv/search?from=0&mediaType=video&nsfw=false&s=c%2B%2B%20%26%20rust&size=2"
        )
    }

    func testDecodesHitsAndFailures() throws {
        let json = #"[{"channel_claim_id":"ch1","claimId":"a","name":"one"},{"channel_claim_id":null,"claimId":"b","name":"@two"}]"#
        let hits = try JSONDecoder().decode([LighthouseHit].self, from: Data(json.utf8))
        XCTAssertEqual(hits, [LighthouseHit(name: "one", claimId: "a", channelClaimId: "ch1"), LighthouseHit(name: "@two", claimId: "b")])
        XCTAssertEqual(hits[0].lbryURL, "lbry://one#a")

        let failure = try JSONDecoder().decode(
            LighthouseFailure.self, from: Data(#"{"success":false,"error":"Extraneous params: exact","data":null}"#.utf8)
        )
        XCTAssertEqual(failure.error, "Extraneous params: exact")
        XCTAssertNil(try? JSONDecoder().decode(LighthouseFailure.self, from: Data(json.utf8)))
    }
}

// MARK: - SearchFeed

final class SearchFeedTests: XCTestCase {
    let feed = SearchFeed()
    let filter = ContentFilter()

    func testPreFilterDropsShownRepeatedBlockedAndMutedChannels() {
        var taste = TasteProfile()
        taste.mutedChannels = ["muted"]
        let filter = ContentFilter(blockedChannelIDs: ["blocked"], blockedClaimIDs: ["bad"])
        let hits = [
            LighthouseHit(name: "a", claimId: "a", channelClaimId: "ok"),
            LighthouseHit(name: "a", claimId: "a", channelClaimId: "ok"),
            LighthouseHit(name: "b", claimId: "b", channelClaimId: "muted"),
            LighthouseHit(name: "c", claimId: "c", channelClaimId: "blocked"),
            LighthouseHit(name: "d", claimId: "bad", channelClaimId: "ok"),
            LighthouseHit(name: "e", claimId: "e", channelClaimId: "ok"),
            LighthouseHit(name: "f", claimId: "f"),
        ]
        let kept = feed.preFilter(hits, shown: ["e"], taste: taste, filter: filter)
        XCTAssertEqual(kept.map(\.claimId), ["a", "f"])
    }

    func testAllowsAppliesFilterAndTasteMutes() {
        var taste = TasteProfile()
        taste.mutedTopics = ["politics"]
        taste.mutedChannels = ["muted"]
        XCTAssertTrue(feed.allows(video("a", tags: ["bitcoin"]), taste: taste, filter: filter))
        XCTAssertFalse(feed.allows(video("b", tags: ["#Politics"]), taste: taste, filter: filter))
        XCTAssertFalse(feed.allows(video("c", tags: ["NSFW"]), taste: taste, filter: filter))
        XCTAssertFalse(feed.allows(video("d", channelID: "muted"), taste: taste, filter: filter))
    }

    func testTextSearchFirstPage() async throws {
        let videos = page("v")
        let backend = FakeBackend(
            videoPages: [videos],
            channelHits: [channel("c1"), channel("c2")],
            extra: ["lbry://@bitcoin": channel("exact", name: "@bitcoin")]
        )
        let results = try await feed.start(.text("bitcoin"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.videos.map(\.claimId), videos.map(\.claimId))
        XCTAssertEqual(results.nextFrom, 20)
        XCTAssertTrue(results.following.isEmpty)
        // The exact @name match comes first.
        XCTAssertEqual(results.channels.map(\.claimId), ["exact", "c1", "c2"])
    }

    func testFollowedChannelsAreLiftedOutOfTheFirstPage() async throws {
        let mine = page("m", count: 3, channelID: "followed")
        let others = page("o", count: 17)
        let backend = FakeBackend(videoPages: [[others[0], mine[0]] + others.dropFirst() + mine.dropFirst()])
        let results = try await feed.start(.text("sail"), filter: filter, taste: TasteProfile(), following: ["followed"], fetcher: backend.fetcher)
        XCTAssertEqual(results.following.map(\.claimId), ["m0", "m1", "m2"])
        XCTAssertEqual(results.videos.map(\.claimId), others.map(\.claimId))
    }

    func testAllFromFollowedChannelsStaysOneList() async throws {
        let mine = page("m", count: 5, channelID: "followed")
        let backend = FakeBackend(videoPages: [mine])
        let results = try await feed.start(.text("sail"), filter: filter, taste: TasteProfile(), following: ["followed"], fetcher: backend.fetcher)
        XCTAssertTrue(results.following.isEmpty)
        XCTAssertEqual(results.videos.count, 5)
    }

    func testFetchesOnWhenFilteringEmptiesAPage() async throws {
        var taste = TasteProfile()
        taste.mutedChannels = ["noisy"]
        let backend = FakeBackend(videoPages: [page("n", channelID: "noisy"), page("v"), page("w")])
        let results = try await feed.start(.text("sail"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.videos.count, 20)
        XCTAssertEqual(results.videos.first?.claimId, "v0")
        XCTAssertEqual(results.nextFrom, 40)
        // The muted page was never resolved.
        let resolveCalls = await backend.resolved
        XCTAssertFalse(resolveCalls.joined().contains { $0.contains("#n") })
    }

    func testFetchOnStopsAfterMaxPages() async throws {
        var taste = TasteProfile()
        taste.mutedChannels = ["noisy"]
        let noisy = (0..<5).map { page("n\($0)-", channelID: "noisy") }
        let backend = FakeBackend(videoPages: noisy)
        let results = try await feed.start(.text("sail"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertTrue(results.videos.isEmpty)
        XCTAssertEqual(results.nextFrom, 60)
        let queries = await backend.queries
        XCTAssertEqual(queries.filter { $0.parameters["mediaType"] == "video" }.count, 3)
    }

    func testPagingDropsRepeatsAndEndsOnAShortPage() async throws {
        let first = page("v")
        let second = [first[0], first[1]] + page("w", count: 8)   // 10 hits: the last page
        let backend = FakeBackend(videoPages: [first, second])
        let one = try await feed.start(.text("sail"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
        let two = try await feed.loadMore(one, for: "sail", filter: filter, taste: TasteProfile(), fetcher: backend.fetcher)
        XCTAssertEqual(two.videos.count, 28)
        XCTAssertEqual(Set(two.videos.map(\.claimId)).count, 28)
        XCTAssertNil(two.nextFrom)
        XCTAssertFalse(two.hasMore)
        let three = try await feed.loadMore(two, for: "sail", filter: filter, taste: TasteProfile(), fetcher: backend.fetcher)
        XCTAssertEqual(three, two)
    }

    func testLaterPageFailureKeepsWhatWasFound() async throws {
        var taste = TasteProfile()
        taste.mutedChannels = ["noisy"]
        // Page 0: 5 keepers (fewer than minimumPerLoad), so page 1 is fetched, and fails.
        let backend = FakeBackend(videoPages: [page("v", count: 5) + page("n", count: 15, channelID: "noisy"), page("w")])
        await backend.setFailVideoPages([1])
        let results = try await feed.start(.text("sail"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.videos.count, 5)
        XCTAssertEqual(results.nextFrom, 20, "retries the failed page next time")
    }

    func testFirstPageFailureThrows() async {
        let backend = FakeBackend(videoPages: [page("v")])
        await backend.setFailVideoPages([0])
        do {
            _ = try await feed.start(.text("sail"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LBRYError, .http(502))
        }
    }

    func testChannelRowFailureDoesNotFailTheSearch() async throws {
        let backend = FakeBackend(videoPages: [page("v", count: 3)], channelHits: [channel("c1")])
        await backend.setFailChannels(true)
        let results = try await feed.start(.text("sail"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.videos.count, 3)
        XCTAssertTrue(results.channels.isEmpty)
    }

    func testChannelSearchListsChannelsOnly() async throws {
        var taste = TasteProfile()
        taste.mutedChannels = ["c2"]
        let backend = FakeBackend(
            channelHits: [channel("c1"), channel("c2"), channel("c3", tags: ["mature"]), channel("bitcoin-id", name: "@bitcoin")],
            extra: ["lbry://@bitcoin": channel("bitcoin-id", name: "@bitcoin")]
        )
        let results = try await feed.start(.channel("bitcoin"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.channels.map(\.claimId), ["bitcoin-id", "c1"])
        XCTAssertTrue(results.videos.isEmpty)
        XCTAssertFalse(results.hasMore)
        let channelQuery = await backend.queries.first
        XCTAssertEqual(channelQuery?.parameters["size"], "40")
    }

    func testTooShortOnlyTriesTheExactChannel() async throws {
        let backend = FakeBackend(videoPages: [page("v")], extra: ["lbry://@ai": channel("ai-id", name: "@ai")])
        let results = try await feed.start(.text("ai"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
        XCTAssertEqual(results.channels.map(\.claimId), ["ai-id"])
        XCTAssertTrue(results.videos.isEmpty)
        XCTAssertFalse(results.hasMore)
        let queries = await backend.queries
        XCTAssertTrue(queries.isEmpty, "Lighthouse refuses searches under 3 characters")

        let nothing = try await feed.start(.text("zz"), filter: filter, taste: TasteProfile(), following: [], fetcher: backend.fetcher)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testLinkResolvesDirectly() async throws {
        let target = video("t", channelID: "muted")
        let channelClaim = channel("c")
        var taste = TasteProfile()
        taste.mutedChannels = ["muted"]
        let backend = FakeBackend(extra: ["lbry://@chan#a/t#1": target, "lbry://@chan#c": channelClaim, "lbry://x#1": video("x", tags: ["nsfw"])])

        let link = try await feed.start(.link("lbry://@chan#a/t#1"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertEqual(link.videos.map(\.claimId), ["t"], "a muted channel's video still opens when asked for by link")
        XCTAssertFalse(link.hasMore)

        let channelLink = try await feed.start(.link("lbry://@chan#c"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertEqual(channelLink.channels.map(\.claimId), ["c"])
        XCTAssertTrue(channelLink.videos.isEmpty)

        let blocked = try await feed.start(.link("lbry://x#1"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertTrue(blocked.isEmpty, "the content filter still applies")

        let missing = try await feed.start(.link("lbry://nothing#0"), filter: filter, taste: taste, following: [], fetcher: backend.fetcher)
        XCTAssertTrue(missing.isEmpty)
    }
}

// MARK: - RecentSearches

final class RecentSearchesTests: XCTestCase {

    func testNewestFirstWithoutRepeats() {
        var recent = RecentSearches()
        recent.record("bitcoin")
        recent.record("  sailing ")
        recent.record("Bitcoin")
        XCTAssertEqual(recent.items, ["Bitcoin", "sailing"])
        recent.record("   ")
        XCTAssertEqual(recent.items.count, 2)
    }

    func testCappedAndEditable() throws {
        var recent = RecentSearches()
        for i in 0..<25 { recent.record("q\(i)") }
        XCTAssertEqual(recent.items.count, RecentSearches.limit)
        XCTAssertEqual(recent.items.first, "q24")
        XCTAssertEqual(recent.items.last, "q5")
        recent.remove("q24")
        XCTAssertEqual(recent.items.first, "q23")
        let restored = try JSONDecoder().decode(RecentSearches.self, from: JSONEncoder().encode(recent))
        XCTAssertEqual(restored, recent)
        recent.clear()
        XCTAssertTrue(recent.isEmpty)
    }
}
