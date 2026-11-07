import SwiftUI
import LBRYKit

/// Browse LBRY on the TV: pick Trending, New, Top this week / month or a topic
/// along the top, and page through a grid of videos below.
struct TVDiscoverView: View {
    @Environment(TVModel.self) private var model
    @State private var store = DiscoverGridStore()
    @State private var sections: [HomeFeed.DiscoverSection] = []
    @State private var selected: HomeFeed.DiscoverSection = .trending

    private let feed = HomeFeed()
    private let columns = [GridItem(.adaptive(minimum: 420, maximum: 440), spacing: 48, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                ScrollView(.horizontal) {
                    HStack(spacing: 24) {
                        ForEach(sections) { section in
                            SectionButton(title: section.title, isSelected: section == selected) {
                                selected = section
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                .focusSection()

                let grid = store.grid(for: selected)
                LazyVGrid(columns: columns, spacing: 56) {
                    ForEach(grid.items) { claim in
                        VideoCard(claim: claim)
                            .onAppear {
                                if claim.claimId == grid.items.last?.claimId { Task { await loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()

                if grid.items.isEmpty, grid.finished {
                    Text("Nothing here right now.").foregroundStyle(.secondary).padding(.horizontal, 80)
                } else if !grid.finished {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationDestination(for: Claim.self) { TVVideoView(claim: $0) }
        .task {
            if sections.isEmpty { sections = feed.discoverSections(taste: model.taste) }
        }
        .task(id: selected) {
            if store.grid(for: selected).items.isEmpty { await loadMore() }
        }
    }

    private func loadMore() async {
        await store.loadMore(selected, feed: feed, taste: model.taste, filter: model.filter, client: model.client)
    }
}

/// One pill in the section row; the selected one is filled.
private struct SectionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        if isSelected {
            Button(action: action) { Text(title) }.buttonStyle(.borderedProminent).tint(.carrelAccent)
        } else {
            Button(action: action) { Text(title) }.buttonStyle(.bordered)
        }
    }
}

/// Paged results per section, kept while you switch between sections.
@Observable
@MainActor
final class DiscoverGridStore {
    struct Grid {
        var items: [Claim] = []
        var page = 1
        var finished = false
        var ids: Set<String> = []
    }

    private var grids: [String: Grid] = [:]
    private var loading: Set<String> = []

    func grid(for section: HomeFeed.DiscoverSection) -> Grid { grids[section.id] ?? Grid() }

    func loadMore(_ section: HomeFeed.DiscoverSection, feed: HomeFeed, taste: TasteProfile,
                  filter: ContentFilter, client: LBRYClient) async {
        var grid = grids[section.id] ?? Grid()
        guard !grid.finished, loading.insert(section.id).inserted else { return }
        defer { loading.remove(section.id) }
        // Up to 3 pages until something new turns up, so the last card always moves on.
        for _ in 0..<3 {
            let params = feed.discoverQuery(section, page: grid.page, taste: taste, blockedTags: Array(filter.blockedTags))
            guard let result = try? await client.claimSearch(params) else { break }
            let fresh = filter.apply(result.items).filter { claim in
                feed.isLong(claim) && feed.ranker.isAllowed(claim, taste: taste) && grid.ids.insert(claim.claimId).inserted
            }
            grid.items += fresh
            grid.page += 1
            if result.items.count < params.pageSize || grid.page > 25 { grid.finished = true }
            if !fresh.isEmpty || grid.finished { break }
        }
        grids[section.id] = grid
    }
}
