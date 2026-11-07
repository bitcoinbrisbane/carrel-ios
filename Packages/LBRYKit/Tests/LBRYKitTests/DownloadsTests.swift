import XCTest
@testable import LBRYKit

/// Issue #20: offline downloads (the bookkeeping; the transfers are URLSession's).
final class DownloadsTests: XCTestCase {

    private func video(_ id: String) -> Claim {
        Claim(claimId: id, name: id, canonicalURL: nil, permanentURL: nil, valueType: "stream", timestamp: nil,
              signingChannel: nil,
              value: ClaimValue(title: id, description: nil, thumbnail: nil, cover: nil, tags: nil, releaseTime: nil,
                                streamType: "video", video: .init(duration: 600), audio: nil, source: nil))
    }

    func testIndex() throws {
        var index = DownloadIndex()
        XCTAssertTrue(index.add(DownloadRecord(claim: video("a"), kind: .file)))
        XCTAssertTrue(index.add(DownloadRecord(claim: video("b"), kind: .hls)))
        XCTAssertFalse(index.add(DownloadRecord(claim: video("a"), kind: .file)), "no duplicates")
        XCTAssertEqual(index.records.map(\.id), ["b", "a"], "newest first")

        index.update("a") { $0.state = .downloading; $0.bytesWritten = 25; $0.bytesExpected = 100 }
        XCTAssertEqual(index.record(for: "a")?.progress, 0.25)
        XCTAssertTrue(index.record(for: "a")!.isActive)
        index.update("b") { $0.fraction = 1.4 }
        XCTAssertEqual(index.record(for: "b")?.progress, 1, "clamped")

        index.update("a") { $0.state = .finished; $0.bytesWritten = 100; $0.relativePath = "Library/x/a.mp4" }
        index.update("b") { $0.state = .failed("No network") }
        XCTAssertEqual(index.finished.map(\.id), ["a"])
        XCTAssertEqual(index.finishedBytes, 100)

        let decoded = try JSONDecoder().decode(DownloadIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(decoded, index)
        XCTAssertEqual(decoded.record(for: "b")?.state, .failed("No network"))

        XCTAssertEqual(index.remove("a")?.id, "a")
        XCTAssertNil(index.record(for: "a"))
    }

    func testStreamKind() {
        let mp4 = URL(string: "https://player.odycdn.com/api/v3/streams/free/x/abc/def")!
        XCTAssertFalse(StreamKind.isHLS(url: mp4, mimeType: "video/mp4"))
        XCTAssertTrue(StreamKind.isHLS(url: mp4, mimeType: "application/x-mpegURL"))
        XCTAssertTrue(StreamKind.isHLS(url: URL(string: "https://cdn/x/master.m3u8")!, mimeType: nil))
        XCTAssertEqual(StreamKind.fileExtension(url: mp4, mimeType: "video/mp4"), "mp4")
        XCTAssertEqual(StreamKind.fileExtension(url: mp4, mimeType: "video/webm"), "webm")
        XCTAssertEqual(StreamKind.fileExtension(url: URL(string: "https://cdn/a.mov")!, mimeType: nil), "mov")
    }
}
