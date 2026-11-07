import SwiftUI
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
        didSet { TasteStore.save(taste) }
    }

    var library: UserLibrary = LibraryStore.load() {
        didSet { LibraryStore.save(library) }
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
            TVShortsView()
                .tabItem { Text("Shorts") }
            NavigationStack { TVLibraryView() }
                .tabItem { Text("Library") }
            NavigationStack { TVSearchView() }
                .tabItem { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Search")
        }
    }
}
