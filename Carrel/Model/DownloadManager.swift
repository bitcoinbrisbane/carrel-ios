import Foundation
import AVFoundation
import UIKit
import LBRYKit

/// Offline downloads (#20). Progressive streams download with a background
/// URLSession (pause keeps resume data); HLS streams with AVAssetDownloadURLSession.
/// Files live under Application Support/Carrel/Downloads, excluded from iCloud backup.
@Observable
@MainActor
final class DownloadManager: NSObject {

    private(set) var index: DownloadIndex = DownloadManager.loadIndex() {
        didSet { save() }
    }

    /// Only download over Wi-Fi (on by default).
    var wifiOnly: Bool = UserDefaults.standard.object(forKey: "downloads.wifiOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: "downloads.wifiOnly") }
    }

    private static let fileSessionID = "au.com.bitcoinbrisbane.carrel.downloads"
    private static let hlsSessionID = "au.com.bitcoinbrisbane.carrel.downloads.hls"
    /// Set by the app delegate when iOS wakes us for finished background transfers.
    static var backgroundCompletion: [String: () -> Void] = [:]

    @ObservationIgnored private var fileSession: URLSession!
    @ObservationIgnored private var hlsSession: AVAssetDownloadURLSession!
    @ObservationIgnored private var tasks: [String: URLSessionTask] = [:]

    override init() {
        super.init()
        let fileConfig = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileSession = URLSession(configuration: fileConfig, delegate: self, delegateQueue: .main)
        let hlsConfig = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hlsConfig.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig, assetDownloadDelegate: self, delegateQueue: .main)
        Task { await reconnect() }
    }

    // MARK: Queries

    func record(for claimID: String) -> DownloadRecord? { index.record(for: claimID) }

    /// The downloaded file to play instead of streaming, if it's complete and still on disk.
    func localURL(for claimID: String) -> URL? {
        guard let record = index.record(for: claimID), record.state == .finished,
              let path = record.relativePath else { return nil }
        let url = Self.home.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var bytesOnDisk: Int64 {
        index.finished.reduce(0) { total, record in
            guard let path = record.relativePath else { return total }
            return total + Self.size(of: Self.home.appendingPathComponent(path))
        }
    }

    // MARK: Actions

    func download(_ claim: Claim, client: LBRYClient) async {
        if let existing = index.record(for: claim.claimId) {
            if case .failed = existing.state { remove(claim.claimId) } else { return }
        }
        index.add(DownloadRecord(claim: claim, kind: .file, state: .queued))
        do {
            let stream = try await client.streamingURL(for: claim.lbryURL)
            let (finalURL, mime) = await Self.probe(stream)
            guard index.record(for: claim.claimId) != nil else { return }      // cancelled meanwhile
            if StreamKind.isHLS(url: finalURL, mimeType: mime) {
                startHLS(claim, url: finalURL)
            } else {
                startFile(claim.claimId, url: finalURL, resumeData: nil)
            }
        } catch {
            index.update(claim.claimId) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func pause(_ claimID: String) {
        guard let task = tasks[claimID] else { return }
        index.update(claimID) { $0.state = .paused }
        if let download = task as? URLSessionDownloadTask {
            download.cancel { [weak self] data in
                Task { @MainActor in
                    if let data { try? data.write(to: Self.resumeDataURL(claimID)) }
                    self?.tasks[claimID] = nil
                }
            }
        } else {
            task.suspend()
        }
    }

    func resume(_ claimID: String, client: LBRYClient) async {
        guard let record = index.record(for: claimID) else { return }
        if let task = tasks[claimID] {          // suspended HLS
            index.update(claimID) { $0.state = .downloading }
            task.resume()
            return
        }
        if record.kind == .file, let data = try? Data(contentsOf: Self.resumeDataURL(claimID)) {
            try? FileManager.default.removeItem(at: Self.resumeDataURL(claimID))
            startFile(claimID, url: nil, resumeData: data)
            return
        }
        // Nothing to resume from: start again.
        remove(claimID)
        await download(record.claim, client: client)
    }

    /// Cancels a transfer or deletes a finished download, files and all.
    func remove(_ claimID: String) {
        tasks[claimID]?.cancel()
        tasks[claimID] = nil
        if let path = index.record(for: claimID)?.relativePath {
            try? FileManager.default.removeItem(at: Self.home.appendingPathComponent(path))
        }
        try? FileManager.default.removeItem(at: Self.resumeDataURL(claimID))
        index.remove(claimID)
    }

    // MARK: Starting transfers

    private func startFile(_ claimID: String, url: URL?, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = fileSession.downloadTask(withResumeData: resumeData)
        } else if let url {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = !wifiOnly
            task = fileSession.downloadTask(with: request)
        } else {
            return
        }
        task.taskDescription = claimID
        tasks[claimID] = task
        index.update(claimID) { $0.state = .downloading; $0.kind = .file }
        task.resume()
    }

    private func startHLS(_ claim: Claim, url: URL) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: !wifiOnly])
        guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: claim.title,
                                                          assetArtworkData: nil, options: nil) else {
            index.update(claim.claimId) { $0.state = .failed("This video can't be downloaded.") }
            return
        }
        task.taskDescription = claim.claimId
        tasks[claim.claimId] = task
        index.update(claim.claimId) { $0.state = .downloading; $0.kind = .hls }
        task.resume()
    }

    /// After a relaunch: reattach to transfers iOS kept running, and mark the rest paused.
    private func reconnect() async {
        var live: Set<String> = []
        for session in [fileSession!, hlsSession!] as [URLSession] {
            for task in await session.allTasks {
                guard let id = task.taskDescription, index.record(for: id) != nil else { task.cancel(); continue }
                tasks[id] = task
                live.insert(id)
            }
        }
        for record in index.records where record.isActive && !live.contains(record.id) {
            index.update(record.id) { $0.state = .paused }
        }
    }

    // MARK: Storage

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Carrel/Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = dir
            try? url.setResourceValues(values)
        }
        return dir
    }

    private static var indexURL: URL { directory.appendingPathComponent("downloads.json") }
    private static func resumeDataURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).resume") }

    private static func loadIndex() -> DownloadIndex {
        guard let data = try? Data(contentsOf: indexURL) else { return DownloadIndex() }
        return (try? JSONDecoder().decode(DownloadIndex.self, from: data)) ?? DownloadIndex()
    }

    private func save() {
        try? JSONEncoder().encode(index).write(to: Self.indexURL, options: .atomic)
    }

    /// Path relative to the app's home directory (which changes between installs/launches).
    private static func relativePath(of url: URL) -> String {
        let home = Self.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home) ? String(path.dropFirst(home.count + 1)) : path
    }

    private static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
        }
        return total
    }

    /// Follows redirects with a HEAD request to learn the final URL and content type.
    private static func probe(_ url: URL) async -> (URL, String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return (url, nil) }
        return (response.url ?? url, response.mimeType)
    }

    fileprivate func finishBackgroundEvents(_ identifier: String?) {
        guard let identifier, let done = Self.backgroundCompletion.removeValue(forKey: identifier) else { return }
        done()
    }
}

