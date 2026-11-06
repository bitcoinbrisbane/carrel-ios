import XCTest
@testable import LBRYKit

final class BackupTests: XCTestCase {

    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let now = Date(timeIntervalSince1970: 1_762_400_000)

    private func video(_ id: String, description: String? = nil) -> Claim {
        Claim(claimId: id, name: id, canonicalURL: nil, permanentURL: nil, valueType: "stream", timestamp: nil,
              signingChannel: ChannelRef(claimId: "ch", name: "@chan", canonicalURL: nil, value: nil),
              value: ClaimValue(title: "Title \(id)", description: description, thumbnail: .init(url: "https://x/\(id).jpg"),
                                cover: nil, tags: ["sailing"], releaseTime: nil, streamType: "video",
                                video: .init(duration: 600), audio: nil, source: nil))
    }

    private func sample() -> BackupPayload {
        var taste = TasteProfile()
        taste.record(.like, on: video("a"))
        taste.mutedTopics.insert("politics")
        taste.exploration = 0.2
        var library = UserLibrary()
        library.follow(ChannelRef(claimId: "ch", name: "@chan", canonicalURL: nil, value: nil), at: now)
        library.recordProgress(video("a", description: "long description"), position: 120, duration: 600, at: now)
        return BackupPayload(taste: taste, library: library, createdAt: now)
    }

    func testRoundTripWithTheSamePhrase() throws {
        let payload = sample()
        let blob = try EncryptedBackup.seal(payload, phrase: phrase)
        XCTAssertEqual(Array(blob.prefix(4)), Array("CRB1".utf8))
        let opened = try EncryptedBackup.open(blob, phrase: phrase)
        XCTAssertEqual(opened.taste, payload.taste)
        XCTAssertEqual(opened.library.following, payload.library.following)
        XCTAssertEqual(opened.library.history.first?.position, 120)
        XCTAssertEqual(opened.library.history.first?.claim.title, "Title a")
        XCTAssertNil(opened.library.history.first?.claim.value?.description, "descriptions aren't backed up")
    }

    func testOtherPhraseCannotRead() throws {
        let blob = try EncryptedBackup.seal(sample(), phrase: phrase)
        let other = "legal winner thank year wave sausage worth useful legal winner thank yellow"
        XCTAssertThrowsError(try EncryptedBackup.open(blob, phrase: other)) { error in
            XCTAssertEqual(error as? EncryptedBackup.Error, .cannotDecrypt)
        }
    }

    func testTamperingIsDetected() throws {
        var blob = try EncryptedBackup.seal(sample(), phrase: phrase)
        blob[blob.count - 5] ^= 0x01
        XCTAssertThrowsError(try EncryptedBackup.open(blob, phrase: phrase))
        XCTAssertThrowsError(try EncryptedBackup.open(Data("hello".utf8), phrase: phrase)) { error in
            XCTAssertEqual(error as? EncryptedBackup.Error, .notABackup)
        }
    }

    func testKeyIsStableAndSeparateFromTheWallet() throws {
        let k1 = EncryptedBackup.key(phrase: phrase).withUnsafeBytes { Array($0) }
        let k2 = EncryptedBackup.key(phrase: "  Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ABOUT ").withUnsafeBytes { Array($0) }
        XCTAssertEqual(k1, k2, "same phrase, however it's typed")
        XCTAssertEqual(k1.count, 32)
        XCTAssertNotEqual(k1, Array(Mnemonic.lbrySeed(phrase).prefix(32)))
        XCTAssertNotEqual(k1, try WalletAccount(phrase: phrase).privateKey(.receive, 0))
    }

    func testBigLibrariesAreTrimmedToFit() throws {
        var library = UserLibrary()
        let filler = String(repeating: "x", count: 4_000)
        for i in 0..<UserLibrary.historyLimit {
            // Random titles that don't compress, so the backup really overflows and must trim.
            let noise = (0..<2_000).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let claim = Claim(claimId: "v\(i)", name: "v\(i)", canonicalURL: nil, permanentURL: nil, valueType: "stream",
                              timestamp: nil, signingChannel: nil,
                              value: ClaimValue(title: "\(i) \(noise)", description: filler,
                                                thumbnail: nil, cover: nil, tags: nil, releaseTime: nil, streamType: nil,
                                                video: nil, audio: nil, source: nil))
            library.recordProgress(claim, position: 60, duration: 600, at: now.addingTimeInterval(Double(i)))
        }
        let blob = try EncryptedBackup.seal(BackupPayload(taste: TasteProfile(), library: library, createdAt: now), phrase: phrase)
        XCTAssertLessThanOrEqual(blob.count, EncryptedBackup.maxSize)
        let opened = try EncryptedBackup.open(blob, phrase: phrase)
        XCTAssertGreaterThan(opened.library.history.count, 0)
        XCTAssertLessThan(opened.library.history.count, UserLibrary.historyLimit, "oldest history was trimmed")
        XCTAssertEqual(opened.library.history.first?.id, "v\(UserLibrary.historyLimit - 1)", "newest kept")
    }

    func testMergeKeepsNewestAndUnitesFollows() {
        var phone = UserLibrary()
        phone.follow(ChannelRef(claimId: "c1", name: "@one", canonicalURL: nil, value: nil), at: now)
        phone.recordProgress(video("a"), position: 50, duration: 600, at: now)
        var backup = UserLibrary()
        backup.follow(ChannelRef(claimId: "c2", name: "@two", canonicalURL: nil, value: nil), at: now)
        backup.recordProgress(video("a"), position: 300, duration: 600, at: now.addingTimeInterval(60))
        backup.recordProgress(video("b"), position: 100, duration: 600, at: now.addingTimeInterval(-60))

        let merged = phone.merged(with: backup)
        XCTAssertEqual(Set(merged.followedChannelIDs), ["c1", "c2"])
        XCTAssertEqual(merged.history.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.entry(for: "a")?.position, 300, "the newer watch wins")
    }
}
