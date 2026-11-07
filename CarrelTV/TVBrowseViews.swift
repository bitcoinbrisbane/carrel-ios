import SwiftUI
import LBRYKit

private let gridColumns = [GridItem(.adaptive(minimum: 420, maximum: 440), spacing: 48, alignment: .top)]

// MARK: - Search

/// Full-text search (Lighthouse) with the system's TV keyboard. Searches as you
/// type, after a short pause; `lbry://` links and @channels resolve directly.
struct TVSearchView: View {
    @Environment(TVModel.self) private var model
    @State private var query = ""
    @State private var results: [Claim] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error {
                Text(error).foregroundStyle(.secondary).padding(80)
            } else if results.isEmpty, !query.isEmpty, !isSearching {
                Text("Nothing found for “\(query)”").foregroundStyle(.secondary).padding(80)
            }
            LazyVGrid(columns: gridColumns, spacing: 56) {
                ForEach(results) { VideoCard(claim: $0) }
            }
            .padding(.horizontal, 80)
        }
        .searchable(text: $query, prompt: "Videos, channels or an lbry:// link")
        .carrelDestinations()
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; error = nil; return }
        isSearching = true
        defer { isSearching = false }
        do {
            var found: [Claim]
            if text.contains("lbry://") || text.hasPrefix("@"), let uri = LBRYURL.normalise(text) {
                found = try await model.client.resolve(uri).map { [$0] } ?? []
            } else {
                found = try await model.client.search(text, size: 30)
            }
            found = model.filter.apply(found)
            guard text == query.trimmingCharacters(in: .whitespaces) else { return }
            results = found
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Library

/// Continue watching, channels you follow, and recent history, all on this TV.
struct TVLibraryView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        let library = model.library
        let resume = library.continueWatching()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 56) {
                if !resume.isEmpty {
                    ShelfRow(title: "Continue watching") {
                        ForEach(resume) { VideoCard(claim: $0.claim, progress: $0.progress) }
                    }
                }
                if !library.following.isEmpty {
                    ShelfRow(title: "Following", subtitle: "\(library.following.count)") {
                        ForEach(library.following) { ChannelCard(channel: $0) }
                    }
                }
                let recent = library.history.prefix(30).filter { entry in !resume.contains { $0.id == entry.id } }
                if !recent.isEmpty {
                    ShelfRow(title: "Watched") {
                        ForEach(Array(recent)) { VideoCard(claim: $0.claim) }
                    }
                }
                if resume.isEmpty, library.following.isEmpty, library.history.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Nothing here yet").font(.title3)
                        Text("Videos you watch and channels you follow show up here. Link your iPhone (top menu) to bring yours over.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(80)
                }
            }
            .padding(.vertical, 40)
        }
        .ignoresSafeArea(edges: .horizontal)
        .carrelDestinations()
    }
}

// MARK: - Channel

/// A channel: banner, avatar, Follow, and its latest videos (more load as you scroll).
struct TVChannelView: View {
    @Environment(TVModel.self) private var model
    let channelID: String
    let name: String
    var channelClaim: Claim?

    @State private var channel: Claim?
    @State private var videos: [Claim] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false

    var body: some View {
        let ref = ChannelRef(claimId: channelID, name: name, canonicalURL: channel?.canonicalURL, value: channel?.value)
        let following = model.library.isFollowing(channelID)
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                FillImage(url: channel?.value?.cover?.url.flatMap(URL.init(string:)))
                    .frame(height: 280)
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom) }
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 32) {
                            ChannelAvatar(url: channel?.thumbnailURL, name: name, size: 140)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(channel?.title ?? name).font(.title2.weight(.bold))
                                Text(name).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.toggleFollow(ref) } label: {
                                Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                            }
                        }
                        .padding(.horizontal, 80)
                        .offset(y: 40)
                    }
                    .padding(.bottom, 40)

                if let bio = channel?.value?.description, !bio.isEmpty {
                    Text(bio).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .frame(maxWidth: 1400, alignment: .leading)
                        .padding(.horizontal, 80)
                }

                LazyVGrid(columns: gridColumns, spacing: 56) {
                    ForEach(videos) { video in
                        VideoCard(claim: video)
                            .onAppear { if video == videos.last { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal, 80)
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .task {
            if channel == nil { channel = channelClaim }
            if channel == nil { channel = try? await model.client.resolve("lbry://\(name)#\(channelID)") }
            if videos.isEmpty { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        var params = ClaimSearchParams.latest(fromChannels: [channelID], page: page)
        params.pageSize = 24
        guard let result = try? await model.client.claimSearch(params) else { return }
        let fresh = model.filter.apply(result.items).filter { item in !videos.contains { $0.claimId == item.claimId } }
        videos += fresh
        page += 1
        if result.items.count < params.pageSize { reachedEnd = true }
    }
}
