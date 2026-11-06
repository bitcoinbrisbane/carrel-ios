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
    @State private var timeObserver: Any?
    @State private var error: String?
    @State private var showTip = false
    @State private var counts: ReactionCounts?

    var body: some View {
        if isChannel {
            ChannelView(channelID: claim.claimId, name: claim.name, channelClaim: claim)
        } else {
            videoPage
        }
    }

    private var videoPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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

                VStack(alignment: .leading, spacing: 12) {
                    Text(claim.title).font(.title3.weight(.semibold))
                    if let channel = claim.signingChannel {
                        ChannelRow(channel: channel)
                    }
                    HStack(spacing: 12) {
                        if claim.address != nil {
                            Button { showTip = true } label: { Label("Tip", systemImage: "l.circle") }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.carrelAccent)
                                .foregroundStyle(.black)
                        }
                        ShareLink(item: claim.lbryURL) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                        Spacer()
                        if let counts {
                            HStack(spacing: 10) {
                                Label(ReactionCounts.compact(counts.likes), systemImage: "hand.thumbsup")
                                Label(ReactionCounts.compact(counts.dislikes), systemImage: "hand.thumbsdown")
                            }
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(counts.likes) likes and \(counts.dislikes) dislikes on Odysee")
                        }
                    }
                    if let description = claim.value?.description, !description.isEmpty {
                        // URLs, @handles and r/subs become links (see Linkifier).
                        Text(Linkifier.attributed(description))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .tint(Color.carrelAccent)
                            .textSelection(.enabled)
                    }
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
        .sheet(isPresented: $showTip) {
            NavigationStack { TipSheet(claim: claim) }
                .presentationDetents([.medium, .large])
        }
        .task { await load() }
        .task { counts = await model.reactions.counts(for: claim.claimId) }
        .onDisappear { stop() }
    }

    private var isChannel: Bool { claim.valueType == "channel" }

    private func load() async {
        guard player == nil else { return }
        do {
            let url = try await model.client.streamingURL(for: claim.lbryURL)
            let p = AVPlayer(url: url)
            // Pick up where you left off.
            if let resume = model.library.resumePosition(for: claim.claimId) {
                _ = await p.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player = p
            p.play()
            // Save progress every 10 s, for Continue watching.
            let claim = self.claim
            let model = self.model
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main) { [weak p] time in
                MainActor.assumeIsolated {
                    model.recordProgress(claim, position: time.seconds, duration: p?.currentItem?.duration.seconds)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        guard let player else { return }
        player.pause()
        let position = player.currentTime().seconds
        if position.isFinite, position > 0 {
            model.recordProgress(claim, position: position, duration: player.currentItem?.duration.seconds)
        }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

/// Channel name, avatar and a Follow button; tapping the name opens the channel.
struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRef

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                ChannelView(channelID: channel.claimId, name: channel.name)
            } label: {
                HStack(spacing: 10) {
                    ChannelAvatar(url: channel.thumbnailURL, name: channel.name, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(channel.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            FollowButton(channel: channel)
        }
    }
}

struct FollowButton: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRef

    var body: some View {
        let following = model.library.isFollowing(channel.claimId)
        Button(following ? "Following" : "Follow") {
            if following { model.library.unfollow(channel.claimId) } else { model.library.follow(channel) }
        }
        .buttonStyle(.bordered)
        .tint(following ? .secondary : Color.carrelAccent)
        .accessibilityAddTraits(following ? .isSelected : [])
    }
}

struct ChannelAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.25))
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(String(name.dropFirst().prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
