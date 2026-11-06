import SwiftUI
import LBRYKit

/// "For you" on the big screen: a featured video and rows, ranked on device with
/// the same `HomeFeed` as the iPhone app.
struct TVHomeView: View {
    @Environment(TVModel.self) private var model
    @State private var page: HomeFeed.Page?
    @State private var isLoading = false
    @State private var error: String?

    private let feed = HomeFeed()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 56) {
                if let featured = page?.featured {
                    FeaturedBanner(item: featured, match: page?.featuredMatch)
                }
                ForEach(page?.rows ?? []) { row in
                    ShelfRow(title: row.title, subtitle: row.subtitle) {
                        ForEach(row.items) { item in
                            VideoCard(claim: item.claim,
                                      progress: row.style == .continueWatching ? model.library.entry(for: item.id)?.progress : nil)
                        }
                    }
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
        page = feed.page(results: results, taste: taste, library: library, filter: filter)
        error = nil
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
