import XCTest
@testable import LBRYKit

final class LBRYURLTests: XCTestCase {

    func testLBRYURLPassesThrough() {
        XCTAssertEqual(LBRYURL.normalise("lbry://@chan#a/video#b"), "lbry://@chan#a/video#b")
    }

    func testOdyseeWebURL() {
        XCTAssertEqual(
            LBRYURL.normalise("https://odysee.com/@chan:a/video:b"),
            "lbry://@chan#a/video#b"
        )
    }

    func testBareOdyseePath() {
        XCTAssertEqual(LBRYURL.normalise("@chan:a"), "lbry://@chan#a")
    }

    func testRejectsOtherHosts() {
        XCTAssertNil(LBRYURL.normalise("https://youtube.com/watch?v=x"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(LBRYURL.normalise("   "))
    }
}

final class DecodingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDecodesResolveWithErrorEntry() throws {
        let envelope = try JSONDecoder().decode(
            RPCResponse<[String: ResolveEntry]>.self,
            from: fixture("resolve")
        )
        let entries = try XCTUnwrap(envelope.result)
        let claim = try XCTUnwrap(entries["lbry://@carrel#c/hello#a"]?.claim)
        XCTAssertEqual(claim.title, "Hello from Carrel")
        XCTAssertEqual(claim.duration, 125)
        XCTAssertEqual(claim.signingChannel?.title, "Carrel")
        XCTAssertNotNil(claim.releaseDate)
        XCTAssertEqual(claim.address, "bMg8mCxn8kjZPKQ4rihZPEeq4aFMLNQf4k")
        XCTAssertNil(entries["lbry://missing"]?.claim)
    }

    func testFilterBlocksTagsAndChannels() throws {
        let envelope = try JSONDecoder().decode(
            RPCResponse<[String: ResolveEntry]>.self,
            from: fixture("resolve")
        )
        let claim = try XCTUnwrap(envelope.result?["lbry://@carrel#c/hello#a"]?.claim)
        XCTAssertTrue(ContentFilter().allows(claim))
        XCTAssertFalse(ContentFilter(blockedChannelIDs: ["c0ffee"]).allows(claim))
        XCTAssertFalse(ContentFilter(blockedTags: ["demo"]).allows(claim))
    }

    func testClaimSearchParamsOmitNils() throws {
        var p = ClaimSearchParams()
        p.notTags = nil
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(p), encoding: .utf8))
        XCTAssertFalse(json.contains("not_tags"))
        XCTAssertTrue(json.contains("\"page_size\":20"))
    }
}

/// Guideline 1.2: blocks, the moderation list and reports.
final class ModerationTests: XCTestCase {

    private func video(_ id: String, channel: String? = "@chan", tags: [String] = []) -> Claim {
        Claim(claimId: id, name: id, canonicalURL: "lbry://\(channel ?? "")#c/\(id)#\(id)", permanentURL: nil, valueType: "stream",
              timestamp: nil,
              signingChannel: channel.map { ChannelRef(claimId: "ch-\($0)", name: $0, canonicalURL: nil, value: nil) },
              value: ClaimValue(title: "Title \(id)", description: nil, thumbnail: nil, cover: nil, tags: tags, releaseTime: nil,
                                streamType: "video", video: .init(duration: 600), audio: nil, source: nil))
    }

    func testCombinedFilter() throws {
        var blocks = UserBlocks()
        blocks.block(channelID: "ch-@bad", name: "@bad")
        blocks.hide(claimID: "reported")
        let server = try JSONDecoder().decode(ModerationList.self, from: Data(
            #"{"updated":"2026-11-07","claims":["removed"],"channels":["ch-@banned"],"tags":["Gore"]}"#.utf8))
        let filter = ContentFilter.combined(user: blocks, server: server)

        let claims = [video("ok"), video("a", channel: "@bad"), video("reported"), video("removed"),
                      video("b", channel: "@banned"), video("c", tags: ["gore"]), video("d", tags: ["nsfw"])]
        XCTAssertEqual(filter.apply(claims).map(\.claimId), ["ok"])

        // A blocked channel's own page is hidden too.
        let channelClaim = Claim(claimId: "ch-@bad", name: "@bad", canonicalURL: nil, permanentURL: nil, valueType: "channel",
                                 timestamp: nil, signingChannel: nil, value: nil)
        XCTAssertFalse(filter.allows(channelClaim))

        XCTAssertTrue(ContentFilter.combined(user: UserBlocks(), server: nil).allows(video("x")))
        blocks.unblock(channelID: "ch-@bad")
        XCTAssertTrue(ContentFilter.combined(user: blocks, server: nil).allows(video("a", channel: "@bad")))
        XCTAssertEqual(try JSONDecoder().decode(UserBlocks.self, from: JSONEncoder().encode(blocks)), blocks)
    }

    func testReportEmail() throws {
        var report = ContentReport(claim: video("abc123", channel: "@chan"), reason: .spam, note: "  Crypto giveaway scam  ")
        XCTAssertEqual(report.subject, "Carrel report: Spam or scam – video abc123")
        XCTAssertTrue(report.body.contains("Claim ID: abc123"))
        XCTAssertTrue(report.body.contains("Channel: @chan (ch-@chan)"))
        XCTAssertTrue(report.body.contains("\n\nCrypto giveaway scam\n"))
        let url = try XCTUnwrap(report.mailtoURL(to: "support@example.com"))
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:support@example.com?subject=Carrel%20report"))

        report = ContentReport(channel: ChannelRef(claimId: "ch1", name: "@someone", canonicalURL: nil, value: nil), reason: .hate)
        XCTAssertTrue(report.isChannel)
        XCTAssertEqual(report.channelID, "ch1")
        XCTAssertTrue(report.subject.contains("channel ch1"))
    }
}
