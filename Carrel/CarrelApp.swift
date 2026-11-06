import SwiftUI
import LBRYKit

@main
struct CarrelApp: App {
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
    /// Public like counts from Odysee (read-only; Carrel likes stay private).
    let reactions = OdyseeReactions(tokenStore: .init(
        load: { UserDefaults.standard.string(forKey: "odysee.authToken") },
        save: { UserDefaults.standard.set($0, forKey: "odysee.authToken") }
    ))
    var filter = ContentFilter()
    var deepLinkClaim: Claim?
    var deepLinkError: String?
    /// A tip started on Apple TV (`carrel://tip?uri=…` from its QR code).
    var tipRequest: Claim?

    /// Learned on this device only; saved after every change.
    var taste: TasteProfile = TasteStore.load() {
        didSet { TasteStore.save(taste); scheduleBackup() }
    }

    func record(_ signal: TasteProfile.Signal, on claim: Claim) {
        taste.record(signal, on: claim)
    }

    /// Follows and watch history, on this device only.
    var library: UserLibrary = LibraryStore.load() {
        didSet { LibraryStore.save(library); scheduleBackup() }
    }

    init() {
        // A wallet opened on a fresh phone brings its taste and library back from iCloud.
        wallet.onReady = { [weak self] in self?.restoreBackupIfFresh() }
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
        .sheet(item: $model.tipRequest) { claim in
            NavigationStack { TipSheet(claim: claim) }
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn't open link", isPresented: .constant(model.deepLinkError != nil)) {
            Button("OK") { model.deepLinkError = nil }
        } message: {
            Text(model.deepLinkError ?? "")
        }
    }
}
