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

    /// Learned on this device only; saved after every change.
    var taste: TasteProfile = TasteStore.load() {
        didSet { TasteStore.save(taste) }
    }

    func record(_ signal: TasteProfile.Signal, on claim: Claim) {
        taste.record(signal, on: claim)
    }

    /// Follows and watch history, on this device only.
    var library: UserLibrary = LibraryStore.load() {
        didSet { LibraryStore.save(library) }
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

    /// Handle `lbry://` and odysee.com links opened from outside the app.
    func open(_ link: String) {
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
        .alert("Couldn't open link", isPresented: .constant(model.deepLinkError != nil)) {
            Button("OK") { model.deepLinkError = nil }
        } message: {
            Text(model.deepLinkError ?? "")
        }
    }
}
