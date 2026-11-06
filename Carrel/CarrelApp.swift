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
            NavigationStack { DiscoverView() }
                .tabItem { Label("Discover", systemImage: "sparkles.tv") }
            ShortsView()
                .tabItem { Label("Shorts", systemImage: "play.rectangle.on.rectangle") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
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
