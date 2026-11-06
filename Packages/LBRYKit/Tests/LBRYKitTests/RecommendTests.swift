import XCTest
@testable import LBRYKit

private let now = Date(timeIntervalSince1970: 1_762_400_000)

private func clip(
    _ id: String,
    channel: String = "@chan",
    channelID: String? = nil,
    tags: [String] = [],
    ageDays: Double = 1,
    seconds: Int? = 30
) -> Claim {
    let released = String(Int(now.timeIntervalSince1970 - ageDays * 86_400))
    return Claim(
        claimId: id,
        name: id,
        canonicalURL: nil,
        permanentURL: nil,
        valueType: "stream",
        timestamp: nil,
        signingChannel: ChannelRef(claimId: channelID ?? "ch-" + channel, name: channel, canonicalURL: nil, value: nil),
        value: ClaimValue(
            title: id, description: nil, thumbnail: nil, cover: nil, tags: tags,
            releaseTime: released, streamType: "video", video: seconds.map { .init(duration: $0) }, audio: nil, source: nil
        )
    )
}

final class TasteProfileTests: XCTestCase {

    func testLikeRaisesTopicsAndChannel() {
        var taste = TasteProfile()
        let c = clip("a", channel: "@sail", tags: ["#Sailing", "diy"])
        taste.record(.like, on: c)
        XCTAssertGreaterThan(taste.topics["sailing"] ?? 0, 0)
        XCTAssertGreaterThan(taste.topics["diy"] ?? 0, 0)
        XCTAssertEqual(taste.channels["ch-@sail"] ?? 0, 0.30, accuracy: 1e-9)
        XCTAssertEqual(taste.channelNames["ch-@sail"], "@sail")
        XCTAssertTrue(taste.liked.contains("a"))
        XCTAssertTrue(taste.hasSeen("a"))
    }

    func testUnlikeUndoesLike() {
        var taste = TasteProfile()
        let c = clip("a", tags: ["bitcoin"])
        taste.record(.like, on: c)
        taste.record(.unlike, on: c)
        XCTAssertEqual(taste.topics["bitcoin"] ?? 1, 0, accuracy: 1e-9)
        XCTAssertFalse(taste.liked.contains("a"))
    }

    func testWeightsAreClamped() {
        var taste = TasteProfile()
        for i in 0..<20 { taste.record(.like, on: clip("c\(i)", tags: ["bitcoin"])) }
        XCTAssertEqual(taste.topics["bitcoin"], 1)
        XCTAssertEqual(taste.channels["ch-@chan"], 1)
    }

    func testPausedIgnoresPassiveSignalsButKeepsExplicitOnes() {
        var taste = TasteProfile()
        taste.isPaused = true
        let c = clip("a", channel: "@x", tags: ["politics"])
        taste.record(.like, on: c)
        XCTAssertNil(taste.topics["politics"])
        XCTAssertTrue(taste.liked.contains("a"))
        taste.record(.lessTopic("#Politics"), on: c)
        XCTAssertEqual(taste.topics["politics"], -0.6)
        taste.record(.muteChannel, on: c)
        XCTAssertTrue(taste.mutedChannels.contains("ch-@x"))
    }

    func testExplorationIsBounded() {
        var taste = TasteProfile()
        taste.exploration = 0.9
        XCTAssertEqual(taste.exploration, 0.4)
        taste.exploration = -1
        XCTAssertEqual(taste.exploration, 0)
    }

    func testResetKeepsSettings() {
        var taste = TasteProfile()
        taste.exploration = 0.25
        taste.record(.like, on: clip("a", tags: ["x"]))
        taste.reset()
        XCTAssertTrue(taste.topics.isEmpty)
        XCTAssertTrue(taste.seen.isEmpty)
        XCTAssertEqual(taste.exploration, 0.25)
    }

    func testRoundTripsThroughJSON() throws {
        var taste = TasteProfile()
        taste.record(.like, on: clip("a", tags: ["bitcoin"]))
        taste.mutedTopics.insert("politics")
        let decoded = try JSONDecoder().decode(TasteProfile.self, from: JSONEncoder().encode(taste))
        XCTAssertEqual(decoded, taste)
    }
}

final class FeedRankerTests: XCTestCase {

