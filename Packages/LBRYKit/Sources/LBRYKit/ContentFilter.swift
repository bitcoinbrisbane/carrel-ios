import Foundation

/// Client-side content filter. App Store Guideline 1.2 requires user-generated
/// content apps to filter objectionable material and let users report and block.
/// This is the on-device layer; the server-side list (carrel-node) comes later.
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
        if let channel = claim.signingChannel, blockedChannelIDs.contains(channel.claimId) { return false }
        return !claim.tags.contains { blockedTags.contains($0.lowercased()) }
    }

    public func apply(_ claims: [Claim]) -> [Claim] {
        claims.filter(allows)
    }
}
