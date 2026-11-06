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
