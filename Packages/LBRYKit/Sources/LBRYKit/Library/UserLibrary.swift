import Foundation

/// The viewer's own things, kept on the device: channels they follow and what
/// they've watched (with where they stopped). No account, nothing uploaded.
public struct UserLibrary: Codable, Equatable, Sendable {

    public struct FollowedChannel: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let claimId: String
        public let name: String
        public var title: String
        public var thumbnailURL: String?
        public let followedAt: Date
        public var id: String { claimId }
        public var lbryURL: String { "lbry://\(name)#\(claimId)" }
    }

    public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
        public private(set) var claim: Claim
        /// Seconds into the video where the viewer stopped.
        public var position: Double
        /// Length in seconds, from the player when known, else from the claim.
        public var duration: Double?
        public var lastWatched: Date
        public var id: String { claim.claimId }

        mutating func replaceClaim(_ claim: Claim) {
            self.claim = claim
        }

        /// 0…1, or nil when the length isn't known.
        public var progress: Double? {
            guard let duration, duration > 0 else { return nil }
            return min(1, max(0, position / duration))
        }
    }

    public private(set) var following: [FollowedChannel] = []
    /// Newest first.
    public private(set) var history: [HistoryEntry] = []
    public static let historyLimit = 500

    public init() {}

    // MARK: Following

    public func isFollowing(_ channelID: String) -> Bool {
        following.contains { $0.claimId == channelID }
    }

    public mutating func follow(_ channel: ChannelRef, at date: Date = Date()) {
        guard !isFollowing(channel.claimId) else { return }
        following.append(FollowedChannel(
            claimId: channel.claimId, name: channel.name, title: channel.title,
            thumbnailURL: channel.value?.thumbnail?.url, followedAt: date
        ))
    }

    /// Follow from a channel claim itself (the channel page).
    public mutating func follow(channelClaim claim: Claim, at date: Date = Date()) {
        follow(ChannelRef(claimId: claim.claimId, name: claim.name, canonicalURL: claim.canonicalURL, value: claim.value), at: date)
    }

    public mutating func unfollow(_ channelID: String) {
        following.removeAll { $0.claimId == channelID }
    }

    public var followedChannelIDs: [String] { following.map(\.claimId) }

    // MARK: History

    /// Record (or update) where the viewer is in a video.
    public mutating func recordProgress(_ claim: Claim, position: Double, duration: Double?, at date: Date = Date()) {
        let length = duration ?? claim.duration.map(Double.init)
        if let i = history.firstIndex(where: { $0.claim.claimId == claim.claimId }) {
            var entry = history.remove(at: i)
            entry.position = max(0, position)
            if let length { entry.duration = length }
            entry.lastWatched = date
            history.insert(entry, at: 0)
        } else {
            history.insert(HistoryEntry(claim: claim, position: max(0, position), duration: length, lastWatched: date), at: 0)
        }
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    public func entry(for claimID: String) -> HistoryEntry? {
        history.first { $0.claim.claimId == claimID }
    }

    /// Where to resume, or nil to start from the beginning (unstarted, nearly finished, or under 30 s in).
    public func resumePosition(for claimID: String) -> Double? {
        guard let entry = entry(for: claimID), entry.position >= 30 else { return nil }
        if let p = entry.progress, p >= 0.95 { return nil }
        return entry.position
    }

    /// Started but not finished: between 5% and 95% through (or 30 s in, if the length is unknown).
    public func continueWatching(limit: Int = 10) -> [HistoryEntry] {
        Array(history.lazy.filter { entry in
            if let p = entry.progress { return p >= 0.05 && p < 0.95 }
            return entry.position >= 30
        }.prefix(limit))
    }

    public mutating func removeFromHistory(_ claimID: String) {
        history.removeAll { $0.claim.claimId == claimID }
    }

    public mutating func clearHistory() {
        history.removeAll()
    }

    mutating func replaceHistory(_ entries: [HistoryEntry]) {
        history = Array(entries.prefix(Self.historyLimit))
    }

    /// Combine with a restored copy: follows are united, history keeps the most
    /// recent entry per video, newest first.
    public func merged(with other: UserLibrary) -> UserLibrary {
        var out = self
        for channel in other.following where !out.isFollowing(channel.claimId) {
            out.following.append(channel)
        }
        var byID: [String: HistoryEntry] = [:]
        for entry in history + other.history {
            if let existing = byID[entry.id], existing.lastWatched >= entry.lastWatched { continue }
            byID[entry.id] = entry
        }
        out.replaceHistory(byID.values.sorted { $0.lastWatched > $1.lastWatched })
        return out
    }

    public var isEmpty: Bool { following.isEmpty && history.isEmpty }
}
