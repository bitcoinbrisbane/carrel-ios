import SwiftUI
import AVKit
import LBRYKit

/// A video's page: backdrop, details, Play / Resume, Like, Follow and Tip.
/// Playback is full screen in the system player (scrubbing, info panel, subtitles).
struct TVVideoView: View {
    @Environment(TVModel.self) private var model
    let claim: Claim
    @State private var playing: Double?          // start position when presented
    @State private var showTip = false

    var body: some View {
        if claim.valueType == "channel" {
            TVChannelView(channelID: claim.claimId, name: claim.name, channelClaim: claim)
        } else {
            page
        }
    }

    private var page: some View {
        let resume = model.library.resumePosition(for: claim.claimId)
        let liked = model.taste.liked.contains(claim.claimId)
        return ZStack(alignment: .bottomLeading) {
            FillImage(url: claim.thumbnailURL)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.95), .black.opacity(0.6), .black.opacity(0.2)],
                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                        .ignoresSafeArea()
                }

            VStack(alignment: .leading, spacing: 28) {
                Text(claim.title).font(.title.weight(.bold)).lineLimit(3)

                HStack(spacing: 24) {
                    if let channel = claim.signingChannel {
                        NavigationLink(value: ChannelRoute(id: channel.claimId, name: channel.name)) {
                            HStack(spacing: 14) {
                                ChannelAvatar(url: channel.thumbnailURL, name: channel.name, size: 52)
                                Text(channel.title)
                            }
                        }
                    }
                    if let date = claim.releaseDate {
                        Text(date, format: .dateTime.day().month().year()).foregroundStyle(.secondary)
                    }
                    if let d = claim.duration {
                        Text(Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                if let description = claim.value?.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .frame(maxWidth: 1200, alignment: .leading)
                }

                HStack(spacing: 32) {
                    Button {
                        playing = resume ?? 0
                    } label: {
                        Label(resume == nil ? "Play" : "Resume", systemImage: "play.fill")
                    }
                    if resume != nil {
                        Button { playing = 0 } label: { Label("From the start", systemImage: "backward.end.fill") }
                    }
                    Button { model.toggleLike(claim) } label: {
                        Label(liked ? "Liked" : "Like", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    if let channel = claim.signingChannel {
                        let following = model.library.isFollowing(channel.claimId)
                        Button { model.toggleFollow(channel) } label: {
                            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                        }
                    }
                    if claim.address != nil {
                        Button { showTip = true } label: { Label("Tip", systemImage: "l.circle") }
                    }
                }
            }
            .padding(80)
        }
        .fullScreenCover(item: Binding(
            get: { playing.map { PlayRequest(start: $0) } },
            set: { if $0 == nil { playing = nil } }
        )) { request in
            TVPlayerScreen(claim: claim, start: request.start)
        }
        .sheet(isPresented: $showTip) { TipWithPhoneView(claim: claim) }
    }
}

private struct PlayRequest: Identifiable {
    let start: Double
    var id: Double { start }
}

/// Resolves the stream, plays from `start`, and saves progress every 10 s and on exit.
struct TVPlayerScreen: View {
    @Environment(TVModel.self) private var model
    let claim: Claim
    let start: Double
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                SystemPlayer(player: player).ignoresSafeArea()
            } else if let error {
                VStack(spacing: 20) {
                    Text("Can't play this").font(.title3)
                    Text(error).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .onDisappear { stop() }
    }

    private func load() async {
        guard player == nil else { return }
        do {
            let url = try await model.streams.url(for: claim, client: model.client)
            let item = AVPlayerItem(url: url)
            item.externalMetadata = metadata()
            let p = AVPlayer(playerItem: item)
            if start > 0 { _ = await p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            player = p
            p.play()
            let claim = self.claim, model = self.model
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

    /// Title and channel for the player's info panel.
    private func metadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, claim.title)]
        if let channel = claim.signingChannel { items.append(item(.iTunesMetadataTrackSubTitle, channel.title)) }
        if let description = claim.value?.description, !description.isEmpty {
            items.append(item(.commonIdentifierDescription, String(description.prefix(500))))
        }
        return items
    }
}

/// The system player (AVPlayerViewController): transport bar, info panel, Siri remote.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
