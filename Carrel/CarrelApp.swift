import SwiftUI
import LBRYKit

@main
struct CarrelApp: App {
    @UIApplicationDelegateAdaptor(CarrelAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.open(url.absoluteString) }
        }
    }
}

/// App-wide state. One LBRY client, one content filter, the on-device taste
/// profile, and any deep link to show.
@Observable
@MainActor
final class AppModel {
    let client = LBRYClient()
    let streams = StreamURLCache()
    let wallet = WalletModel()
    let downloads = DownloadManager()
    /// Public like counts from Odysee (read-only; Carrel likes stay private).
    let reactions = OdyseeReactions(tokenStore: .init(
        load: { UserDefaults.standard.string(forKey: "odysee.authToken") },
        save: { UserDefaults.standard.set($0, forKey: "odysee.authToken") }
    ))
    /// Defaults + the viewer's blocks + Carrel's moderation list (Guideline 1.2).
    private(set) var filter = ContentFilter()
    var blocks: UserBlocks = BlockStore.load() {
        didSet { BlockStore.save(blocks); rebuildFilter() }
    }
    private(set) var moderation: ModerationList? = ModerationStore.load()
    var termsAccepted = Support.termsAccepted {
        didSet { Support.termsAccepted = termsAccepted }
    }
    var deepLinkClaim: Claim?
    var deepLinkError: String?
    /// A tip started on Apple TV (`carrel://tip?uri=…` from its QR code).
    var tipRequest: Claim?
    /// An Apple TV asking to sync (`carrel://pair-tv?…` from its QR code), awaiting confirmation.
    var tvPairOffer: TVPairOffer?
    /// True while applying another device's backup, so that doesn't trigger a backup of its own.
    private var applyingRemote = false

    /// Learned on this device only; saved after every change.
    var taste: TasteProfile = TasteStore.load() {
        didSet { TasteStore.save(taste); if !applyingRemote { scheduleBackup() } }
    }

    func record(_ signal: TasteProfile.Signal, on claim: Claim) {
        taste.record(signal, on: claim)
    }

    /// Follows and watch history, on this device only.
    var library: UserLibrary = LibraryStore.load() {
        didSet { LibraryStore.save(library); if !applyingRemote { scheduleBackup() } }
    }

