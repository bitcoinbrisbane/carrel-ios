import SwiftUI

/// Placeholder for phase 1b: local subscriptions, watch history and downloads.
struct LibraryView: View {
    var body: some View {
        ContentUnavailableView(
            "Your library",
            systemImage: "books.vertical",
            description: Text("Subscriptions, history and downloads live here. They stay on this device — no account needed.")
        )
        .navigationTitle("Library")
    }
}