    private func tasteLikingSailing() -> TasteProfile {
        var taste = TasteProfile()
        taste.exploration = 0
        taste.record(.like, on: clip("seed1", channel: "@sail", tags: ["sailing"]))
        taste.record(.like, on: clip("seed2", channel: "@sail", tags: ["sailing"]))
        taste.record(.quickSkip, on: clip("seed3", channel: "@food", tags: ["cooking"]))
        return taste
    }

    func testRanksLikedChannelAndTopicFirst() {
        let taste = tasteLikingSailing()
        var rng = SeededGenerator(seed: 1)
        let ranked = FeedRanker().rank([
            clip("cook", channel: "@food", tags: ["cooking"]),
            clip("other", channel: "@new", tags: ["gardening"]),
            clip("sail", channel: "@sail", tags: ["sailing"]),
            clip("sailNewChannel", channel: "@boats", tags: ["sailing"]),
        ], taste: taste, now: now, using: &rng)

        XCTAssertEqual(ranked.map(\.id), ["sail", "sailNewChannel", "other", "cook"])
        XCTAssertEqual(ranked[0].reason, .channel("@sail"))
        XCTAssertEqual(ranked[1].reason, .topic("sailing"))
        XCTAssertEqual(ranked[2].reason, .trending)
    }

    func testFiltersSeenMutedAndDuplicates() {
        var taste = tasteLikingSailing()
        taste.mutedTopics.insert("politics")
        taste.record(.muteChannel, on: clip("m", channel: "@loud"))
        var rng = SeededGenerator(seed: 1)
        let ranked = FeedRanker().rank([
            clip("seed1", channel: "@sail", tags: ["sailing"]),   // already seen
            clip("pol", tags: ["Politics"]),                        // muted topic
            clip("loud2", channel: "@loud"),                        // muted channel
            clip("ok", tags: ["sailing"]),
            clip("ok", tags: ["sailing"]),                          // duplicate
        ], taste: taste, now: now, using: &rng)
        XCTAssertEqual(ranked.map(\.id), ["ok"])
    }

    func testExplorationSlotsUseUnfamiliarClips() {
        var taste = tasteLikingSailing()
        taste.exploration = 0.25      // every 4th slot
        var candidates = (0..<6).map { clip("s\($0)", channel: "@sail", tags: ["sailing"]) }
        candidates += (0..<3).map { clip("n\($0)", channel: "@new\($0)", tags: ["gardening"]) }
        var rng = SeededGenerator(seed: 42)
        let ranked = FeedRanker().rank(candidates, taste: taste, now: now, using: &rng)

        XCTAssertEqual(ranked.count, 9)
        XCTAssertEqual(ranked[3].reason, .exploring)
        XCTAssertEqual(ranked[7].reason, .exploring)
        XCTAssertTrue(ranked[3].id.hasPrefix("n"))
        XCTAssertTrue(ranked[7].id.hasPrefix("n"))
        XCTAssertTrue(ranked[0..<3].allSatisfy { $0.id.hasPrefix("s") })
    }

    func testFresherWinsWhenTasteIsEqual() {
        var rng = SeededGenerator(seed: 1)
        var taste = TasteProfile()
        taste.exploration = 0
        let ranked = FeedRanker().rank([
            clip("old", ageDays: 10),
            clip("new", ageDays: 0.5),
        ], taste: taste, now: now, using: &rng)
        XCTAssertEqual(ranked.map(\.id), ["new", "old"])
    }

    func testReasonText() {
        XCTAssertEqual(RankedClaim.Reason.topic("bitcoin").text, "Matches #bitcoin")
        XCTAssertEqual(RankedClaim.Reason.channel("@sail").text, "You liked clips from @sail")
        XCTAssertEqual(RankedClaim.Reason.exploring.text, "Exploring: new to you")
    }
}

final class ShortsFeedTests: XCTestCase {

