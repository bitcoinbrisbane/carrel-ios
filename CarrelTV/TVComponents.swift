import SwiftUI
import CoreImage.CIFilterBuiltins
import LBRYKit

extension Color {
    static let carrelAccent = Color(red: 242.0 / 255, green: 181.0 / 255, blue: 68.0 / 255)
}

/// A remote image that fills its frame, cropped (the frame never grows to the image).
struct FillImage: View {
    let url: URL?

    var body: some View {
        Color.white.opacity(0.08)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .clipped()
    }
}

/// A video in a row: a focusable 16:9 card, with the title and channel underneath.
struct VideoCard: View {
    let claim: Claim
    var width: CGFloat = 420
    var progress: Double? = nil
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: claim) {
                FillImage(url: claim.thumbnailURL)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottomTrailing) {
                        if let d = claim.duration {
                            Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            GeometryReader { geo in
                                Rectangle().fill(Color.carrelAccent)
                                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: 6)
                            }
                            .frame(height: 6)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(claim.title).font(.callout.weight(.medium)).lineLimit(2)
                HStack(spacing: 8) {
                    if let badge {
                        Text(badge).foregroundStyle(Color.carrelAccent)
                    }
                    if let channel = claim.signingChannel {
                        Text(channel.title).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

/// A horizontally scrolling row with a heading.
struct ShelfRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content() }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            // Moving down from anywhere above lands in this row, even when its first
            // card isn't directly below what has focus (#24).
            .focusSection()
        }
    }
}

struct ChannelAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 80

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.12))
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

/// A channel in a row: avatar card opening the channel.
struct ChannelCard: View {
    let id: String
    let name: String
    let title: String
    let thumbnailURL: URL?

    /// A channel the viewer follows.
    init(channel: UserLibrary.FollowedChannel) {
        id = channel.claimId
        name = channel.name
        title = channel.title
        thumbnailURL = channel.thumbnailURL.flatMap(URL.init(string:))
    }

    /// A channel's own claim, e.g. from search.
    init(claim: Claim) {
        id = claim.claimId
        name = claim.name
        title = claim.title
        thumbnailURL = claim.thumbnailURL
    }

    var body: some View {
        NavigationLink(value: ChannelRoute(id: id, name: name)) {
            VStack(spacing: 14) {
                ChannelAvatar(url: thumbnailURL, name: name, size: 160)
                Text(title).font(.callout).lineLimit(1).frame(width: 200)
            }
            .padding(12)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Navigation

/// A channel page as a navigation value. Every push in the TV app is value-based
/// (`Claim` or `ChannelRoute`): mixing in destination-style links made a video
/// opened from a channel page show the channel again (#19).
struct ChannelRoute: Hashable {
    let id: String
    let name: String
}

extension View {
    /// The destinations every tab's NavigationStack needs: videos and channels.
    func carrelDestinations() -> some View {
        navigationDestination(for: Claim.self) { TVVideoView(claim: $0) }
            .navigationDestination(for: ChannelRoute.self) { TVChannelView(channelID: $0.id, name: $0.name) }
    }
}

// MARK: - Tip with the phone

/// The link Carrel on iPhone opens to tip this video: `carrel://tip?uri=lbry://…`.
enum PhoneTip {
    static func link(for claim: Claim) -> URL? {
        var components = URLComponents()
        components.scheme = "carrel"
        components.host = "tip"
        components.queryItems = [URLQueryItem(name: "uri", value: claim.lbryURL)]
        return components.url
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.white
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Tipping from the TV: scan with the iPhone and Carrel there shows the tip sheet.
struct TipWithPhoneView: View {
    let claim: Claim
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 80) {
            if let link = PhoneTip.link(for: claim) {
                QRCodeImage(text: link.absoluteString)
                    .padding(28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .frame(width: 480, height: 480)
                    .accessibilityLabel("QR code to tip this video in Carrel on iPhone")
            }
            VStack(alignment: .leading, spacing: 24) {
                Text("Tip with your iPhone").font(.title2.weight(.bold))
                Text("Scan with the iPhone camera. Carrel opens with the tip ready to send from your wallet: no keys live on this Apple TV.")
                    .font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(claim.title).font(.headline).lineLimit(2)
                    if let channel = claim.signingChannel {
                        Text(channel.title).foregroundStyle(.secondary)
                    }
                }
                Button("Done") { dismiss() }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(80)
    }
}