    init() {
        rebuildFilter()
        Task { await refreshModeration() }
        // A wallet opened on a fresh phone brings its taste and library back from iCloud.
        wallet.onReady = { [weak self] in self?.restoreBackupIfFresh() }
        // Apple TV (or another iPhone) changed the backup: fold its changes in.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard keys.contains(CloudBackupStore.key) else { return }
            MainActor.assumeIsolated { self?.pullBackup() }
        }
        CloudBackupStore.store.synchronize()
    }

    // MARK: Encrypted backup (taste + library)

    private(set) var lastBackup: Date? = CloudBackupStore.lastSaved
    private(set) var backupError: String?
    private var backupTask: Task<Void, Never>?

    /// Back up a little after the last change, so a burst of changes is one write.
    func scheduleBackup() {
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.backupNow()
        }
    }

    func backupNow() {
        guard wallet.isReady, let phrase = try? wallet.recoveryPhrase() else { return }
        do {
            // Fold in what Apple TV wrote since, so its likes and follows aren't overwritten.
            pullBackup()
            let blob = try EncryptedBackup.seal(BackupPayload(taste: taste, library: library), phrase: phrase)
            let now = Date()
            CloudBackupStore.save(blob, at: now)
            lastBackup = now
            backupError = nil
        } catch {
            backupError = "Couldn't back up: \(error.localizedDescription)"
        }
    }

    /// Restore. `replaceTaste` swaps in the backed-up taste; follows and history are always combined.
    @discardableResult
    func restoreBackup(replaceTaste: Bool) -> Bool {
        guard let phrase = try? wallet.recoveryPhrase(), let blob = CloudBackupStore.load() else {
            backupError = "No backup found for this wallet."
            return false
        }
        do {
            let payload = try EncryptedBackup.open(blob, phrase: phrase)
            if replaceTaste || taste.isEmpty { taste = payload.taste }
            library = library.merged(with: payload.library)
            backupError = nil
            return true
        } catch EncryptedBackup.Error.cannotDecrypt {
            backupError = "The iCloud backup belongs to a different recovery phrase."
        } catch {
            backupError = "Couldn't restore: \(error.localizedDescription)"
        }
        return false
    }

    /// Merge the backup in iCloud (perhaps written by Apple TV) into this phone's
    /// taste and library. Quiet: does nothing if there's no backup or it isn't ours.
    func pullBackup() {
        guard let phrase = try? wallet.recoveryPhrase(), let blob = CloudBackupStore.load(),
              let remote = try? EncryptedBackup.open(blob, phrase: phrase) else { return }
        let mergedTaste = taste.merged(with: remote.taste)
        let mergedLibrary = library.merged(with: remote.library)
        applyingRemote = true
        defer { applyingRemote = false }
        if mergedTaste != taste { taste = mergedTaste }
        if mergedLibrary != library { library = mergedLibrary }
    }

    // MARK: Moderation

    private func rebuildFilter() {
        filter = ContentFilter.combined(user: blocks, server: moderation)
    }

    /// Fetch Carrel's moderation list (how reports are acted on) and apply it.
    func refreshModeration() async {
        guard let list = try? await ModerationList.fetch() else { return }
        ModerationStore.save(list)
        moderation = list
        rebuildFilter()
    }

    func block(_ channel: ChannelRef) {
        blocks.block(channelID: channel.claimId, name: channel.name)
        if library.isFollowing(channel.claimId) { library.unfollow(channel.claimId) }
    }

    func unblock(channelID: String) {
        blocks.unblock(channelID: channelID)
    }

    // MARK: Apple TV

    struct TVPairOffer: Identifiable {
        let offer: TVPairing.Offer
        var id: String { offer.id }
    }

    /// Hands this wallet's backup key (not the phrase) to the Apple TV that showed the
    /// QR code, through iCloud key-value storage, then backs up so the TV has data.
    func linkAppleTV(_ offer: TVPairing.Offer) throws {
        guard let phrase = try wallet.recoveryPhrase() else { throw WalletError.watchOnly }
        let sealed = try offer.seal(backupKey: EncryptedBackup.key(phrase: phrase))
        let store = CloudBackupStore.store
        store.set(sealed, forKey: TVPairing.storeKey(id: offer.id))
        store.synchronize()
        backupNow()
    }

    private func restoreBackupIfFresh() {
        guard taste.isEmpty, library.isEmpty, CloudBackupStore.load() != nil else { return }
        restoreBackup(replaceTaste: true)
    }

    func recordProgress(_ claim: Claim, position: Double, duration: Double?) {
        guard position.isFinite, position >= 0 else { return }
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        library.recordProgress(claim, position: position, duration: length)
        // Finishing a long video is a strong taste signal too.
        // (Recording marks it seen, so this fires once per video.)
        if let length, position / length >= 0.9, !taste.hasSeen(claim.claimId) {
            record(.watchedToEnd, on: claim)
        }
    }

    /// Handle `lbry://` and odysee.com links opened from outside the app, and
    /// `carrel://tip?uri=lbry://…` from the Apple TV app's tip QR code.
    func open(_ link: String) {
        if let components = URLComponents(string: link), components.scheme?.lowercased() == "carrel" {
            if components.host == "pair-tv" {
                do {
                    tvPairOffer = TVPairOffer(offer: try TVPairing.Offer(link: link))
                } catch {
                    deepLinkError = "That Apple TV code didn't scan properly. Try again."
                }
                return
            }
            guard components.host == "tip",
                  let uri = components.queryItems?.first(where: { $0.name == "uri" })?.value.flatMap(LBRYURL.normalise) else {
                deepLinkError = "Carrel can't open that link."
                return
            }
            Task {
                do {
                    guard let claim = try await client.resolve(uri) else {
                        deepLinkError = "Nothing found at \(uri)."
                        return
                    }
                    tipRequest = claim
                } catch {
                    deepLinkError = error.localizedDescription
                }
            }
            return
        }
        guard let uri = LBRYURL.normalise(link) else {
            deepLinkError = "Carrel can't open that link."
            return
        }
        Task {
            do {
                deepLinkClaim = try await client.resolve(uri)
                if deepLinkClaim == nil { deepLinkError = "Nothing found at \(uri)." }
            } catch {
                deepLinkError = error.localizedDescription
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house") }
            ShortsView()
                .tabItem { Label("Shorts", systemImage: "play.rectangle.on.rectangle") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
            NavigationStack { WalletView() }
                .tabItem { Label("Wallet", systemImage: "wallet.bifold") }
        }
        .sheet(item: $model.deepLinkClaim) { claim in
            NavigationStack { ClaimDetailView(claim: claim) }
        }
        .sheet(item: $model.tvPairOffer) { request in
            LinkAppleTVSheet(offer: request.offer)
                .presentationDetents([.medium])
        }
        .sheet(item: $model.tipRequest) { claim in
            NavigationStack { TipSheet(claim: claim) }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(get: { !model.termsAccepted }, set: { _ in })) {
            TermsView { model.termsAccepted = true }
                .interactiveDismissDisabled()
        }
        .alert("Couldn't open link", isPresented: .constant(model.deepLinkError != nil)) {
            Button("OK") { model.deepLinkError = nil }
        } message: {
            Text(model.deepLinkError ?? "")
        }
    }
}
