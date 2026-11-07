import SwiftUI
import LBRYKit

/// Library: what you follow and what you've watched. All stored on this phone.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        let library = model.library
        List {
            Section {
                NavigationLink {
                    TasteView()
                } label: {
                    Label("Your taste", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("What Carrel has learned from what you watch. It stays on this phone.")
            }

            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    HStack {
                        Label("Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                        let count = model.downloads.index.records.count
                        if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                    }
                }
            }

            Section("Following") {
                if library.following.isEmpty {
                    Text("Tap Follow on a channel to see it here.").foregroundStyle(.secondary)
                }
                ForEach(library.following) { channel in
                    NavigationLink {
                        ChannelView(channelID: channel.claimId, name: channel.name)
                    } label: {
                        HStack(spacing: 12) {
                            ChannelAvatar(url: channel.thumbnailURL.flatMap(URL.init(string:)), name: channel.name, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(channel.title).lineLimit(1)
                                Text(channel.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { model.library.unfollow(library.following[i].claimId) }
                }
            }

            Section {
                if library.history.isEmpty {
                    Text("Videos you watch appear here, so you can pick up where you left off.").foregroundStyle(.secondary)
                }
                ForEach(library.history.prefix(100)) { entry in
                    NavigationLink(value: entry.claim) {
                        HStack(spacing: 12) {
                            VideoThumb(claim: entry.claim, progress: entry.progress)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.claim.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                if let channel = entry.claim.signingChannel {
                                    Text(channel.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(entry.lastWatched, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { Array(library.history.prefix(100))[$0].id }
                    for id in ids { model.library.removeFromHistory(id) }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    if !library.history.isEmpty {
                        Button("Clear") { confirmClear = true }.font(.caption)
                    }
                }
            }

        }
        .navigationTitle("Library")
        .navigationDestination(for: Claim.self) { ClaimDetailView(claim: $0) }
        .confirmationDialog("Clear watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.library.clearHistory() }
        } message: {
            Text("Continue watching is cleared too. Follows and your taste stay.")
        }
    }
}

struct VideoThumb: View {
    let claim: Claim
    let progress: Double?

    var body: some View {
        Color(white: 0.15)
            .overlay {
                AsyncImage(url: claim.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    Rectangle().fill(Color.carrelAccent).frame(width: 112 * progress, height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