// MARK: - URLSession delegates (delivered on the main queue)

extension DownloadManager: URLSessionDownloadDelegate, AVAssetDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription else { return }
            index.update(id) {
                $0.state = .downloading
                $0.bytesWritten = totalBytesWritten
                $0.bytesExpected = max(totalBytesExpectedToWrite, 0)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription, index.record(for: id) != nil else { return }
            let response = downloadTask.response
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                index.update(id) { $0.state = .failed("The server said \(http.statusCode).") }
                return
            }
            // The HEAD probe missed that this is an HLS playlist: download it the HLS way.
            if let url = response?.url, StreamKind.isHLS(url: url, mimeType: response?.mimeType),
               let claim = index.record(for: id)?.claim {
                tasks[id] = nil
                startHLS(claim, url: url)
                return
            }
            let ext = StreamKind.fileExtension(url: response?.url ?? location, mimeType: response?.mimeType)
            let destination = Self.directory.appendingPathComponent("\(id).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                let size = Self.size(of: destination)
                index.update(id) {
                    $0.state = .finished
                    $0.relativePath = Self.relativePath(of: destination)
                    $0.bytesWritten = size
                    $0.bytesExpected = size
                }
            } catch {
                index.update(id) { $0.state = .failed("Couldn't save the file: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                                timeRangeExpectedToLoad: CMTimeRange) {
        MainActor.assumeIsolated {
            guard let id = assetDownloadTask.taskDescription else { return }
            let loaded = loadedTimeRanges.map(\.timeRangeValue).reduce(0.0) { $0 + $1.duration.seconds }
            let expected = timeRangeExpectedToLoad.duration.seconds
            index.update(id) {
                $0.state = .downloading
                if expected > 0 { $0.fraction = loaded / expected }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let id = assetDownloadTask.taskDescription else { return }
            index.update(id) { $0.relativePath = Self.relativePath(of: location) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let id = task.taskDescription else { return }
            if tasks[id] === task { tasks[id] = nil }
            guard let record = index.record(for: id) else { return }
            if let error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled, record.state == .paused { return }   // our pause
                if nsError.code == NSURLErrorCancelled, record.state != .downloading { return }
                if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? data.write(to: Self.resumeDataURL(id))
                    index.update(id) { $0.state = .paused }
                } else {
                    index.update(id) { $0.state = .failed(nsError.localizedDescription) }
                }
            } else if record.kind == .hls, record.relativePath != nil {
                let size = record.relativePath.map { Self.size(of: Self.home.appendingPathComponent($0)) } ?? 0
                index.update(id) { $0.state = .finished; $0.bytesWritten = size; $0.bytesExpected = size; $0.fraction = 1 }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            finishBackgroundEvents(session.configuration.identifier)
        }
    }
}

/// Hands iOS's "your background downloads finished" wake-up to DownloadManager.
final class CarrelAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            DownloadManager.backgroundCompletion[identifier] = completionHandler
        }
    }
}
