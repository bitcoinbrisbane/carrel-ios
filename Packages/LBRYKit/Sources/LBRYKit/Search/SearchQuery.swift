import Foundation

/// What the viewer typed into search, worked out before anything goes to the network.
///
///     lbry://@chan#a/video#b, odysee.com/@chan:a/video:b, @chan:a  → .link (opens directly)
///     @name                                                     → .channel (channel search)
///     anything else                                             → .text (full-text search)
public enum SearchQuery: Hashable, Sendable {
    /// A link to open directly, normalised to `lbry://`.
    case link(String)
    /// A channel search, by name without the `@`.
    case channel(String)
    /// Full-text search.
    case text(String)

    /// Nil for an empty (or `@`-only) query.
    public init?(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let lower = s.lowercased()
        if s.hasPrefix("lbry://") || lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("odysee.com/") || lower.hasPrefix("www.odysee.com/") {
            // A pasted link. One Carrel can't open (another site, an Odysee page that
            // isn't a claim) is searched as text rather than refused.
            let link = lower.hasPrefix("odysee.com/") || lower.hasPrefix("www.odysee.com/") ? "https://" + s : s
            if let uri = LBRYURL.normalise(link) {
                self = .link(uri)
            } else {
                self = .text(s)
            }
            return
        }

        if s.hasPrefix("@") {
            let rest = s.dropFirst()
            // "@chan:a", "@chan#a" and "@chan/video" point at a claim; a bare "@name" searches channels.
            if rest.contains(where: { ":#/".contains($0) }), let uri = LBRYURL.normalise(s) {
                self = .link(uri)
                return
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .channel(name)
            return
        }

        self = .text(s)
    }

    /// Lighthouse refuses shorter searches ("the length must be between 3 and 99999"),
    /// counting UTF-16 units as JavaScript does.
    public static let minimumSearchLength = 3

    /// Too short for Lighthouse: only an exact channel name can be looked up.
    public var isTooShort: Bool {
        switch self {
        case .link: return false
        case .channel(let s), .text(let s): return s.utf16.count < Self.minimumSearchLength
        }
    }

    /// The name to try as an exact channel match (`lbry://@name`), shown first among
    /// the channels: spaces dropped, so "bitcoin takeover" finds @bitcointakeover.
    /// Nil for links, and for text that can't be a channel name.
    public var exactChannelName: String? {
        let raw: String
        switch self {
        case .link: return nil
        case .channel(let name): raw = name
        case .text(let text): raw = text
        }
        let name = raw.filter { !$0.isWhitespace }
        guard !name.isEmpty, name.count <= 64,
              !name.contains(where: { Self.invalidNameCharacters.contains($0) }) else { return nil }
        return name
    }

    /// Characters LBRY doesn't allow in claim names.
    static let invalidNameCharacters: Set<Character> = [
        "=", "&", "#", ":", "$", "@", "%", "?", ";", "/", "\\", "\"", "<", ">", "{", "}", "|", "^", "~", "[", "]", "`",
    ]
}
