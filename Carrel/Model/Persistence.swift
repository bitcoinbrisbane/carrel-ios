import Foundation
import LBRYKit

/// Saves the taste profile as JSON in Application Support. Local only: excluded
/// from iCloud backup until we add an encrypted wallet backup.
enum TasteStore {

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Carrel", isDirectory: true)
        return dir.appendingPathComponent("taste.json")
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
