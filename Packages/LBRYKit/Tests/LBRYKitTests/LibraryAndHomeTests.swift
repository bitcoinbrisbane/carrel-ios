import XCTest
@testable import LBRYKit

private let now = Date(timeIntervalSince1970: 1_762_400_000)

private func video(_ id: String, channel: String = "@chan", tags: [String] = [], seconds: Int = 600, ageDays: Double = 1) -> Claim {
    Claim(
        claimId: id, name: id, canonicalURL: nil, permanentURL: nil, valueType: "stream", timestamp: nil,
        signingChannel: ChannelRef(claimId: "ch-" + channel, name: channel, canonicalURL: nil, value: nil),
        value: ClaimValue(title: id, description: nil, thumbnail: nil, cover: nil, tags: tags,
                          releaseTime: String(Int(now.timeIntervalSince1970 - ageDays * 86_400)),
                          streamType: "video", video: .init(duration: seconds), audio: nil, source: nil)
    )
}

final class UserLibraryTests: XCTestCase {

    func testFollowAndUnfollow() {
        var lib = UserLibrary()
        let chan = ChannelRef(claimId: "c1", name: "@sail", canonicalURL: nil, value: nil)
        lib.follow(chan, at: now)
        lib.follow(chan, at: now)
        XCTAssertEqual(lib.following.count, 1)
        XCTAssertTrue(lib.isFollowing("c1"))
        XCTAssertEqual(lib.following[0].lbryURL, "lbry://@sail#c1")
        lib.unfollow("c1")
        XCTAssertFalse(lib.isFollowing("c1"))
    }

    func testContinueWatchingAndResume() {
        var lib = UserLibrary()
        lib.recordProgress(video("started"), position: 120, duration: 600, at: now)
        lib.recordProgress(video("barely"), position: 10, duration: 600, at: now)
        lib.recordProgress(video("finished"), position: 590, duration: 600, at: now)
        lib.recordProgress(video("unknownLength", seconds: 0), position: 45, duration: nil, at: now)

        XCTAssertEqual(Set(lib.continueWatching().map(\.id)), ["started", "unknownLength"])
        XCTAssertEqual(lib.resumePosition(for: "started"), 120)
        XCTAssertNil(lib.resumePosition(for: "barely"), "under 30 s starts from the top")
        XCTAssertNil(lib.resumePosition(for: "finished"))
        XCTAssertEqual(lib.entry(for: "started")?.progress ?? 0, 0.2, accuracy: 1e-9)
    }

    func testRewatchMovesToFrontAndHistoryIsCapped() {
        var lib = UserLibrary()
        for i in 0..<(UserLibrary.historyLimit + 5) {
            lib.recordProgress(video("v\(i)"), position: 60, duration: 600, at: now)
        }
        XCTAssertEqual(lib.history.count, UserLibrary.historyLimit)
        lib.recordProgress(video("v10"), position: 300, duration: 600, at: now)
        XCTAssertEqual(lib.history.first?.id, "v10")
        XCTAssertEqual(lib.history.first?.position, 300)
        XCTAssertEqual(lib.history.count, UserLibrary.historyLimit)
    }

    func testRoundTripsThroughJSON() throws {
        var lib = UserLibrary()
        lib.follow(ChannelRef(claimId: "c1", name: "@sail", canonicalURL: nil, value: nil), at: now)
        lib.recordProgress(video("a", tags: ["sailing"]), position: 100, duration: 600, at: now)
        let decoded = try JSONDecoder().decode(UserLibrary.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(decoded, lib)
        XCTAssertEqual(decoded.history[0].claim.tags, ["sailing"])
    }
}

final class HomeFeedTests: XCTestCase {

    private func likedSailing() -> TasteProfile {
        var t = TasteProfile()
        for i in 0..<3 { t.record(.like, on: video("seed\(i)", channel: "@sail", tags: ["sailing"])) }
        return t
    }

