import SwiftUI
import LBRYKit

/// A channel: cover, bio, Follow, and its latest videos.
struct ChannelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reporting = false
    @State private var confirmBlock = false
    let channelID: String
    let name: String
    /// Pass the channel claim when you already have it (saves a resolve).
    var channelClaim: Claim?

    @State private var channel: Claim?
    @State private var videos: [Claim] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            Section("Latest") {
                ForEach(videos) { video in
                    NavigationLink { ClaimDetailView(claim: video) } label: { ClaimRow(claim: video) }
                        .onAppear { if video == videos.last { Task { await loadMore() } } }
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                if !isLoading, videos.isEmpty, error == nil {
                    Text("No videos yet.").foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(channel?.title ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { reporting = true } label: { Label("Report channel…", systemImage: "flag") }
                    if model.blocks.isBlocked(channelID: channelID) {
                        Button { model.unblock(channelID: channelID) } label: { Label("Unblock \(name)", systemImage: "hand.raised.slash") }
                    } else {
                        Button(role: .destructive) { confirmBlock = true } label: { Label("Block \(name)", systemImage: "hand.raised") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More: report or block")
            }
        }
        .sheet(isPresented: $reporting) {
            ReportSheet(report: ContentReport(channel: ref), channel: ref) { dismiss() }
        }
        .confirmationDialog("Block \(name)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { model.block(ref); dismiss() }
        } message: {
            Text("You won't see its videos anywhere in Carrel. Unblock in Library › Blocked channels.")
        }
        .environment(\.openURL, OpenURLAction { url in
            if Linkifier.kind(ofWebURL: url) == .lbry || url.scheme?.lowercased() == "lbry" {
                model.open(url.absoluteString)
                return .handled
            }
            return .systemAction
        })
        .task { await load() }
    }

    private var ref: ChannelRef {
        ChannelRef(claimId: channelID, name: name, canonicalURL: channel?.canonicalURL, value: channel?.value)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.secondary.opacity(0.2)
                .frame(height: 120)
                .overlay {
                    AsyncImage(url: channel?.value?.cover?.url.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .clipped()
            HStack(spacing: 12) {
                ChannelAvatar(url: channel?.thumbnailURL, name: name, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel?.title ?? name).font(.title3.weight(.bold)).lineLimit(1)
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                FollowButton(channel: ref)
            }
            .padding(.horizontal)
            if let bio = channel?.value?.description, !bio.isEmpty {
                Text(Linkifier.attributed(bio))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .tint(Color.carrelAccent)
                    .lineLimit(6)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    private func load() async {
        if channel == nil {
            channel = channelClaim
            if channel == nil {
                channel = try? await model.client.resolve("lbry://\(name)#\(channelID)")
            }
        }
        if videos.isEmpty { await loadMore() }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var params = ClaimSearchParams()
        params.channelIDs = [channelID]
        params.streamTypes = nil
        params.orderBy = ["release_time"]
        params.page = page
        do {
            let result = try await model.client.claimSearch(params)
            let known = Set(videos.map(\.claimId))
            videos += model.filter.apply(result.items).filter { !known.contains($0.claimId) }
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
