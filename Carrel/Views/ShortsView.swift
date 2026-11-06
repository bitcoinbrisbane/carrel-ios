import SwiftUI
import AVKit
import Combine
import LBRYKit

/// Full-screen vertical feed of short clips, ranked on device. Swipe for the
/// next one; like and "Not for me" tune what comes next.
struct ShortsView: View {
    @Environment(AppModel.self) private var model

    @State private var items: [RankedClaim] = []
    @State private var currentID: String?
    @State private var shownAt = Date()
    @State private var page = 1
    @State private var isLoading = false
    @State private var error: String?
    @State private var feedbackFor: RankedClaim?
    @State private var tipFor: RankedClaim?
    @State private var toast: String?

    private let feed = ShortsFeed()
    /// Leaving a clip sooner than this counts as a skip.
    private let quickSkipSeconds: TimeInterval = 2

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    ShortPage(
                        item: item,
                        isActive: item.id == currentID,
                        isLiked: model.taste.liked.contains(item.id),
                        onLike: { toggleLike(item) },
                        onNotForMe: { feedbackFor = item },
                        onTip: { tipFor = item },
                        onFinished: { model.record(.watchedToEnd, on: item.claim) }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(Color.black)
        .overlay {
            if items.isEmpty {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't load Shorts", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await reload() } }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.thickMaterial, in: Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "Show me less of…",
            isPresented: Binding(get: { feedbackFor != nil }, set: { if !$0 { feedbackFor = nil } }),
            titleVisibility: .visible,
            presenting: feedbackFor
        ) { item in
            notForMeButtons(item)
        } message: { _ in
            Text("This stays on your phone and tunes your feed.")
        }
        .sheet(item: $tipFor) { item in
            NavigationStack { TipSheet(claim: item.claim) }
                .presentationDetents([.medium, .large])
        }
        .task { if items.isEmpty { await reload() } }
        .onChange(of: currentID) { oldID, newID in
            leave(oldID)
            shownAt = Date()
            prefetchAround(newID)
            loadMoreIfNeeded(newID)
        }
    }

    // MARK: Feedback

    @ViewBuilder
    private func notForMeButtons(_ item: RankedClaim) -> some View {
        let channel = item.claim.signingChannel?.name
        let tag = TasteProfile.tags(of: item.claim).first

        Button("Not interested in this video") {
            apply(.notInterested, to: item, toast: "Got it. Skipped.")
        }
        if let channel {
            Button("Less from \(channel)") {
                apply(.lessChannel, to: item, toast: "You'll see less from \(channel).")
            }
        }
        if let tag {
            Button("Less #\(tag)") {
                apply(.lessTopic(tag), to: item, toast: "Turning down #\(tag).")
            }
        }
        if let channel {
            Button("Hide \(channel) completely", role: .destructive) {
                apply(.muteChannel, to: item, toast: "\(channel) muted. Undo in Your taste.")
            }
        }
    }

    private func apply(_ signal: TasteProfile.Signal, to item: RankedClaim, toast message: String) {
        model.record(signal, on: item.claim)
        // Drop anything now hidden (e.g. the rest of a muted channel) and move on.
        let ranker = feed.ranker
        let index = items.firstIndex(of: item) ?? 0
        let upcoming = items[(index + 1)...].filter { ranker.isAllowed($0.claim, taste: model.taste) }
        items = Array(items[...index]) + upcoming
        withAnimation { currentID = upcoming.first?.id ?? currentID }
        showToast(message)
    }

    private func toggleLike(_ item: RankedClaim) {
        let liked = model.taste.liked.contains(item.id)
        model.record(liked ? .unlike : .like, on: item.claim)
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { if toast == message { toast = nil } }
        }
    }

    // MARK: Watch signals

    private func leave(_ id: String?) {
        guard let id, let item = items.first(where: { $0.id == id }) else { return }
        if Date().timeIntervalSince(shownAt) < quickSkipSeconds {
            model.record(.quickSkip, on: item.claim)
        } else {
            model.taste.markSeen(id)
        }
    }

    // MARK: Loading

    private func reload() async {
        page = 1
        items = []
        error = nil
        await loadPage()
        currentID = items.first?.id
        shownAt = Date()
        prefetchAround(currentID)
    }

    private func loadPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ranked = try await feed.load(page: page, taste: model.taste, filter: model.filter, client: model.client)
            let known = Set(items.map(\.id))
            items += ranked.filter { !known.contains($0.id) }
            page += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMoreIfNeeded(_ id: String?) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }), index >= items.count - 4 else { return }
        Task { await loadPage() }
    }

    private func prefetchAround(_ id: String?) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let next = items.dropFirst(index + 1).prefix(2).map(\.claim)
        let streams = model.streams, client = model.client
        Task { await streams.prefetch(next, client: client) }
    }
}

/// One clip: video filling the screen, info at the bottom, actions on the right.
private struct ShortPage: View {
    @Environment(AppModel.self) private var model

    let item: RankedClaim
    let isActive: Bool
    let isLiked: Bool
    let onLike: () -> Void
    let onNotForMe: () -> Void
    let onTip: () -> Void
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var reportedFinish = false

    var body: some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: item.claim.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(white: 0.08)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onTapGesture { player.timeControlStatus == .playing ? player.pause() : player.play() }
            }

            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                info
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .foregroundStyle(.white)
        .task(id: isActive) {
            if isActive { await start() } else { player?.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let player, (note.object as? AVPlayerItem) === player.currentItem else { return }
            if !reportedFinish { reportedFinish = true; onFinished() }
            player.seek(to: .zero)
            player.play()   // loop, like other short-video apps
        }
        .onDisappear { player?.pause() }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let channel = item.claim.signingChannel {
                Text(channel.name).font(.subheadline.weight(.semibold))
            }
            Text(item.claim.title).font(.subheadline).lineLimit(3)
            Label(item.reason.text, systemImage: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.carrelAccent, in: Capsule())
            if failed {
                Text("Couldn't load this clip").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 18) {
            ActionButton(
                systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                label: "Like",
                tint: isLiked ? .carrelAccent : .white,
                action: onLike
            )
            .accessibilityAddTraits(isLiked ? .isSelected : [])
            ActionButton(systemImage: "hand.thumbsdown", label: "Not for me", action: onNotForMe)
            ActionButton(systemImage: "l.circle", label: "Tip", action: onTip)
            ShareLink(item: item.claim.lbryURL) {
                ActionLabel(systemImage: "arrowshape.turn.up.right", label: "Share")
            }
        }
    }

    private func start() async {
        if player == nil {
            do {
                let url = try await model.streams.url(for: item.claim, client: model.client)
                let p = AVPlayer(url: url)
                p.isMuted = false
                player = p
            } catch {
                failed = true
                return
            }
        }
        guard isActive else { return }
        player?.play()
    }
}

private struct ActionButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionLabel(systemImage: systemImage, label: label, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct ActionLabel: View {
    let systemImage: String
    let label: String
    var tint: Color = .white

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.4), in: Circle())
            Text(label).font(.caption2.weight(.semibold))
        }
        .frame(minWidth: 60)
        .contentShape(Rectangle())
    }
}

/// AVPlayerLayer without system controls, filling its frame.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspectFill
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

extension Color {
    /// Carrel's "desk lamp" amber, from the mock screens.
    static let carrelAccent = Color(red: 242.0 / 255, green: 181.0 / 255, blue: 68.0 / 255)
}
