import Foundation

// App Store Guideline 1.2 (user-generated content): filter, report, block, and act on
// reports. Reports go to Carrel's support address; acting on one means adding the claim
// or channel to the published moderation list, which every copy of the app fetches.

/// Channels and videos this viewer has blocked. Stays on the device.
public struct UserBlocks: Codable, Equatable, Sendable {
    /// Channel claim ID → name, so the list can show what's blocked.
    public var channels: [String: String] = [:]
    /// Single videos hidden after reporting them.
    public var claims: Set<String> = []

    public init() {}

    public mutating func block(channelID: String, name: String) { channels[channelID] = name }
    public mutating func unblock(channelID: String) { channels[channelID] = nil }
    public mutating func hide(claimID: String) { claims.insert(claimID) }

    public func isBlocked(channelID: String) -> Bool { channels[channelID] != nil }

    /// Blocked channels sorted by name, for the settings list.
    public var sortedChannels: [(id: String, name: String)] {
        channels.map { (id: $0.key, name: $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Carrel's published moderation list (`moderation/blocklist.json` in the repo).
public struct ModerationList: Codable, Equatable, Sendable {
    public var updated: String?
    public var claims: [String]
    public var channels: [String]
    public var tags: [String]

    public init(updated: String? = nil, claims: [String] = [], channels: [String] = [], tags: [String] = []) {
        self.updated = updated
        self.claims = claims
        self.channels = channels
        self.tags = tags
    }

    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/bitcoinbrisbane/carrel-ios/main/moderation/blocklist.json")!

    public static func fetch(from url: URL = defaultURL, session: URLSession = .shared) async throws -> ModerationList {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ModerationList.self, from: data)
    }
}

/// Why something is being reported.
public enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case sexual, childSafety, violence, hate, harassment, illegal, spam, copyright, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sexual: return "Sexual content"
        case .childSafety: return "Child safety"
        case .violence: return "Violence or graphic content"
        case .hate: return "Hate speech"
        case .harassment: return "Harassment or bullying"
        case .illegal: return "Illegal activity"
        case .spam: return "Spam or scam"
        case .copyright: return "Copyright"
        case .other: return "Something else"
        }
    }
}

/// A report of a video or channel, sent by email to Carrel's support address.
public struct ContentReport: Equatable, Sendable {
    public let claimID: String
    public let isChannel: Bool
    public let title: String
    public let url: String
    public let channelID: String?
    public let channelName: String?
    public var reason: ReportReason
    public var note: String

    public init(claim: Claim, reason: ReportReason = .other, note: String = "") {
        claimID = claim.claimId
        isChannel = claim.valueType == "channel"
        title = claim.title
        url = claim.lbryURL
        channelID = isChannel ? claim.claimId : claim.signingChannel?.claimId
        channelName = isChannel ? claim.name : claim.signingChannel?.name
        self.reason = reason
        self.note = note
    }

    public init(channel: ChannelRef, reason: ReportReason = .other, note: String = "") {
        claimID = channel.claimId
        isChannel = true
        title = channel.title
        url = channel.canonicalURL ?? "lbry://\(channel.name)#\(channel.claimId)"
        channelID = channel.claimId
        channelName = channel.name
        self.reason = reason
        self.note = note
    }

    public var subject: String {
        "Carrel report: \(reason.title) – \(isChannel ? "channel" : "video") \(claimID.prefix(12))"
    }

    public var body: String {
        var lines = [
            "Reason: \(reason.title)",
            "\(isChannel ? "Channel" : "Video"): \(title)",
            "URL: \(url)",
            "Claim ID: \(claimID)",
        ]
        if !isChannel, let channelName, let channelID { lines.append("Channel: \(channelName) (\(channelID))") }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines += ["", trimmed] }
        lines += ["", "Sent from Carrel. Reports are reviewed within 24 hours."]
        return lines.joined(separator: "\n")
    }

    /// `mailto:` link with subject and body filled in.
    public func mailtoURL(to address: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return c.url
    }
}
