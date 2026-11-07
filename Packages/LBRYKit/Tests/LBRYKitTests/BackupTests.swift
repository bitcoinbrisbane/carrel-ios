import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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

/// Issue #18: iPhone ↔ Apple TV sync.
final class SyncTests: XCTestCase {

    private func video(_ id: String, channel: String, tags: [String]) -> Claim {
        Claim(claimId: id, name: id, canonicalURL: nil, permanentURL: nil, valueType: "stream", timestamp: nil,
              signingChannel: ChannelRef(claimId: "ch-\(channel)", name: channel, canonicalURL: nil, value: nil),
              value: ClaimValue(title: id, description: nil, thumbnail: nil, cover: nil, tags: tags, releaseTime: nil,
                                streamType: "video", video: .init(duration: 600), audio: nil, source: nil))
    }

    func testTasteMergeIsOrderIndependentAndRepeatable() {
        var phone = TasteProfile()
        phone.record(.like, on: video("p1", channel: "@sail", tags: ["sailing"]))
        phone.record(.like, on: video("p2", channel: "@sail", tags: ["sailing"]))
        phone.mutedTopics.insert("politics")
        var tv = TasteProfile()
        tv.record(.like, on: video("t1", channel: "@cook", tags: ["cooking"]))
        tv.record(.lessTopic("sailing"), on: video("t2", channel: "@x", tags: ["sailing"]))   // -0.6
        tv.exploration = 0.3

        let a = phone.merged(with: tv), b = tv.merged(with: phone)
        XCTAssertEqual(a.topics, b.topics)
        XCTAssertEqual(a.channels, b.channels)
        XCTAssertEqual(a.topics["sailing"], -0.6, "the stronger opinion wins")
        XCTAssertNotNil(a.topics["cooking"])
        XCTAssertEqual(a.mutedTopics, ["politics"])
        XCTAssertEqual(a.liked, ["p1", "p2", "t1"])
        XCTAssertTrue(a.hasSeen("t2") && a.hasSeen("p1"))
        XCTAssertEqual(a.exploration, 0.1, "settings stay this device's")
        XCTAssertEqual(b.exploration, 0.3)
        XCTAssertEqual(a.merged(with: tv), a, "merging again changes nothing")
    }

    func testBackupKeyRoundTripAndPayloadMerge() throws {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let key = EncryptedBackup.key(phrase: phrase)
        var phoneLib = UserLibrary()
        phoneLib.follow(ChannelRef(claimId: "ch-@sail", name: "@sail", canonicalURL: nil, value: nil))
        let phone = BackupPayload(taste: TasteProfile(), library: phoneLib)
        let blob = try EncryptedBackup.seal(phone, key: key)
        XCTAssertEqual(try EncryptedBackup.open(blob, phrase: phrase).library.following.map(\.claimId), ["ch-@sail"],
                       "key and phrase forms are interchangeable")

        var tvLib = UserLibrary()
        tvLib.follow(ChannelRef(claimId: "ch-@cook", name: "@cook", canonicalURL: nil, value: nil))
        let merged = BackupPayload(taste: TasteProfile(), library: tvLib).merged(with: try EncryptedBackup.open(blob, key: key))
        XCTAssertEqual(Set(merged.library.following.map(\.claimId)), ["ch-@sail", "ch-@cook"])
    }

    func testPairingHandsTheBackupKeyToTheTVOnly() throws {
        let key = SymmetricKey(size: .bits256)
        let request = TVPairing.Request(id: "K7Q2XM")
        let link = request.link.absoluteString
        XCTAssertTrue(link.hasPrefix("carrel://pair-tv?id=K7Q2XM&pk="))

        let offer = try TVPairing.Offer(link: link)
        XCTAssertEqual(offer.id, "K7Q2XM")
        let sealed = try offer.seal(backupKey: key)
        let opened = try request.open(sealed)
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })

        XCTAssertThrowsError(try TVPairing.Request(id: "K7Q2XM").open(sealed), "another TV's key can't open it")
        XCTAssertThrowsError(try TVPairing.Request(id: "OTHER1", privateKey: request.privateKey).open(sealed),
                             "bound to the pairing id")
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try request.open(tampered))
        XCTAssertThrowsError(try TVPairing.Offer(link: "carrel://pair-tv?id=X&pk=short"))
        XCTAssertThrowsError(try TVPairing.Offer(link: "https://example.com/pair-tv?id=X&pk=AAAA"))
    }
}
