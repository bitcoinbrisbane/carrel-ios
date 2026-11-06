import SwiftUI
import LBRYKit

/// Shows and edits what the on-device recommender has learned.
struct TasteView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var confirmRestore = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learned on this phone only").font(.subheadline.weight(.semibold))
                        Text("Built from \(model.taste.watchedCount) clips watched to the end, \(model.taste.liked.count) likes and \(model.taste.notForMeCount) “not for me”. Nothing here is sent anywhere.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock").foregroundStyle(Color.carrelAccent)
                }
            }

            Section("Topics") {
                if topics.isEmpty {
                    Text("Like or watch a few Shorts and your topics show up here.").foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    TopicRow(
                        tag: topic.tag,
                        weight: topic.weight,
                        isMuted: model.taste.mutedTopics.contains(topic.tag),
                        toggle: { toggleTopic(topic.tag) }
                    )
                }
            }

            Section("Channels") {
                if channels.isEmpty {
                    Text("Channels you like or mute appear here.").foregroundStyle(.secondary)
                }
                ForEach(channels) { channel in
                    let muted = model.taste.mutedChannels.contains(channel.id)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.taste.channelNames[channel.id] ?? channel.id)
                            Text(muted ? "Muted · won’t appear" : String(format: "Affinity %+.2f", channel.weight))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(muted ? "Unmute" : "Mute") { toggleChannel(channel.id) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Surprise me")
                        Spacer()
                        Text("\(Int((model.taste.exploration * 100).rounded()))% of feed").foregroundStyle(.secondary)
                    }
                    Slider(value: $model.taste.exploration, in: 0...0.4, step: 0.05)
                        .tint(Color.carrelAccent)
                }
                Toggle("Pause learning", isOn: $model.taste.isPaused)
            } header: {
                Text("How your feed is ranked")
            } footer: {
                Text("Clips are scored on topic match, channel affinity and freshness. The surprise share is new-to-you clips so the feed doesn’t get stuck.")
            }

            Section {
                if model.wallet.isReady {
                    LabeledContent("Last backed up") {
                        if let date = model.lastBackup {
                            Text(date, style: .relative) + Text(" ago")
                        } else {
                            Text("Not yet")
                        }
                    }
                    Button("Back up now") { model.backupNow() }
                    Button("Restore from iCloud") { confirmRestore = true }
                } else {
                    Text("Set up your wallet to back this up. It's encrypted with your recovery phrase.")
                        .foregroundStyle(.secondary)
                }
                if let error = model.backupError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("iCloud backup")
            } footer: {
                Text("Your taste, follows and watch history, encrypted with a key from your wallet's recovery phrase. Apple stores it but can't read it; restoring the wallet on a new phone brings it back.")
            }

            Section {
                Button("Reset my taste", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Your taste")
        .confirmationDialog("Reset everything Carrel has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.taste.reset() }
        }
        .confirmationDialog("Restore from iCloud?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { model.restoreBackup(replaceTaste: true) }
        } message: {
            Text("Your taste is replaced by the backed-up one. Follows and history from the backup are added to what's here.")
        }
    }

    private struct WeightRow: Identifiable {
        let id: String
        let weight: Double
        var tag: String { id }
    }

    private var topics: [WeightRow] {
        let tags = Set(model.taste.topics.keys).union(model.taste.mutedTopics)
        return tags.map { WeightRow(id: $0, weight: model.taste.topics[$0] ?? 0) }.sorted { $0.weight > $1.weight }
    }

    private var channels: [WeightRow] {
        let ids = Set(model.taste.channels.keys).union(model.taste.mutedChannels)
        return ids.map { WeightRow(id: $0, weight: model.taste.channels[$0] ?? 0) }.sorted { $0.weight > $1.weight }
    }

    private func toggleTopic(_ tag: String) {
        if model.taste.mutedTopics.contains(tag) {
            model.taste.mutedTopics.remove(tag)
        } else {
            model.taste.mutedTopics.insert(tag)
        }
    }

    private func toggleChannel(_ id: String) {
        if model.taste.mutedChannels.contains(id) {
            model.taste.mutedChannels.remove(id)
        } else {
            model.taste.mutedChannels.insert(id)
        }
    }
}

private struct TopicRow: View {
    let tag: String
    let weight: Double
    let isMuted: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(tag)").frame(width: 110, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(isMuted || weight < 0 ? Color.secondary : Color.carrelAccent)
                        .frame(width: geo.size.width * min(1, abs(weight)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Button(isMuted ? "Hidden" : "Hide", action: toggle)
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isMuted ? "hidden" : String(format: "weight %.2f", weight))
    }
}
