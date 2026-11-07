import Foundation

/// The viewer's last few searches, newest first. Kept on the device only: not part
/// of the encrypted iCloud backup.
public struct RecentSearches: Codable, Equatable, Sendable {
    public private(set) var items: [String] = []
    public static let limit = 20

    public init() {}

    /// Add a search, or move it to the top if it's already there (ignoring case).
    public mutating func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = t.lowercased()
        items.removeAll { $0.lowercased() == key }
        items.insert(t, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ text: String) {
        items.removeAll { $0 == text }
    }

    public mutating func clear() {
        items.removeAll()
    }

    public var isEmpty: Bool { items.isEmpty }
}
