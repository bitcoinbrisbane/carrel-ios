import SwiftUI
import CryptoKit
import LBRYKit

/// Carrel for Apple TV: the same LBRY client and on-device recommender as the
/// iPhone app, with a 10-foot UI. No keys live on the TV: tipping shows a QR code
/// that Carrel on iPhone opens to send the tip.
@main
struct CarrelTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// App-wide state for the TV: client, filter, taste and library (on this TV).
@Observable
@MainActor
final class TVModel {
    let client = LBRYClient()
    let streams = StreamURLCache()
    var filter = ContentFilter()

    var taste: TasteProfile = TasteStore.load() {
        didSet { TasteStore.save(taste); if !applyingRemote { schedulePush() } }
    }

    var library: UserLibrary = LibraryStore.load() {
        didSet { LibraryStore.save(library); if !applyingRemote { schedulePush() } }
    }

    // MARK: Sync with iPhone (issue #18)

    /// The iPhone's backup key, once linked. Never the recovery phrase.
    private(set) var backupKey: SymmetricKey? = TVKeyStore.load()
    private(set) var lastSync: Date?
    var isLinked: Bool { backupKey != nil }
    private var applyingRemote = false
    private var pushTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard keys.contains(CloudBackupStore.key) else { return }
            MainActor.assumeIsolated { self?.pull() }
        }
        CloudBackupStore.store.synchronize()
        pull()
    }

    /// Merge the iPhone's backup into this TV's taste and library.
    func pull() {
        guard let backupKey, let blob = CloudBackupStore.load(),
              let remote = try? EncryptedBackup.open(blob, key: backupKey) else { return }
        let mergedTaste = taste.merged(with: remote.taste)
        let mergedLibrary = library.merged(with: remote.library)
        applyingRemote = true
        defer { applyingRemote = false }
        if mergedTaste != taste { taste = mergedTaste }
        if mergedLibrary != library { library = mergedLibrary }
        lastSync = Date()
    }

    /// Write this TV's changes back (merged with the latest from the phone), 20 s after the last change.
    private func schedulePush() {
        guard isLinked else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    func push() {
        guard let backupKey else { return }
        pull()
        guard let blob = try? EncryptedBackup.seal(BackupPayload(taste: taste, library: library), key: backupKey) else { return }
        CloudBackupStore.save(blob)
        lastSync = Date()
    }

    /// Finish pairing if the iPhone has left this TV its key. True once linked.
    func completePairing(_ request: TVPairing.Request) -> Bool {
        let store = CloudBackupStore.store
        store.synchronize()
        let entry = TVPairing.storeKey(id: request.id)
        guard let sealed = store.data(forKey: entry), let key = try? request.open(sealed) else { return false }
        store.removeObject(forKey: entry)
        store.synchronize()
        TVKeyStore.save(key)
        backupKey = key
        pull()
        return true
    }

    /// Stop syncing. This TV keeps what it has; the iPhone's backup is untouched.
    func unlink() {
        TVKeyStore.delete()
        backupKey = nil
        pushTask?.cancel()
        lastSync = nil
    }

    func record(_ signal: TasteProfile.Signal, on claim: Claim) {
        taste.record(signal, on: claim)
    }

    func toggleLike(_ claim: Claim) {
        record(taste.liked.contains(claim.claimId) ? .unlike : .like, on: claim)
    }

    func toggleFollow(_ channel: ChannelRef) {
        if library.isFollowing(channel.claimId) { library.unfollow(channel.claimId) } else { library.follow(channel) }
    }

    func recordProgress(_ claim: Claim, position: Double, duration: Double?) {
        guard position.isFinite, position >= 0 else { return }
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        library.recordProgress(claim, position: position, duration: length)
        if let length, position / length >= 0.9, !taste.hasSeen(claim.claimId) {
            record(.watchedToEnd, on: claim)
        }
    }
}

struct TVRootView: View {
    var body: some View {
        TabView {
            NavigationStack { TVHomeView() }
                .tabItem { Text("Home") }
            NavigationStack { TVDiscoverView() }
                .tabItem { Text("Discover") }
            NavigationStack { TVLibraryView() }
                .tabItem { Text("Library") }
            NavigationStack { TVSearchView() }
                .tabItem { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search")
        }
    }
}
