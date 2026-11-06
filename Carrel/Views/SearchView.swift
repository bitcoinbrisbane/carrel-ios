import SwiftUI
import LBRYKit

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Claim] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        List(results) { claim in
            NavigationLink(value: claim) { ClaimRow(claim: claim) }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .navigationDestination(for: Claim.self) { ClaimDetailView(claim: $0) }
        .searchable(text: $query, prompt: "Videos or an lbry:// link")
        .onSubmit(of: .search) { Task { await run() } }
        .overlay {
            if isSearching { ProgressView() }
            else if let error { ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if results.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            // A pasted link resolves directly; anything else goes to full-text search.
            if text.contains("lbry://") || text.contains("odysee.com") || text.hasPrefix("@"),
               let uri = LBRYURL.normalise(text) {
                results = try await model.client.resolve(uri).map { [$0] } ?? []
            } else {
                results = try await model.client.search(text)
            }
            results = model.filter.apply(results)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
