import SwiftUI
import AVKit
import Combine
import LBRYKit

/// Shorts on the TV: one clip at a time, centred, ranked on device.
/// Swipe down (or up) on the remote for the next (or previous) clip, click or
/// Play/Pause to pause, swipe right for Like, Not for me, Follow and Tip.
struct TVShortsView: View {
    @Environment(TVModel.self) private var model

    @State private var items: [RankedClaim] = []
    @State private var index = 0
    @State private var page = 1
    @State private var mode: Mode = .forYou
    @State private var isLoading = false
    @State private var error: String?
    @State private var player: AVPlayer?
    @State private var isPaused = false
    @State private var shownAt = Date()
    @State private var toast: String?
    @State private var tipFor: Claim?
    @FocusState private var focus: Focus?

    enum Mode: String { case forYou = "For you", following = "Following" }
    enum Focus: Hashable { case clip }

    private let feed = ShortsFeed()
    private let quickSkipSeconds: TimeInterval = 2

    private var current: RankedClaim? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let current {
                HStack(alignment: .center, spacing: 64) {
                    info(current).frame(width: 560, alignment: .leading)
                    clip
                    actions(current).frame(width: 360, alignment: .leading)
                }
                .padding(.horizontal, 60)
            } else if isLoading {
                ProgressView()
            } else {
                VStack(spacing: 24) {
                    Text(mode == .following && model.library.following.isEmpty
                         ? "Follow some channels to see their Shorts here."
                         : (error ?? "No Shorts right now."))
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await reload() } }
                    if mode == .following { Button("Show For you") { switchMode() } }
                }
            }
            if let toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(.thinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
                    .transition(.opacity)
            }
        }
        .task { if items.isEmpty { await reload() } }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let player, (note.object as? AVPlayerItem) === player.currentItem, let current else { return }
            model.record(.watchedToEnd, on: current.claim)
            move(by: 1)
        }
        .sheet(item: $tipFor) { TipWithPhoneView(claim: $0) }
    }

    // MARK: Pieces

    /// The video, 9:16, focusable so the remote's swipes come here.
    private var clip: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let player {
                PlayerLayer(player: player)
            } else {
                ProgressView()
            }
            if isPaused {
                Image(systemName: "pause.fill").font(.system(size: 80)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(focus == .clip ? Color.white.opacity(0.6) : Color.clear, lineWidth: 4)
        }
        .padding(.vertical, 40)
        .focusable()
        .focused($focus, equals: .clip)
        .onMoveCommand { direction in
            switch direction {
            case .down: move(by: 1)
            case .up: move(by: -1)
            default: break
            }
        }
        .onPlayPauseCommand { togglePause() }
        .onTapGesture { togglePause() }
        .defaultFocus($focus, .clip)
    }

    private func info(_ item: RankedClaim) -> some View {
        let tags = TasteProfile.tags(of: item.claim)
        return VStack(alignment: .leading, spacing: 20) {
            Text(mode.rawValue.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Color.carrelAccent)
            Text(item.claim.title).font(.title3.weight(.bold)).lineLimit(4)
            if let channel = item.claim.signingChannel {
                HStack(spacing: 14) {
                    ChannelAvatar(url: channel.thumbnailURL, name: channel.name, size: 52)
                    Text(channel.title).font(.headline)
                }
            }
            Text(item.reason.text).font(.callout).foregroundStyle(.secondary)
            if !tags.isEmpty {
                Text(tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer().frame(height: 20)
            Text("Swipe ▲▼ for more · ▶︎ for actions")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func actions(_ item: RankedClaim) -> some View {
        let liked = model.taste.liked.contains(item.id)
        return VStack(alignment: .leading, spacing: 20) {
            Button { model.toggleLike(item.claim) } label: {
                Label(liked ? "Liked" : "Like", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Menu {
                Button("Skip this clip") { apply(.notInterested, to: item, toast: "Got it, fewer like this") }
                if let channel = item.claim.signingChannel {
                    Button("Less from \(channel.name)") { apply(.lessChannel, to: item, toast: "Less from \(channel.name)") }
                    Button("Hide \(channel.name)") { apply(.muteChannel, to: item, toast: "\(channel.name) hidden") }
                }
                if let tag = TasteProfile.tags(of: item.claim).first {
                    Button("Less #\(tag)") { apply(.lessTopic(tag), to: item, toast: "Less #\(tag)") }
                }
            } label: {
                Label("Not for me", systemImage: "hand.thumbsdown")
            }
            if let channel = item.claim.signingChannel {
                let following = model.library.isFollowing(channel.claimId)
                Button { model.toggleFollow(channel) } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                }
            }
            if item.claim.address != nil {
                Button { player?.pause(); isPaused = true; tipFor = item.claim } label: { Label("Tip", systemImage: "l.circle") }
            }
            Button { switchMode() } label: {
                Label(mode == .forYou ? "Following" : "For you", systemImage: "arrow.left.arrow.right")
            }
        }
    }

    // MARK: Playback

    private func togglePause() {
        guard let player else { return }
        if isPaused { player.play() } else { player.pause() }
        isPaused.toggle()
    }

    private func move(by step: Int) {
        let next = index + step
        guard items.indices.contains(next) else { return }
        leaveCurrent()
        index = next
        Task { await startCurrent() }
        if next >= items.count - 4 { Task { await loadPage() } }
    }

    private func leaveCurrent() {
        guard let current else { return }
        if Date().timeIntervalSince(shownAt) < quickSkipSeconds {
            model.record(.quickSkip, on: current.claim)
        } else {
            model.taste.markSeen(current.id)
        }
    }

    private func startCurrent() async {
        player?.pause()
        player = nil
        isPaused = false
        shownAt = Date()
        guard let current else { return }
        let id = current.id
        if let url = try? await model.streams.url(for: current.claim, client: model.client), self.current?.id == id {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        let upcoming = items.dropFirst(index + 1).prefix(2).map(\.claim)
        let streams = model.streams, client = model.client
        Task { await streams.prefetch(upcoming, client: client) }
    }

    private func apply(_ signal: TasteProfile.Signal, to item: RankedClaim, toast message: String) {
        model.record(signal, on: item.claim)
        let ranker = feed.ranker, taste = model.taste
        let upcoming = items[(index + 1)...].filter { ranker.isAllowed($0.claim, taste: taste) }
        items = Array(items[...index]) + upcoming
        show(message)
        move(by: 1)
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { if toast == message { toast = nil } }
        }
    }

    private func switchMode() {
        mode = mode == .forYou ? .following : .forYou
        Task { await reload() }
    }

    // MARK: Loading

    private func reload() async {
        player?.pause()
        player = nil
        items = []
        index = 0
        page = 1
        await loadPage()
        await startCurrent()
        focus = .clip
    }

    private func loadPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ranked: [RankedClaim]
            switch mode {
            case .forYou:
                ranked = try await feed.load(page: page, taste: model.taste, filter: model.filter, client: model.client)
            case .following:
                ranked = try await feed.loadFollowing(page: page, library: model.library, taste: model.taste,
                                                      filter: model.filter, client: model.client)
            }
            let known = Set(items.map(\.id))
            items += ranked.filter { !known.contains($0.id) }
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// AVPlayerLayer without system controls, so the remote drives the feed.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
