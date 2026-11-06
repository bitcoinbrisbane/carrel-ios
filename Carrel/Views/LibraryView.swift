import SwiftUI

/// Library: personal, on-device things. Subscriptions, history and downloads come next.
struct LibraryView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    TasteView()
                } label: {
                    Label("Your taste", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("What Carrel has learned from your Shorts. It stays on this device.")
            }

            Section("Coming soon") {
                Label("Subscriptions", systemImage: "person.2")
                Label("History", systemImage: "clock")
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Library")
    }
}
