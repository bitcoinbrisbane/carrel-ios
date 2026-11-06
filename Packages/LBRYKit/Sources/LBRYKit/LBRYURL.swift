import Foundation

/// Normalises the link shapes people paste into an `lbry://` URL the SDK can resolve.
///
///     lbry://@channel#a/video#b          → unchanged
///     https://odysee.com/@channel:a/video:b → lbry://@channel#a/video#b
///     @channel:a/video:b                 → lbry://@channel#a/video#b
public enum LBRYURL {

    public static func normalise(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("lbry://") {
            s.removeFirst("lbry://".count)
        } else if let url = URL(string: s), let host = url.host, url.scheme?.hasPrefix("http") == true {
            guard host == "odysee.com" || host.hasSuffix(".odysee.com") else { return nil }
            s = String(url.path.drop(while: { $0 == "/" }))
        }

        s = s.removingPercentEncoding ?? s
        // Drop query/fragment-free trailing slashes.
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }

        // Odysee uses ':' where lbry:// uses '#' for claim-id modifiers.
        let segments = s.split(separator: "/", omittingEmptySubsequences: true).map { segment in
            segment.replacingOccurrences(of: ":", with: "#")
        }
        guard segments.count <= 2 else { return nil }
        return "lbry://" + segments.joined(separator: "/")
    }
}
