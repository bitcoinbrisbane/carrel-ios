import SwiftUI
import LBRYKit

/// "For you" on the big screen: a featured video and rows, ranked on device with
/// the same `HomeFeed` as the iPhone app.
struct TVHomeView: View {
    @Environment(TVModel.self) private var model
    @State private var page: HomeFeed.Page?
    @State private var isLoading = false
    @State private var error: String?
    @State private var discover = DiscoverStore()

    private let feed = HomeFeed()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 56) {
                if let featured = page?.featured {
                    FeaturedBanner(item: featured, match: page?.featuredMatch)
                }
                ForEach(page?.rows ?? []) { row in
                    ShelfRow(title: row.title, subtitle: row.style == .continueWatching ? nil : row.subtitle) {
                        ForEach(row.items) { item in
                            VideoCard(claim: item.claim,
                                      progress: row.style == .continueWatching ? model.library.entry(for: item.id)?.progress : nil)
                        }
                    }
                }
                if page != nil {
                    ForEach(discover.shelves) { shelf in
                        DiscoverShelfRow(shelf: shelf, store: discover)
                    }
                    MoreToWatchGrid(store: discover)
                }
                if page == nil, isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 600)
                }
                if let error, page == nil {
                    VStack(spacing: 24) {
                        Text("Couldn't load videos").font(.title3)
                        Text(error).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, minHeight: 600)
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationDestination(for: Claim.self) { TVVideoView(claim: $0) }
        .task { if page == nil { await load() } }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let taste = model.taste, library = model.library, filter = model.filter, client = model.client
        let queries = feed.queries(taste: taste, library: library, blockedTags: Array(filter.blockedTags))
        var results: [HomeFeed.Source: [Claim]] = [:]
        await withTaskGroup(of: (HomeFeed.Source, [Claim]?).self) { group in
            for q in queries {
                group.addTask { (q.source, try? await client.claimSearch(q.params).items) }
            }
            for await (source, claims) in group {
                if let claims { results[source] = claims }
            }
        }
        if results.isEmpty {
            error = "Check the Apple TV's network connection."
            return
        }
        let newPage = feed.page(results: results, taste: taste, library: library, filter: filter)
        page = newPage
        error = nil
        let shown = Set(([newPage.featured].compactMap { $0 } + newPage.rows.flatMap(\.items)).map(\.id))
        discover.reset(shelves: feed.discoverShelves(taste: taste, blockedTags: Array(filter.blockedTags)),
                       shown: shown, taste: taste, filter: filter, client: client)
    }
}

/// Discover shelves and the endless "More to watch" grid under the personal rows.
/// Each shelf loads when it scrolls into view; a video appears at most once on the page.
@Observable
@MainActor
final class DiscoverStore {
    private(set) var shelves: [HomeFeed.Shelf] = []
    private(set) var loaded: [String: [Claim]] = [:]
    private(set) var more: [Claim] = []
    private(set) var moreFinished = false

    private var shown: Set<String> = []
    private var loading: Set<String> = []
    /// Next trending page for the grid (page 1 already fed the rows).
    private(set) var morePage = 2
    private var taste = TasteProfile()
    private var filter = ContentFilter()
    private var client: LBRYClient?
    private let feed = HomeFeed()

    func reset(shelves: [HomeFeed.Shelf], shown: Set<String>, taste: TasteProfile, filter: ContentFilter, client: LBRYClient) {
        self.shelves = shelves
        self.shown = shown
        self.taste = taste
        self.filter = filter
        self.client = client
        loaded = [:]
        more = []
        morePage = 2
        moreFinished = false
        loading = []
    }

    /// Nil until loaded; empty if the shelf had nothing new.
    func items(for shelf: HomeFeed.Shelf) -> [Claim]? { loaded[shelf.id] }

    func load(_ shelf: HomeFeed.Shelf) async {
        guard loaded[shelf.id] == nil, let client, loading.insert(shelf.id).inserted else { return }
        defer { loading.remove(shelf.id) }
        let found = (try? await client.claimSearch(shelf.params).items) ?? []
        loaded[shelf.id] = take(found, limit: 15)
    }

    func loadMore() async {
        guard !moreFinished, let client, loading.insert("more").inserted else { return }
        defer { loading.remove("more") }
        // Keep going (up to 3 pages) until something new turns up, so the grid's
        // "load more" trigger, its last card, always moves.
        for _ in 0..<3 {
            let params = feed.moreToWatchQuery(page: morePage, taste: taste, blockedTags: Array(filter.blockedTags))
            guard let page = try? await client.claimSearch(params) else { return }
            let fresh = take(page.items, limit: .max)
            more += fresh
            morePage += 1
            if page.items.count < params.pageSize || morePage > 25 { moreFinished = true }
            if !fresh.isEmpty || moreFinished { return }
        }
    }

    private func take(_ claims: [Claim], limit: Int) -> [Claim] {
        var out: [Claim] = []
        for claim in filter.apply(claims) where feed.isLong(claim) && feed.ranker.isAllowed(claim, taste: taste) {
            guard out.count < limit, shown.insert(claim.claimId).inserted else { continue }
            out.append(claim)
        }
        return out
    }
}

private struct DiscoverShelfRow: View {
    let shelf: HomeFeed.Shelf
    let store: DiscoverStore

    var body: some View {
        Group {
            if let items = store.items(for: shelf) {
                if !items.isEmpty {
                    ShelfRow(title: shelf.title, subtitle: shelf.subtitle) {
                        ForEach(items) { VideoCard(claim: $0) }
                    }
                }
            } else {
                // Placeholder with the shelf's height, so scrolling doesn't jump while it loads.
                VStack(alignment: .leading, spacing: 20) {
                    Text(shelf.title).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
                .padding(.horizontal, 80)
            }
        }
        .task { await store.load(shelf) }
    }
}

private struct MoreToWatchGrid: View {
    let store: DiscoverStore
    private let columns = [GridItem(.adaptive(minimum: 420, maximum: 440), spacing: 48, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("More to watch").font(.title3.weight(.semibold)).padding(.horizontal, 80)
            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(store.more) { claim in
                    VideoCard(claim: claim)
                        .onAppear { if claim.claimId == store.more.last?.claimId { Task { await store.loadMore() } } }
                }
            }
            .padding(.horizontal, 80)
            if !store.moreFinished {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await store.loadMore() }
            }
        }
    }
}

/// The best match, full width, with its "% match".
private struct FeaturedBanner: View {
    let item: RankedClaim
    let match: Int?

    var body: some View {
        NavigationLink(value: item.claim) {
            FillImage(url: item.claim.thumbnailURL)
                .frame(height: 620)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.2), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            if let match {
                                Text("\(match)% match").foregroundStyle(Color.carrelAccent)
                            }
                            Text(item.reason.text).foregroundStyle(.white.opacity(0.75))
                        }
                        .font(.callout.weight(.semibold))
                        Text(item.claim.title)
                            .font(.title.weight(.bold))
                            .lineLimit(2)
                            .frame(maxWidth: 1100, alignment: .leading)
                        if let channel = item.claim.signingChannel {
                            Text(channel.title).font(.headline).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(64)
                }
        }
        .buttonStyle(.card)
        .padding(.horizontal, 80)
        .padding(.top, 20)
    }
}
