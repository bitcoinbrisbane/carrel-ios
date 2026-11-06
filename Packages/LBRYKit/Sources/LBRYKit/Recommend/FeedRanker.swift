import Foundation

/// A clip placed in the feed, with the reason Carrel shows for it.
public struct RankedClaim: Identifiable, Hashable, Sendable {
    public let claim: Claim
    public let score: Double
    public let reason: Reason

    public var id: String { claim.claimId }

    public enum Reason: Hashable, Sendable {
        case topic(String)        // normalised tag
        case channel(String)      // @name
        case following(String)    // @name of a followed channel
        case exploring
        case trending

        public var text: String {
            switch self {
            case .topic(let tag): return "Matches #\(tag)"
            case .channel(let name): return "You liked clips from \(name)"
            case .following(let name): return "You follow \(name)"
            case .exploring: return "Exploring: new to you"
            case .trending: return "Trending on LBRY"
            }
        }
    }
}

/// Ranks candidate clips against a `TasteProfile`, entirely on device.
///
///     score = topicWeight·topicMatch + channelWeight·channelAffinity + freshnessWeight·freshness
///
/// Then roughly `taste.exploration` of the slots are filled with clips the viewer
/// has shown no interest in either way, picked at random, so the feed doesn't narrow.
public struct FeedRanker: Sendable {
    public var topicWeight = 1.0
    public var channelWeight = 0.8
    public var freshnessWeight = 0.4
    /// Days for freshness to fall to ~37%.
    public var freshnessDays = 3.0

    public init() {}

    // MARK: Scoring

    public func topicMatch(_ claim: Claim, taste: TasteProfile) -> Double {
        let weights = TasteProfile.tags(of: claim).compactMap { taste.topics[$0] }
        guard !weights.isEmpty else { return 0 }
        return weights.reduce(0, +) / Double(weights.count)
    }

    public func channelAffinity(_ claim: Claim, taste: TasteProfile) -> Double {
        claim.signingChannel.flatMap { taste.channels[$0.claimId] } ?? 0
    }

    public func freshness(_ claim: Claim, now: Date) -> Double {
        guard let released = claim.releaseDate else { return 0 }
        let days = max(0, now.timeIntervalSince(released) / 86_400)
        return exp(-days / freshnessDays)
    }

    public func score(_ claim: Claim, taste: TasteProfile, now: Date) -> Double {
        topicWeight * topicMatch(claim, taste: taste)
            + channelWeight * channelAffinity(claim, taste: taste)
            + freshnessWeight * freshness(claim, now: now)
    }

    /// True if the viewer has expressed any opinion about this clip's channel or tags.
    public func isFamiliar(_ claim: Claim, taste: TasteProfile) -> Bool {
        if let id = claim.signingChannel?.claimId, taste.channels[id] != nil { return true }
        return TasteProfile.tags(of: claim).contains { taste.topics[$0] != nil }
    }

    /// Hard filters: muted channels and topics, and clips already shown.
    public func isAllowed(_ claim: Claim, taste: TasteProfile) -> Bool {
        if taste.hasSeen(claim.claimId) { return false }
        if let id = claim.signingChannel?.claimId, taste.mutedChannels.contains(id) { return false }
        return !TasteProfile.tags(of: claim).contains { taste.mutedTopics.contains($0) }
    }

    public func reason(for claim: Claim, taste: TasteProfile) -> RankedClaim.Reason {
        if let channel = claim.signingChannel, (taste.channels[channel.claimId] ?? 0) >= 0.2 {
            return .channel(channel.name)
        }
        let best = TasteProfile.tags(of: claim)
            .compactMap { tag in taste.topics[tag].map { (tag, $0) } }
            .max { $0.1 < $1.1 }
        if let best, best.1 >= 0.1 { return .topic(best.0) }
        return .trending
    }

    // MARK: Ranking

    public func rank(_ candidates: [Claim], taste: TasteProfile, now: Date = Date()) -> [RankedClaim] {
        var rng = SystemRandomNumberGenerator()
        return rank(candidates, taste: taste, now: now, using: &rng)
    }

    public func rank<G: RandomNumberGenerator>(
        _ candidates: [Claim], taste: TasteProfile, now: Date, using rng: inout G
    ) -> [RankedClaim] {
        // De-duplicate (several queries return the same clip) and apply hard filters.
        var unique: [Claim] = []
        var ids = Set<String>()
        for claim in candidates where ids.insert(claim.claimId).inserted && isAllowed(claim, taste: taste) {
            unique.append(claim)
        }

        let scored = unique.map { (claim: $0, score: score($0, taste: taste, now: now), familiar: isFamiliar($0, taste: taste)) }

        // Exploitation pool: everything, best first. Exploration pool: unfamiliar clips, shuffled.
        let exploit = scored.sorted { $0.score > $1.score }
        var explore = scored.filter { !$0.familiar }
        explore.shuffle(using: &rng)

        // Every `every`-th slot is an exploration slot (10% → every 10th).
        let every = taste.exploration > 0 ? max(2, Int((1 / taste.exploration).rounded())) : Int.max

        var out: [RankedClaim] = []
        var used = Set<String>()
        var exploitIndex = 0
        var exploreIndex = 0

        while out.count < scored.count {
            let isExploreSlot = (out.count + 1) % every == 0
            var picked: (claim: Claim, score: Double, familiar: Bool)?
            var exploring = false

            if isExploreSlot {
                while exploreIndex < explore.count, used.contains(explore[exploreIndex].claim.claimId) { exploreIndex += 1 }
                if exploreIndex < explore.count {
                    picked = explore[exploreIndex]
                    exploring = true
                }
            }
            if picked == nil {
                while exploitIndex < exploit.count, used.contains(exploit[exploitIndex].claim.claimId) { exploitIndex += 1 }
                if exploitIndex < exploit.count { picked = exploit[exploitIndex] }
            }
            guard let p = picked else { break }

            used.insert(p.claim.claimId)
            let reason: RankedClaim.Reason = exploring ? .exploring : reason(for: p.claim, taste: taste)
            out.append(RankedClaim(claim: p.claim, score: p.score, reason: reason))
        }
        return out
    }
}

/// Small deterministic RNG (SplitMix64) so ranking can be tested.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
