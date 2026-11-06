import XCTest
@testable import LBRYKit

final class ReactionsTests: XCTestCase {

    func testParsesOdyseeReactionList() throws {
        // Shape from odysee-frontend (redux/selectors/reactions.ts): data.others_reactions[id].like
        let json = """
        {"success": true, "error": null, "data": {
          "my_reactions": {"aa": {"like": 0, "dislike": 0}},
          "others_reactions": {"aa": {"like": 1234, "dislike": 12}, "bb": {"like": "7", "dislike": 0}}
        }}
        """
        let counts = try OdyseeReactions.parseList(Data(json.utf8))
        XCTAssertEqual(counts["aa"], ReactionCounts(likes: 1234, dislikes: 12))
        XCTAssertEqual(counts["bb"]?.likes, 7, "numbers as strings are tolerated")
    }

    func testAPIErrorsSurface() {
        let json = #"{"success": false, "error": "auth_token is required", "data": null}"#
        XCTAssertThrowsError(try OdyseeReactions.parseList(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OdyseeReactions.ReactionError, .api("auth_token is required"))
        }
        XCTAssertTrue(OdyseeReactions.looksLikeAuthError("auth_token is required"))
        XCTAssertFalse(OdyseeReactions.looksLikeAuthError("rate limited"))
    }

    func testCompactCounts() {
        XCTAssertEqual(ReactionCounts.compact(0), "0")
        XCTAssertEqual(ReactionCounts.compact(842), "842")
        XCTAssertEqual(ReactionCounts.compact(1_000), "1k")
        XCTAssertEqual(ReactionCounts.compact(1_250), "1.2k")
        XCTAssertEqual(ReactionCounts.compact(15_999), "15.9k")
        XCTAssertEqual(ReactionCounts.compact(250_000), "250k")
        XCTAssertEqual(ReactionCounts.compact(3_400_000), "3.4M")
    }
}
