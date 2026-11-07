import Foundation

/// One downloaded (or downloading) video, as the Downloads list keeps it.
public struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {

    public enum State: Codable, Equatable, Sendable {
        case queued
        case downloading
        case paused
        case finished
        case failed(String)
    }

    /// A plain file (progressive MP4) or an HLS package (`.movpkg`, via AVAssetDownloadTask).
    public enum Kind: String, Codable, Sendable {
        case file
        case hls
    }

    public var claim: Claim
    public var state: State
    public var kind: Kind
    /// Where it lives, relative to the app's home directory (Apple's advice for HLS
    /// packages, whose absolute path changes between launches).
    public var relativePath: String?
    public var bytesWritten: Int64 = 0
    public var bytesExpected: Int64 = 0
    /// HLS reports progress as a fraction rather than bytes.
    public var fraction: Double?
    public var addedAt: Date

    public var id: String { claim.claimId }

    public init(claim: Claim, kind: Kind, state: State = .queued, addedAt: Date = Date()) {
        self.claim = claim
        self.kind = kind
        self.state = state
        self.addedAt = addedAt
    }

    /// 0…1 when known.
    public var progress: Double? {
        if state == .finished { return 1 }
        if let fraction { return min(max(fraction, 0), 1) }
        guard bytesExpected > 0 else { return nil }
        return min(Double(bytesWritten) / Double(bytesExpected), 1)
    }

    public var isActive: Bool { state == .queued || state == .downloading }
}

/// The Downloads list, newest first, saved as JSON next to the files.
public struct DownloadIndex: Codable, Equatable, Sendable {
    public private(set) var records: [DownloadRecord] = []

    public init() {}

    public func record(for claimID: String) -> DownloadRecord? {
        records.first { $0.id == claimID }
    }

    /// Adds a new download at the top, or returns false if it's already there.
    @discardableResult
    public mutating func add(_ record: DownloadRecord) -> Bool {
        guard self.record(for: record.id) == nil else { return false }
        records.insert(record, at: 0)
        return true
    }

    public mutating func update(_ claimID: String, _ change: (inout DownloadRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == claimID }) else { return }
        change(&records[i])
    }

    @discardableResult
    public mutating func remove(_ claimID: String) -> DownloadRecord? {
        guard let i = records.firstIndex(where: { $0.id == claimID }) else { return nil }
        return records.remove(at: i)
    }

    public var finished: [DownloadRecord] { records.filter { $0.state == .finished } }

    /// Bytes on disk for finished downloads.
    public var finishedBytes: Int64 { finished.reduce(0) { $0 + $1.bytesWritten } }
}

public enum StreamKind {
    /// Whether a stream is HLS (needs AVAssetDownloadTask) or a plain file (URLSession).
    public static func isHLS(url: URL, mimeType: String?) -> Bool {
        if let mime = mimeType?.lowercased(), mime.contains("mpegurl") { return true }
        return url.pathExtension.lowercased() == "m3u8"
    }

    /// File extension for a progressive download.
    public static func fileExtension(url: URL, mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        default:
            let ext = url.pathExtension.lowercased()
            return ["mp4", "m4v", "mov", "webm", "mp3", "m4a"].contains(ext) ? ext : "mp4"
        }
    }
}
