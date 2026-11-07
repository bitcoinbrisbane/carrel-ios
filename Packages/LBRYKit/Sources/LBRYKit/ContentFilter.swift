import Foundation

/// Client-side content filter. App Store Guideline 1.2 requires user-generated
/// content apps to filter objectionable material and let users report and block.
/// Built from the default tags, the viewer's own blocks (`UserBlocks`) and Carrel's
/// published moderation list (`ModerationList`), which is how reports get acted on.
public struct ContentFilter: Sendable {

    /// Tags excluded from discovery feeds by default.
    public static let defaultBlockedTags = ["mature", "xxx", "sex", "porn", "nsfw"]

    public var blockedTags: Set<String>
    public var blockedChannelIDs: Set<String>
    public var blockedClaimIDs: Set<String>

    public init(
        blockedTags: Set<String> = Set(defaultBlockedTags),
        blockedChannelIDs: Set<String> = [],
        blockedClaimIDs: Set<String> = []
    ) {
        self.blockedTags = blockedTags
        self.blockedChannelIDs = blockedChannelIDs
        self.blockedClaimIDs = blockedClaimIDs
    }

    public func allows(_ claim: Claim) -> Bool {
        if blockedClaimIDs.contains(claim.claimId) { return false }
        if blockedChannelIDs.contains(claim.claimId) { return false }      // a blocked channel's own page
        if let channel = claim.signingChannel, blockedChannelIDs.contains(channel.claimId) { return false }
        return !claim.tags.contains { blockedTags.contains($0.lowercased()) }
    }

    public func apply(_ claims: [Claim]) -> [Claim] {
        claims.filter(allows)
    }

    /// Defaults + the viewer's blocks + Carrel's moderation list.
    public static func combined(user: UserBlocks, server: ModerationList?) -> ContentFilter {
        ContentFilter(
            blockedTags: Set(defaultBlockedTags).union((server?.tags ?? []).map { $0.lowercased() }),
            blockedChannelIDs: Set(user.channels.keys).union(server?.channels ?? []),
            blockedClaimIDs: user.claims.union(server?.claims ?? [])
        )
    }
}
