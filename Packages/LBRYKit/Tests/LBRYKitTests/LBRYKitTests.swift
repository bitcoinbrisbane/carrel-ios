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