    func testDiscoverShelves() throws {
        var taste = likedSailing()
        for i in 0..<2 { taste.record(.like, on: video("c\(i)", channel: "@cook", tags: ["cooking"])) }
        taste.mutedTopics.insert("gaming")
        taste.record(.lessTopic("music"), on: video("m", channel: "@m", tags: ["music"]))
        let shelves = HomeFeed().discoverShelves(taste: taste, blockedTags: ["nsfw"], topicCount: 5, now: now)
        let ids = shelves.map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), ["top-week", "top-month"])
        XCTAssertFalse(ids.contains("topic-sailing"), "already its own row (More #sailing)")
        XCTAssertEqual(ids[2], "topic-cooking", "your other topics come first")
        XCTAssertEqual(shelves[2].subtitle, "You watch a lot of this")
        XCTAssertFalse(ids.contains("topic-gaming"), "muted")
        XCTAssertFalse(HomeFeed().discoverShelves(taste: taste, blockedTags: [], now: now).map(\.id).contains("topic-music"),
                       "turned down with Less #music")
        XCTAssertEqual(shelves.count, 2 + 5)
        XCTAssertEqual(shelves[0].params.orderBy, ["effective_amount"])
        XCTAssertEqual(shelves[0].params.releaseTime, ">\(Int(now.timeIntervalSince1970) - 7 * 86_400)")
        XCTAssertTrue(shelves.allSatisfy { $0.params.duration == ">=181" && $0.params.notTags?.contains("nsfw") == true })

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(shelves[0].params), encoding: .utf8))
        XCTAssertTrue(json.contains("\"release_time\""))

        let more = HomeFeed().moreToWatchQuery(page: 3, taste: taste, blockedTags: [])
        XCTAssertEqual(more.page, 3)
        XCTAssertEqual(more.duration, ">=181")
    }

    func testDiscoverSections() {
        var taste = likedSailing()
        taste.mutedTopics.insert("news")
        let feed = HomeFeed()
        let sections = feed.discoverSections(taste: taste, topicCount: 4)
        XCTAssertEqual(sections.map(\.id), ["trending", "new", "top-week", "top-month",
                                             "topic-sailing", "topic-technology", "topic-science", "topic-education"])
        XCTAssertEqual(sections[4].title, "#sailing")

        let new = feed.discoverQuery(.new, page: 2, taste: taste, blockedTags: [], now: now)
        XCTAssertEqual(new.orderBy, ["release_time"])
        XCTAssertEqual(new.releaseTime, "<=\(Int(now.timeIntervalSince1970))")
        XCTAssertEqual(new.page, 2)
        let month = feed.discoverQuery(.topMonth, page: 1, taste: taste, blockedTags: [], now: now)
        XCTAssertEqual(month.releaseTime, ">\(Int(now.timeIntervalSince1970) - 30 * 86_400)")
        let topic = feed.discoverQuery(.topic("sailing"), page: 1, taste: taste, blockedTags: ["nsfw"], now: now)
        XCTAssertEqual(topic.anyTags, ["sailing"])
        XCTAssertEqual(topic.notTags, ["nsfw", "news"])
        XCTAssertEqual(topic.duration, ">=181")
    }

    func testQueriesFollowTasteAndLibrary() {
        var lib = UserLibrary()
        lib.follow(ChannelRef(claimId: "ch-@news", name: "@news", canonicalURL: nil, value: nil), at: now)
        let qs = HomeFeed().queries(taste: likedSailing(), library: lib, blockedTags: ["nsfw"])
        XCTAssertEqual(qs.map(\.source), [.trending, .following, .channel(id: "ch-@sail", name: "@sail"), .topic("sailing")])
        XCTAssertTrue(qs.allSatisfy { $0.params.duration == ">=181" })
        XCTAssertEqual(qs[1].params.channelIDs, ["ch-@news"])
    }

    func testNewViewerGetsTrendingOnly() {
        let qs = HomeFeed().queries(taste: TasteProfile(), library: UserLibrary(), blockedTags: [])
        XCTAssertEqual(qs.map(\.source), [.trending])
    }

    func testPageBuildsRowsWithoutDuplicates() {
        var lib = UserLibrary()
        lib.recordProgress(video("half", channel: "@sail", tags: ["sailing"]), position: 300, duration: 600, at: now)
        let taste = likedSailing()

        let results: [HomeFeed.Source: [Claim]] = [
            .trending: [video("t1", channel: "@x"), video("t2", channel: "@y"), video("s9", channel: "@sail", tags: ["sailing"])],
            .channel(id: "ch-@sail", name: "@sail"): (1...4).map { video("s\($0)", channel: "@sail", tags: ["sailing"]) },
            .topic("sailing"): [video("s1", channel: "@sail", tags: ["sailing"]), video("o1", channel: "@boats", tags: ["sailing"])],
        ]
        let page = HomeFeed().page(results: results, taste: taste, library: lib, now: now)

        XCTAssertNotNil(page.featured)
        XCTAssertEqual(page.featured?.claim.signingChannel?.name, "@sail")
        XCTAssertGreaterThanOrEqual(page.featuredMatch ?? 0, 70)

        XCTAssertEqual(page.rows.first?.title, "Continue watching")
        XCTAssertEqual(page.rows.first?.items.map(\.id), ["half"])
        XCTAssertTrue(page.rows.contains { $0.title == "Because you liked @sail" })
        XCTAssertTrue(page.rows.contains { $0.title == "More #sailing" })

        let ids = page.rows.flatMap { $0.items.map(\.id) } + [page.featured!.id]
        XCTAssertEqual(ids.count, Set(ids).count, "each video appears once")
        XCTAssertFalse(page.rows.filter { $0.style == .standard }.flatMap(\.items).contains { $0.id == "half" },
                       "a video you're halfway through isn't recommended again")
    }

    func testMatchPercent() {
        XCTAssertEqual(HomeFeed.matchPercent(0), 50)
        XCTAssertGreaterThanOrEqual(HomeFeed.matchPercent(1.27), 90)
        XCTAssertLessThan(HomeFeed.matchPercent(-1), 20)
    }
}
