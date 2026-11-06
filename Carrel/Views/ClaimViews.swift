import SwiftUI
import AVKit
import LBRYKit

struct ClaimRow: View {
    let claim: Claim

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: claim.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if let d = claim.duration {
                    Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(claim.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let channel = claim.signingChannel {
                    Text(channel.title).font(.caption).foregroundStyle(.secondary)
                }
                if let date = claim.releaseDate {
                    Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ClaimDetailView: View {
    @Environment(AppModel.self) private var model
    let claim: Claim
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isChannel {
                    AsyncImage(url: claim.value?.cover?.url.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(height: 140)
                    .clipped()
                } else {
                    ZStack {
                        if let player {
                            VideoPlayer(player: player)
                        } else if let error {
                            ContentUnavailableView("Can't play this", systemImage: "play.slash", description: Text(error))
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(claim.title).font(.title3.weight(.semibold))
                    if let channel = claim.signingChannel {
                        Label(channel.title, systemImage: "person.crop.circle").font(.subheadline)
                    }
                    if let description = claim.value?.description, !description.isEmpty {
                        // URLs, @handles and r/subs become links (see Linkifier).
                        Text(Linkifier.attributed(description))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .tint(Color.carrelAccent)
                            .textSelection(.enabled)
                    }
                    ShareLink(item: claim.lbryURL) { Label("Share lbry:// link", systemImage: "square.and.arrow.up") }
                }
                .padding(.horizontal)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            // LBRY and Odysee links open here; everything else (x.com, reddit.com, the web)
            // goes to the system, which hands x.com and reddit.com to their apps if installed.
            if Linkifier.kind(ofWebURL: url) == .lbry || url.scheme?.lowercased() == "lbry" {
                player?.pause()
                model.open(url.absoluteString)
                return .handled
            }
            return .systemAction
        })
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private var isChannel: Bool { claim.valueType == "channel" }

    private func load() async {
        guard player == nil, !isChannel else { return }
        do {
            let url = try await model.client.streamingURL(for: claim.lbryURL)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
