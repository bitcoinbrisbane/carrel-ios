import SwiftUI
import LBRYKit

/// "For you": filter chips, a featured video, and rows ranked on this phone.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    enum Chip: Hashable {
        case forYou
        case following
        case topic(String)

        var label: String {
            switch self {
            case .forYou: return "For you"
            case .following: return "Following"
            case .topic(let tag): return "#\(tag)"
            }
        }
    }

    @State private var chip: Chip = .forYou
    @State private var page: HomeFeed.Page?
    @State private var list: [RankedClaim] = []
    @State private var isLoading = false
    @State private var error: String?

    private let feed = HomeFeed()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                chipsRow
                if chip == .forYou {
                    if let page {
                        if let featured = page.featured {
                            FeaturedCard(item: featured, match: page.featuredMatch)
                        }
                        ForEach(page.rows) { row in RowView(row: row) }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(list) { item in
                            NavigationLink(value: item.claim) { ClaimRow(claim: item.claim) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .overlay {
            if isLoading, page == nil, list.isEmpty {
                ProgressView()
            } else if let error, page == nil {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if chip == .following, list.isEmpty, !isLoading {
                ContentUnavailableView("No channels yet", systemImage: "person.2",
                                       description: Text("Tap Follow on a channel and its new videos show up here."))
            }
        }
        .navigationTitle("carrel")
        .navigationDestination(for: Claim.self) { ClaimDetailView(claim: $0) }
        .refreshable { await load() }
        .task(id: chip) { await load() }
    }

    // MARK: Chips

    private var chips: [Chip] {
        [.forYou, .following] + model.taste.topTopics(3).map { .topic($0.tag) }
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { c in
                    Button(c.label) { chip = c }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(chip == c ? Color.primary : Color.clear, in: Capsule())
                        .foregroundStyle(chip == c ? Color(uiColor: .systemBackground) : Color.primary)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(chip == c ? 0 : 0.4)))
                        .accessibilityAddTraits(chip == c ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let taste = model.taste
        let library = model.library
        let filter = model.filter
        let client = model.client
        let blocked = Array(filter.blockedTags)
        do {
            switch chip {
            case .forYou:
                let queries = feed.queries(taste: taste, library: library, blockedTags: blocked)
                var results: [HomeFeed.Source: [Claim]] = [:]
                try await withThrowingTaskGroup(of: (HomeFeed.Source, [Claim]?).self) { group in
                    for q in queries {
                        group.addTask { (q.source, try? await client.claimSearch(q.params).items) }
                    }
                    for try await (source, claims) in group {
                        if let claims { results[source] = claims }
                    }
                }
                if results.isEmpty { throw LBRYError.emptyResult("claim_search") }
                page = feed.page(results: results, taste: taste, library: library, filter: filter)
            case .following:
                list = []
                guard !library.following.isEmpty else { return }
                let params = feed.chipQuery(.following, taste: taste, library: library, blockedTags: blocked)
                list = filter.apply(try await client.claimSearch(params).items).filter(feed.isLong)
                    .map { RankedClaim(claim: $0, score: 0, reason: .trending) }
            case .topic(let tag):
                let params = feed.chipQuery(.topic(tag), taste: taste, library: library, blockedTags: blocked)
                list = feed.ranker.rank(filter.apply(try await client.claimSearch(params).items).filter(feed.isLong), taste: taste)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Featured

private struct FeaturedCard: View {
    let item: RankedClaim
    let match: Int?

    var body: some View {
        NavigationLink(value: item.claim) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.15)
                    .overlay {
                        AsyncImage(url: item.claim.thumbnailURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.carrelAccent, in: RoundedRectangle(cornerRadius: 6))
                    Text(item.claim.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let channel = item.claim.signingChannel {
                        Text([channel.name, item.claim.duration.map(Self.minutes)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(16)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private var badge: String {
        let reason = item.reason == .trending ? "Trending on LBRY" : item.reason.text.prefix(1).lowercased() + item.reason.text.dropFirst()
        if let match { return "\(match)% match · \(reason)" }
        return String(reason.prefix(1).uppercased() + reason.dropFirst())
    }

    static func minutes(_ seconds: Int) -> String { "\(max(1, seconds / 60)) min" }
}

// MARK: - Rows

private struct RowView: View {
    @Environment(AppModel.self) private var model
    let row: HomeFeed.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.headline)
                Spacer()
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        NavigationLink(value: item.claim) {
                            VideoCard(
                                claim: item.claim,
                                progress: row.style == .continueWatching ? model.library.entry(for: item.id)?.progress : nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct VideoCard: View {
    let claim: Claim
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(white: 0.15)
                .overlay {
                    AsyncImage(url: claim.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .frame(width: 168, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if let d = claim.duration {
                        Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.3))
                                Rectangle().fill(Color.carrelAccent).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                    }
                }
            Text(claim.title).font(.footnote.weight(.medium)).lineLimit(2).frame(width: 168, alignment: .leading)
            if let channel = claim.signingChannel {
                Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 168, alignment: .leading)
    }
}
