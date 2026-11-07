import SwiftUI
import LBRYKit

private let gridColumns = [GridItem(.adaptive(minimum: 420, maximum: 440), spacing: 48, alignment: .top)]

// MARK: - Search

/// Search with the system's TV keyboard, as you type after a short pause. The same
/// engine as the iPhone (LBRYKit's `SearchFeed`): channels, videos from channels you
/// follow, then everything else, loading more as you scroll. `lbry://` and
/// odysee.com links open directly.
struct TVSearchView: View {
    @Environment(TVModel.self) private var model
    @State private var query = ""
    /// What the results on screen are for.
    @State private var searched: Searched?
    @State private var results = SearchFeed.Results()
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var error: String?

    private let feed: SearchFeed = {
        var feed = SearchFeed()
        feed.pageSize = 24   // whole rows of the grid
        return feed
    }()

    struct Searched: Equatable {
        let text: String
        let query: SearchQuery
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if let error {
                    Text(error).foregroundStyle(.secondary).padding(80)
                } else if let searched, results.isEmpty, !isSearching {
                    Text(emptyMessage(for: searched)).foregroundStyle(.secondary).padding(80)
                }
                if !results.channels.isEmpty {
                    ShelfRow(title: "Channels") {
                        ForEach(results.channels) { ChannelCard(claim: $0) }
                    }
                }
                if !results.following.isEmpty {
                    ShelfRow(title: "From channels you follow") {
                        ForEach(results.following) { VideoCard(claim: $0) }
                    }
                }
                if !results.videos.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        if !results.channels.isEmpty || !results.following.isEmpty {
                            Text("Videos").font(.title3.weight(.semibold)).padding(.horizontal, 80)
                        }
                        LazyVGrid(columns: gridColumns, spacing: 56) {
                            ForEach(results.videos) { claim in
                                VideoCard(claim: claim)
                                    .onAppear { if claim.id == results.videos.last?.id { Task { await loadMore() } } }
                            }
                        }
                        .padding(.horizontal, 80)
                        .focusSection()
                    }
                }
                if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 40)
        }
        .ignoresSafeArea(edges: .horizontal)
        .searchable(text: $query, prompt: "Videos, @channels or an lbry:// link")
        .carrelDestinations()
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func emptyMessage(for searched: Searched) -> String {
        searched.query.isTooShort
            ? "Type at least \(SearchQuery.minimumSearchLength) characters"
            : "Nothing found for “\(searched.text)”"
    }

    private func run() async {
        guard let parsed = SearchQuery(query) else {
            results = SearchFeed.Results()
            searched = nil
            error = nil
            isSearching = false
            return
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        // A cancelled run leaves this to the newer one that replaced it.
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let found = try await feed.start(
                parsed,
                filter: model.filter,
                taste: model.taste,
                following: Set(model.library.followedChannelIDs),
                fetcher: .client(model.client)
            )
            guard !Task.isCancelled else { return }   // still typing: a newer search is on its way
            results = found
            searched = Searched(text: text, query: parsed)
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let current = searched, case .text(let text) = current.query,
              results.hasMore, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let more = try? await feed.loadMore(
            results, for: text, filter: model.filter, taste: model.taste, fetcher: .client(model.client)
        ), searched == current else { return }
        results = more
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
                TVSyncCard()
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
                        Text("Videos you watch and channels you follow show up here. Link your iPhone above to bring yours over.")
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
