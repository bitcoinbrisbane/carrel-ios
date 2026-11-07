import Foundation

/// What Carrel has learned about one viewer, kept on the device only.
///
/// Weights run from -1 (avoid) to +1 (love). They move a little with every
/// signal, so one stray like doesn't take over the feed.
public struct TasteProfile: Codable, Equatable, Sendable {

    /// Normalised tag → weight (tags are lowercased, without `#`).
    public var topics: [String: Double] = [:]
    /// Channel claim id → weight.
    public var channels: [String: Double] = [:]
    /// Channel claim id → display name (`@name`), for the Your taste screen.
    public var channelNames: [String: String] = [:]

    public var mutedTopics: Set<String> = []
    public var mutedChannels: Set<String> = []
    public var liked: Set<String> = []

    /// Recently shown claim ids, newest last. Capped so the profile stays small.
    public private(set) var seen: [String] = []
    public static let seenLimit = 2_000

    /// Share of the feed reserved for things the viewer hasn't shown interest in yet (0…0.4).
    public var exploration: Double = 0.1 {
        didSet { exploration = min(max(exploration, 0), 0.4) }
    }

    /// While paused, watching and liking stop changing weights. Explicit choices
    /// (less of / mute) still apply, because the viewer asked for them directly.
    public var isPaused = false

    public var watchedCount = 0
    public var notForMeCount = 0

    public init() {}

    // MARK: Signals

    public enum Signal: Equatable, Sendable {
        case like
        case unlike
        /// Watched to the end (or looped).
        case watchedToEnd
        /// Swiped away within a couple of seconds.
        case quickSkip
        /// "Not interested in this video".
        case notInterested
        /// "Less from this channel".
        case lessChannel
        /// "Less of this tag".
        case lessTopic(String)
        /// "Hide this channel completely".
        case muteChannel
    }

    /// How hard each signal pushes (topic, channel). Tuned by feel; adjust freely.
    static func deltas(_ signal: Signal) -> (topic: Double, channel: Double) {
        switch signal {
        case .like: return (0.25, 0.30)
        case .unlike: return (-0.25, -0.30)
        case .watchedToEnd: return (0.10, 0.10)
        case .quickSkip: return (-0.06, -0.06)
        case .notInterested: return (-0.15, -0.10)
        case .lessChannel, .lessTopic, .muteChannel: return (0, 0)
        }
    }

    public mutating func record(_ signal: Signal, on claim: Claim) {
        let channelID = claim.signingChannel?.claimId
        if let channel = claim.signingChannel {
            channelNames[channel.claimId] = channel.name
        }

        switch signal {
        case .like:
            liked.insert(claim.claimId)
        case .unlike:
            liked.remove(claim.claimId)
        case .watchedToEnd:
            watchedCount += 1
        case .notInterested:
            notForMeCount += 1
        case .lessChannel:
            notForMeCount += 1
            if let channelID { channels[channelID] = clamp((channels[channelID] ?? 0) - 0.6) }
        case .lessTopic(let tag):
            notForMeCount += 1
            let t = Self.normalise(tag)
            topics[t] = clamp((topics[t] ?? 0) - 0.6)
        case .muteChannel:
            notForMeCount += 1
            if let channelID { mutedChannels.insert(channelID) }
        case .quickSkip:
            break
        }

        if signal != .unlike { markSeen(claim.claimId) }
        guard !isPaused else { return }

        let (topicDelta, channelDelta) = Self.deltas(signal)
        let tags = Self.tags(of: claim)
        if topicDelta != 0, !tags.isEmpty {
            // Spread the push across the clip's tags so heavily-tagged clips don't dominate.
            let share = topicDelta / Double(tags.count).squareRoot()
            for tag in tags { topics[tag] = clamp((topics[tag] ?? 0) + share) }
        }
        if channelDelta != 0, let channelID {
            channels[channelID] = clamp((channels[channelID] ?? 0) + channelDelta)
        }
    }

    public mutating func markSeen(_ claimID: String) {
        if let i = seen.firstIndex(of: claimID) { seen.remove(at: i) }
        seen.append(claimID)
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
    }

    public func hasSeen(_ claimID: String) -> Bool { seen.contains(claimID) }

    /// Combine with the same viewer's profile from another device (iPhone ↔ Apple TV).
    /// Order-independent and repeatable: for each topic or channel the stronger opinion
    /// wins (largest magnitude), mutes, likes and seen clips are combined, counts take
    /// the larger. Settings (surprise share, paused) stay this device's.
    public func merged(with other: TasteProfile) -> TasteProfile {
        func stronger(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
            a.merging(b) { x, y in abs(x) > abs(y) || (abs(x) == abs(y) && x > y) ? x : y }
        }
        var out = self
        out.topics = stronger(topics, other.topics)
        out.channels = stronger(channels, other.channels)
        out.channelNames = channelNames.merging(other.channelNames) { mine, _ in mine }
        out.mutedTopics.formUnion(other.mutedTopics)
        out.mutedChannels.formUnion(other.mutedChannels)
        out.liked.formUnion(other.liked)
        var seenSet = Set(seen)
        out.seen = seen
        for id in other.seen where seenSet.insert(id).inserted { out.seen.append(id) }
        if out.seen.count > Self.seenLimit { out.seen.removeFirst(out.seen.count - Self.seenLimit) }
        out.watchedCount = max(watchedCount, other.watchedCount)
        out.notForMeCount = max(notForMeCount, other.notForMeCount)
        return out
    }

    /// Forget everything except settings.
    public mutating func reset() {
        let (exploration, paused) = (self.exploration, isPaused)
        self = TasteProfile()
        self.exploration = exploration
        self.isPaused = paused
    }

    /// Nothing learned yet (settings aside).
    public var isEmpty: Bool {
        topics.isEmpty && channels.isEmpty && liked.isEmpty && mutedTopics.isEmpty && mutedChannels.isEmpty
    }

    // MARK: Queries used by feed building and the Your taste screen

    public func topTopics(_ n: Int) -> [(tag: String, weight: Double)] {
        topics.filter { $0.value > 0 && !mutedTopics.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }

    public func topChannels(_ n: Int) -> [(id: String, weight: Double)] {
        channels.filter { $0.value > 0 && !mutedChannels.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }

    // MARK: Helpers

    public static func normalise(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        return t
    }

    /// The tags that count for ranking: normalised, de-duplicated, first five.
    public static func tags(of claim: Claim) -> [String] {
        var out: [String] = []
        for tag in claim.tags {
            let t = normalise(tag)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
            if out.count == 5 { break }
        }
        return out
    }

    private func clamp(_ v: Double) -> Double { min(max(v, -1), 1) }
}