    func testQueriesFollowTaste() throws {
        var taste = TasteProfile()
        taste.record(.like, on: clip("a", channel: "@sail", tags: ["sailing"]))
        taste.mutedTopics.insert("politics")

        let queries = ShortsFeed().queries(for: taste, page: 2, blockedTags: ["nsfw"])
        XCTAssertEqual(queries.count, 3)   // trending, liked channels, top topics
        XCTAssertEqual(queries[1].channelIDs, ["ch-@sail"])
        XCTAssertEqual(queries[2].anyTags, ["sailing"])
        for q in queries {
            XCTAssertEqual(q.duration, "<=180")
            XCTAssertEqual(q.page, 2)
            XCTAssertEqual(q.notTags, ["nsfw", "politics"])
        }
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(queries[0]), encoding: .utf8))
        XCTAssertTrue(json.contains("\"duration\":\"<=180\""))
    }

    func testNewViewerGetsTrendingOnly() {
        XCTAssertEqual(ShortsFeed().queries(for: TasteProfile(), page: 1, blockedTags: []).count, 1)
    }

    func testFollowingQueryAndTimeline() {
        var library = UserLibrary()
        let feed = ShortsFeed()
        XCTAssertNil(feed.followingQuery(library: library, taste: TasteProfile(), page: 1, blockedTags: []))

        library.follow(ChannelRef(claimId: "ch-@sail", name: "@sail", canonicalURL: nil, value: nil), at: now)
        library.follow(ChannelRef(claimId: "ch-@loud", name: "@loud", canonicalURL: nil, value: nil), at: now)
        var taste = TasteProfile()
        taste.mutedChannels.insert("ch-@loud")
        taste.mutedTopics.insert("politics")
        taste.markSeen("old")   // seen in For you: still shown in Following

        let q = feed.followingQuery(library: library, taste: taste, page: 3, blockedTags: ["nsfw"])
        XCTAssertEqual(q?.channelIDs, ["ch-@sail"])
        XCTAssertEqual(q?.duration, "<=180")
        XCTAssertEqual(q?.orderBy, ["release_time"])
        XCTAssertEqual(q?.page, 3)
        XCTAssertEqual(q?.notTags, ["nsfw", "politics"])

        let timeline = feed.followingTimeline([
            clip("old", channel: "@sail", ageDays: 3),
            clip("new", channel: "@sail", ageDays: 0.1),
            clip("new", channel: "@sail", ageDays: 0.1),
            clip("pol", channel: "@sail", tags: ["politics"]),
            clip("loud", channel: "@loud"),
        ], taste: taste, filter: ContentFilter())
        XCTAssertEqual(timeline.map(\.id), ["new", "old"])
        XCTAssertEqual(timeline[0].reason, .following("@sail"))
        XCTAssertEqual(timeline[0].reason.text, "You follow @sail")
    }
}

/// Issue #17: the hubs honour `duration` (it's a range field in the hub's search, and
/// Odysee's own Shorts query is `duration: "<=180"`), but a video with no length in its
/// metadata is indexed as 0, so the feeds also check lengths on the phone.
final class DurationSplitTests: XCTestCase {

    func testShortsKeepsOnlyKnownShortLengths() {
        let feed = ShortsFeed()
        XCTAssertTrue(feed.isShort(clip("a", seconds: 1)))
        XCTAssertTrue(feed.isShort(clip("b", seconds: 180)))
        XCTAssertFalse(feed.isShort(clip("c", seconds: 181)))
        XCTAssertFalse(feed.isShort(clip("d", seconds: 0)), "no length in metadata")
        XCTAssertFalse(feed.isShort(clip("e", seconds: nil)))
    }

    func testFollowingTimelineDropsLongAndUnknown() {
        let claims = [clip("short", seconds: 45), clip("long", seconds: 900), clip("unknown", seconds: 0)]
        let ids = ShortsFeed().followingTimeline(claims, taste: TasteProfile(), filter: ContentFilter()).map(\.claim.claimId)
        XCTAssertEqual(ids, ["short"])
    }

    func testHomeKeepsOnlyLongVideos() {
        let feed = HomeFeed()
        XCTAssertTrue(feed.isLong(clip("a", seconds: 181)))
        XCTAssertFalse(feed.isLong(clip("b", seconds: 180)))
        XCTAssertFalse(feed.isLong(clip("c", seconds: nil)))
        let page = feed.page(results: [.trending: [clip("long", seconds: 1200), clip("short", seconds: 40)]],
                             taste: TasteProfile(), library: UserLibrary(), now: now)
        let shown = ([page.featured].compactMap { $0 } + page.rows.flatMap(\.items)).map(\.claim.claimId)
        XCTAssertTrue(shown.contains("long"))
        XCTAssertFalse(shown.contains("short"))
    }
}
