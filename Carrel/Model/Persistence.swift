import Foundation
import LBRYKit

/// Saves the taste profile as JSON in Application Support. Local only: excluded
/// from iCloud backup until we add an encrypted wallet backup.
enum TasteStore {

    static var url: URL {
        #if os(tvOS)
        // tvOS apps may only keep files in Caches (the system can purge it when short of space).
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Carrel", isDirectory: true).appendingPathComponent("taste.json")
    }

    static func load() -> TasteProfile {
        guard let data = try? Data(contentsOf: url),
              let taste = try? JSONDecoder().decode(TasteProfile.self, from: data) else {
            return TasteProfile()
        }
        return taste
    }

    static func save(_ taste: TasteProfile) {
        do {
            var dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try JSONEncoder().encode(taste).write(to: url, options: .atomic)
        } catch {
            // Best effort: a lost write only costs a little learning.
        }
    }
}

/// Follows and watch history.
enum LibraryStore {
    static var url: URL {
        TasteStore.url.deletingLastPathComponent().appendingPathComponent("library.json")
    }

    static func load() -> UserLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(UserLibrary.self, from: data) else { return UserLibrary() }
        return library
    }

    static func save(_ library: UserLibrary) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(library).write(to: url, options: .atomic)
    }
}

/// The encrypted taste + library backup in iCloud key-value storage. The blob is
/// sealed with a key from the wallet phrase (EncryptedBackup), so Apple can't read it.
/// Syncs only when the app has the iCloud key-value storage capability (see README);
/// without it, the store keeps the value on this device only.
enum CloudBackupStore {
    static let key = "carrel.backup.v1"
    static var store: NSUbiquitousKeyValueStore { .default }

    static func save(_ blob: Data, at date: Date = Date()) {
        store.set(blob, forKey: key)
        store.set(date, forKey: key + ".date")
        store.synchronize()
    }

    static func load() -> Data? {
        store.synchronize()
        return store.data(forKey: key)
    }

    static var lastSaved: Date? { store.object(forKey: key + ".date") as? Date }
}

/// The CarrelChain header window (last 100 validated headers), so launches sync
/// only what's new instead of starting from the checkpoint each time.
enum ChainStore {
    static var url: URL {
        TasteStore.url.deletingLastPathComponent().appendingPathComponent("headers.json")
    }

    static func load() -> HeaderChain? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HeaderChain.self, from: data)
    }

    static func save(_ chain: HeaderChain) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(chain).write(to: url, options: .atomic)
    }
}

/// Streaming URLs from the SDK's `get`, cached so the next clips can be
/// fetched ahead of time and play instantly when swiped to.
actor StreamURLCache {
    private var urls: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    func url(for claim: Claim, client: LBRYClient) async throws -> URL {
        if let url = urls[claim.claimId] { return url }
        if let task = inFlight[claim.claimId] { return try await task.value }
        let task = Task { try await client.streamingURL(for: claim.lbryURL) }
        inFlight[claim.claimId] = task
        defer { inFlight[claim.claimId] = nil }
        let url = try await task.value
        urls[claim.claimId] = url
        return url
    }

    func prefetch(_ claims: [Claim], client: LBRYClient) {
        for claim in claims where urls[claim.claimId] == nil && inFlight[claim.claimId] == nil {
            Task { _ = try? await self.url(for: claim, client: client) }
        }
    }
}

/// Ethereum transactions Carrel sent, so mints, sends and unwraps can be followed
/// (and unwrap payouts requested) even if the app was closed in between.
struct EthereumActivity: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case send, mint, unwrap }
    enum State: String, Codable {
        case submitted        // broadcast, not mined yet
        case confirmed        // mined and succeeded (sends and mints end here)
        case awaitingPayout   // unwrap mined; waiting for 12 confirmations and the LBC payout
        case paid             // unwrap: the bridge paid the LBC
        case failed
    }

    let hash: String
    let kind: Kind
    let title: String
    let date: Date
    var state: State
    var detail: String?
    var id: String { hash }

    var isOpen: Bool { state == .submitted || state == .awaitingPayout }
}

enum EthereumActivityStore {
    static var url: URL {
        TasteStore.url.deletingLastPathComponent().appendingPathComponent("eth-activity.json")
    }

    static func load() -> [EthereumActivity] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([EthereumActivity].self, from: data)) ?? []
    }

    static func save(_ items: [EthereumActivity]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(items.prefix(50))).write(to: url, options: .atomic)
    }
}

// MARK: - Moderation (Guideline 1.2), shared with Apple TV

/// The viewer's blocked channels and hidden videos.
enum BlockStore {
    private static let key = "carrel.blocks.v1"
    static func load() -> UserBlocks {
        guard let data = UserDefaults.standard.data(forKey: key) else { return UserBlocks() }
        return (try? JSONDecoder().decode(UserBlocks.self, from: data)) ?? UserBlocks()
    }
    static func save(_ blocks: UserBlocks) {
        UserDefaults.standard.set(try? JSONEncoder().encode(blocks), forKey: key)
    }
}

/// Last copy of Carrel's published moderation list, so it applies offline too.
enum ModerationStore {
    private static let key = "carrel.moderation.v1"
    static func load() -> ModerationList? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ModerationList.self, from: $0) }
    }
    static func save(_ list: ModerationList) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

/// Support contact and policies, from Info.plist (set in project.yml).
enum Support {
    static var email: String { info("CarrelSupportEmail") ?? "" }
    static var privacyURL: URL? { info("CarrelPrivacyPolicyURL").flatMap(URL.init(string:)) }
    static var hasEmail: Bool { email.contains("@") }

    /// Terms accepted on first launch; bump the version to ask again after changing them.
    static let termsVersion = 1
    static var termsAccepted: Bool {
        get { UserDefaults.standard.integer(forKey: "carrel.terms.accepted") >= termsVersion }
        set { UserDefaults.standard.set(newValue ? termsVersion : 0, forKey: "carrel.terms.accepted") }
    }

    static let terms = """
    Carrel is a player for the LBRY network. The videos and channels you see are published by other people on an open network; Carrel doesn't host or create them.

    By using Carrel you agree to Apple's standard licence terms for apps, and to this: there is no tolerance for objectionable content or abusive users. Don't use Carrel to find, share or promote illegal content, sexual content involving minors, threats, harassment or hate.

    Carrel filters mature content by default. You can report any video or channel, and block any channel so you never see it again. Reports are reviewed within 24 hours; content that breaks these terms is removed from Carrel and its channel blocked for everyone.

    Your wallet and keys stay on your devices. Carrel can't recover them or reverse a transaction.
    """

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
