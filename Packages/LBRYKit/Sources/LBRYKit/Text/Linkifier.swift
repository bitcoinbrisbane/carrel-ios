import Foundation

/// Finds links in claim descriptions and channel bios.
///
/// - `https://…` URLs (x.com/twitter.com, reddit.com and odysee.com are recognised).
/// - `lbry://…` URLs, and odysee.com links, which Carrel opens itself.
/// - `r/sub`, `/r/sub`, `u/name`, `/u/name` → Reddit.
/// - `@handle` on a line that mentions Twitter or X → x.com.
/// - Any other `@name` → that LBRY channel, opened in Carrel.
///
/// Matches never overlap; earlier rules win.
public enum Linkifier {

    public enum Kind: Equatable, Sendable {
        case web
        case lbry
        case x
        case reddit
    }

    public struct Link: Equatable, Sendable {
        public let range: Range<String.Index>
        public let url: URL
        public let kind: Kind
    }

    public static func links(in text: String) -> [Link] {
        var found: [Link] = []
        var taken: [Range<String.Index>] = []

        func add(_ range: Range<String.Index>, _ url: URL?, _ kind: Kind) {
            guard let url, !taken.contains(where: { $0.overlaps(range) }) else { return }
            taken.append(range)
            found.append(Link(range: range, url: url, kind: kind))
        }

        // 1. Explicit URLs.
        for match in matches(of: urlPattern, in: text) {
            var range = match.range
            // Trailing punctuation usually belongs to the sentence, not the link.
            // A closing bracket stays only if it closes one opened inside the link.
            while range.upperBound > range.lowerBound, let last = text[range].last {
                let candidate = text[range]
                let unbalanced = (last == ")" && candidate.filter { $0 == ")" }.count > candidate.filter { $0 == "(" }.count)
                    || (last == "]" && candidate.filter { $0 == "]" }.count > candidate.filter { $0 == "[" }.count)
                guard ".,;:!?}'\"".contains(last) || unbalanced else { break }
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            let raw = String(text[range])
            if raw.lowercased().hasPrefix("lbry://") {
                add(range, URL(string: raw), .lbry)
            } else if let url = URL(string: raw) {
                add(range, url, kind(ofWebURL: url))
            }
        }

        // 2. Reddit shorthands.
        for match in matches(of: redditPattern, in: text) {
            guard let typeRange = match.groups[0], let nameRange = match.groups[1] else { continue }
            let path = text[typeRange].lowercased() == "r" ? "r" : "user"
            add(match.range, URL(string: "https://www.reddit.com/\(path)/\(text[nameRange])"), .reddit)
        }

        // 3. @handles: X on Twitter/X lines, LBRY channels everywhere else.
        for match in matches(of: handlePattern, in: text) {
            guard let nameRange = match.groups[0] else { continue }
            let name = String(text[nameRange])
            if isXLine(text, around: match.range) {
                let handle = name.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !handle.isEmpty, handle.count <= 15 else { continue }
                let end = text.index(match.range.lowerBound, offsetBy: handle.count + 1)
                add(match.range.lowerBound..<end, URL(string: "https://x.com/\(handle)"), .x)
            } else {
                let lbry = "lbry://@" + name.replacingOccurrences(of: ":", with: "#")
                add(match.range, URL(string: lbry), .lbry)
            }
        }

        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Classification

    public static func kind(ofWebURL url: URL) -> Kind {
        guard let host = url.host?.lowercased() else { return .web }
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if isHost("x.com") || isHost("twitter.com") { return .x }
        if isHost("reddit.com") || host == "redd.it" { return .reddit }
        if isHost("odysee.com") { return .lbry }
        return .web
    }

    /// True if the line holding `range` labels itself as Twitter or X ("Twitter: @me", "X: @me", "on X @me").
    static func isXLine(_ text: String, around range: Range<String.Index>) -> Bool {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let line = String(text[lineStart..<lineEnd])
        let ns = line as NSString
        return xLinePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: Patterns

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?|lbry)://[^\s<>"]+"#, options: [.caseInsensitive])

    /// `r/name` or `u/name`, optionally with a leading slash, not inside a word or URL path.
    private static let redditPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/.])/?([ru])/([A-Za-z0-9_][A-Za-z0-9_-]{1,20})\b"#, options: [.caseInsensitive])

    /// `@name`, not preceded by a word character (so emails don't match). LBRY names allow
    /// letters, digits and `-`; an optional `:claimid` or `#claimid` suffix is kept.
    private static let handlePattern = try! NSRegularExpression(
        pattern: #"(?<![\w@/])@([A-Za-z0-9_][A-Za-z0-9_-]*(?:[:#][0-9a-fA-F]{1,40})?)"#)

    private static let xLinePattern = try! NSRegularExpression(
        pattern: #"twitter|\bx\s*[:\-–—]|\bon x\b|x\.com|𝕏"#, options: [.caseInsensitive])

    private struct Match {
        let range: Range<String.Index>
        let groups: [Range<String.Index>?]
    }

    private static func matches(of regex: NSRegularExpression, in text: String) -> [Match] {
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: ns).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (1..<max(1, result.numberOfRanges)).map { Range(result.range(at: $0), in: text) }
            return Match(range: range, groups: result.numberOfRanges > 1 ? groups : [])
        }
    }
}

extension Linkifier {
    /// The text as an `AttributedString` with `.link` set on every detected link.
    public static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for link in links(in: text) {
            guard let lower = AttributedString.Index(link.range.lowerBound, within: out),
                  let upper = AttributedString.Index(link.range.upperBound, within: out) else { continue }
            out[lower..<upper].link = link.url
        }
        return out
    }
}
