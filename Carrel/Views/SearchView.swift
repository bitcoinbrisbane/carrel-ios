import SwiftUI
import LBRYKit

/// Search: recent searches until you search, then channels, videos from channels you
/// follow, and everything else, loading more as you scroll. The searching itself is
/// LBRYKit's `SearchFeed`, shared with Apple TV (docs/SEARCH.md).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    /// The search on screen (or loading). Nil shows recent searches.
    @State private var submitted: Submitted?
    @State private var results = SearchFeed.Results()
    @State private var phase: Phase = .idle
    @State private var isLoadingMore = false
    @State private var moreError: String?

    private let feed = SearchFeed()

    struct Submitted: Equatable {
        /// New for every submit, so searching the same text again reloads.
        let id = UUID()
        let text: String
        let query: SearchQuery
    }

    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .navigationDestination(for: Claim.self) { ClaimDetailView(claim: $0) }
            .searchable(text: $text, prompt: "Videos, @channels or a link")
            .onSubmit(of: .search) { submit(text) }
            .onChange(of: text) { _, new in
                // Clearing the field goes back to recent searches.
                if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submitted = nil }
            }
            // Changing `submitted` cancels the search in flight, so an older, slower
            // search can't replace a newer one.
            .task(id: submitted) { await runSearch() }
    }

    @ViewBuilder private var content: some View {
        if let submitted {
            resultsList
                .overlay { statusOverlay(for: submitted) }
        } else {
            recentList
        }
    }

    // MARK: Recent searches

    private var recentList: some View {
        List {
            if !model.recentSearches.isEmpty {
                Section {
                    ForEach(model.recentSearches.items, id: \.self) { item in
                        Button {
                            text = item
                            submit(item)
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        let items = offsets.map { model.recentSearches.items[$0] }
                        for item in items { model.recentSearches.remove(item) }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { model.recentSearches.clear() }
                            .font(.subheadline)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.recentSearches.isEmpty {
                ContentUnavailableView(
                    "Search LBRY", systemImage: "magnifyingglass",
                    description: Text("Find videos and channels, or paste an lbry:// or odysee.com link.")
                )
            }
        }
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !results.channels.isEmpty {
                    channelsSection
                }
                if !results.following.isEmpty {
                    sectionHeader("From channels you follow")
                    ForEach(results.following) { videoRow($0) }
                }
                if !results.videos.isEmpty {
                    if !results.following.isEmpty || !results.channels.isEmpty {
                        sectionHeader("Videos")
                    }
                    ForEach(results.videos) { videoRow($0) }
                }
                if results.hasMore, phase == .loaded {
                    moreFooter
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder private var channelsSection: some View {
        if case .text? = submitted?.query {
            sectionHeader("Channels")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results.channels) { ChannelResultCard(claim: $0) }
                }
                .padding(.horizontal)
            }
        } else {
            // An @name search or a channel link: the channels are the results.
            ForEach(results.channels) { ChannelResultRow(claim: $0).padding(.horizontal) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal)
    }

    private func videoRow(_ claim: Claim) -> some View {
        NavigationLink(value: claim) {
            ClaimRow(claim: claim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    /// Loads the next page when scrolled into view.
    @ViewBuilder private var moreFooter: some View {
        Group {
            if let moreError {
                Button("Couldn't load more. Try again") { Task { await loadMore() } }
                    .accessibilityHint(moreError)
            } else {
                ProgressView()
                    // Keyed on the count, so it runs again if a page lands while this is
                    // still on screen (a short page on a tall screen).
                    .task(id: results.following.count + results.videos.count) { await loadMore() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func statusOverlay(for submitted: Submitted) -> some View {
        if phase == .loading {
            ProgressView()
        } else if case .failed(let message) = phase {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { self.submitted = Submitted(text: submitted.text, query: submitted.query) }
            }
        } else if phase == .loaded, results.isEmpty {
            if case .link = submitted.query {
                ContentUnavailableView("Nothing at that link", systemImage: "link",
                                       description: Text("It may have been removed, or Carrel can't show it."))
            } else if submitted.query.isTooShort {
                ContentUnavailableView("Too short to search", systemImage: "character.cursor.ibeam",
                                       description: Text("Type at least \(SearchQuery.minimumSearchLength) characters."))
            } else {
                ContentUnavailableView.search(text: submitted.text)
            }
        }
    }

    // MARK: Searching

    private func submit(_ input: String) {
        guard let query = SearchQuery(input) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Links aren't searches: keep them out of the recent list.
        if case .link = query {} else { model.recentSearches.record(trimmed) }
        submitted = Submitted(text: trimmed, query: query)
    }

    private func runSearch() async {
        results = SearchFeed.Results()
        moreError = nil
        guard let submitted else {
            phase = .idle
            return
        }
        phase = .loading
        do {
            let found = try await feed.start(
                submitted.query,
                filter: model.filter,
                taste: model.taste,
                following: Set(model.library.followedChannelIDs),
                fetcher: .client(model.client)
            )
            guard !Task.isCancelled else { return }   // a newer search took over
            results = found
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard let submitted, case .text(let text) = submitted.query,
              results.hasMore, phase == .loaded, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await feed.loadMore(
                results, for: text, filter: model.filter, taste: model.taste, fetcher: .client(model.client)
            )
            guard self.submitted?.id == submitted.id else { return }   // the search changed meanwhile
            results = more
            moreError = nil
        } catch {
            // Scrolling the footer away cancels the load; it starts again when it's back.
            guard !Task.isCancelled, self.submitted?.id == submitted.id else { return }
            moreError = error.localizedDescription
        }
    }
}

// MARK: - Channels in results

/// A channel in the row above a text search's videos: avatar, names and Follow.
private struct ChannelResultCard: View {
    let claim: Claim

    var body: some View {
        VStack(spacing: 8) {
            NavigationLink(value: claim) {
                VStack(spacing: 6) {
                    ChannelAvatar(url: claim.thumbnailURL, name: claim.name, size: 64)
                    Text(claim.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(claim.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 112)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FollowButton(channel: ChannelRef(channelClaim: claim))
                .controlSize(.small)
        }
    }
}

/// A channel as a full-width row, for an @name search.
private struct ChannelResultRow: View {
    let claim: Claim

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: claim) {
                HStack(spacing: 12) {
                    ChannelAvatar(url: claim.thumbnailURL, name: claim.name, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(claim.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(claim.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FollowButton(channel: ChannelRef(channelClaim: claim))
        }
    }
}
