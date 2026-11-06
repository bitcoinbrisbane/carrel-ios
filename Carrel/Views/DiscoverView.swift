import SwiftUI
import LBRYKit

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var claims: [Claim] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(claims) { claim in
                NavigationLink(value: claim) { ClaimRow(claim: claim) }
                    .onAppear { if claim == claims.last { Task { await loadMore() } } }
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .navigationTitle("Discover")
        .navigationDestination(for: Claim.self) { ClaimDetailView(claim: $0) }
        .refreshable { await reload() }
        .task { if claims.isEmpty { await reload() } }
        .overlay {
            if let error, claims.isEmpty {
                ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(error))
            }
        }
    }

    private func reload() async {
        page = 1
        claims = []
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.client.claimSearch(
                .trending(page: page, notTags: Array(model.filter.blockedTags))
            )
            claims += model.filter.apply(result.items)
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
