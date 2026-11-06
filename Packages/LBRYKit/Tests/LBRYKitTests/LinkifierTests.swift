import XCTest
@testable import LBRYKit

final class LinkifierTests: XCTestCase {

    /// Trimmed from a real description (Switched to Linux).
    private let description = """
    The latest Linux Mint update gives us new upcoming features.
    #linuxmint #linux

    https://blog.linuxmint.com/?p=5093

    Support: https://switchedtolinux.com/support
    🛒 Amazon: http://tlm.li/amazon.
    Social Media:
    🐦 Twitter: @switchedtolinux
    Reddit: /r/switchedtolinux
    Also on LBRY: @SwitchedToLinux:7 and lbry://@Odysee#8
    Mail me: tom@example.com
    """

    private func found(_ text: String) -> [(String, String, Linkifier.Kind)] {
        Linkifier.links(in: text).map { (String(text[$0.range]), $0.url.absoluteString, $0.kind) }
    }

    func testRealDescription() {
        let links = found(description)
        let byText = Dictionary(links.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })

        XCTAssertEqual(byText["https://blog.linuxmint.com/?p=5093"]?.1, .web)
        XCTAssertEqual(byText["https://switchedtolinux.com/support"]?.1, .web)
        XCTAssertEqual(byText["http://tlm.li/amazon"]?.1, .web, "trailing full stop is not part of the link")

        XCTAssertEqual(byText["@switchedtolinux"]?.0, "https://x.com/switchedtolinux")
        XCTAssertEqual(byText["@switchedtolinux"]?.1, .x)

        XCTAssertEqual(byText["/r/switchedtolinux"]?.0, "https://www.reddit.com/r/switchedtolinux")
        XCTAssertEqual(byText["/r/switchedtolinux"]?.1, .reddit)

        XCTAssertEqual(byText["@SwitchedToLinux:7"]?.0, "lbry://@SwitchedToLinux#7")
        XCTAssertEqual(byText["@SwitchedToLinux:7"]?.1, .lbry)
        XCTAssertEqual(byText["lbry://@Odysee#8"]?.1, .lbry)

        XCTAssertFalse(links.contains { $0.0.contains("example.com") }, "emails are not handles")
        XCTAssertFalse(links.contains { $0.0.hasPrefix("#") }, "hashtags are left alone")
    }

    func testKnownHosts() {
        XCTAssertEqual(found("see https://twitter.com/jack/status/20")[0].2, .x)
        XCTAssertEqual(found("see https://www.reddit.com/r/LBRY/")[0].2, .reddit)
        XCTAssertEqual(found("see https://odysee.com/@chan:a/video:b")[0].2, .lbry)
    }

    func testXLineVariants() {
        XCTAssertEqual(found("X: @lbryio")[0].1, "https://x.com/lbryio")
        XCTAssertEqual(found("Follow me on X @lbryio")[0].1, "https://x.com/lbryio")
        XCTAssertEqual(found("Watch @lbryio here")[0].1, "lbry://@lbryio")
    }

    func testRedditShorthands() {
        XCTAssertEqual(found("join r/LBRY today")[0].1, "https://www.reddit.com/r/LBRY")
        XCTAssertEqual(found("ask u/spez")[0].1, "https://www.reddit.com/user/spez")
        XCTAssertTrue(found("https://example.com/r/notreddit").allSatisfy { $0.2 == .web })
    }

    func testURLWithParenthesesKeepsClosingParen() {
        XCTAssertEqual(found("(https://en.wikipedia.org/wiki/LBRY_(protocol))")[0].0,
                       "https://en.wikipedia.org/wiki/LBRY_(protocol)")
    }

    func testAttributedStringCarriesLinks() {
        let attributed = Linkifier.attributed("Twitter: @me")
        let urls = attributed.runs.compactMap { $0.link }
        XCTAssertEqual(urls, [URL(string: "https://x.com/me")!])
    }
}
