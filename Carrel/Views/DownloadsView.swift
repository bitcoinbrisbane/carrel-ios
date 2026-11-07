import SwiftUI
import LBRYKit

/// Download / progress / pause / downloaded, on the video page.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let claim: Claim
    @State private var confirmDelete = false

    var body: some View {
        let downloads = model.downloads
        let record = downloads.record(for: claim.claimId)
        Group {
            switch record?.state {
            case nil:
                Button { Task { await downloads.download(claim, client: model.client) } } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            case .queued?:
                Button {} label: { Label("Starting…", systemImage: "arrow.down.circle.dotted") }.disabled(true)
            case .downloading?:
                Button { downloads.pause(claim.claimId) } label: {
                    HStack(spacing: 6) {
                        ProgressRing(progress: record?.progress)
                        Text(record?.progress.map { "\(Int($0 * 100))%" } ?? "Downloading")
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("Downloading. Tap to pause.")
            case .paused?:
                Button { Task { await downloads.resume(claim.claimId, client: model.client) } } label: {
                    Label("Resume", systemImage: "pause.circle")
                }
            case .finished?:
                Button { confirmDelete = true } label: {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                }
                .tint(.green)
            case .failed?:
                Button { Task { await downloads.download(claim, client: model.client) } } label: {
                    Label("Retry", systemImage: "exclamationmark.arrow.circlepath")
                }
                .tint(.orange)
            }
        }
        .buttonStyle(.bordered)
        .confirmationDialog("Remove the download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { downloads.remove(claim.claimId) }
        } message: {
            Text("You can still stream it.")
        }
    }
}

private struct ProgressRing: View {
    let progress: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
            if let progress {
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.carrelAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Library › Downloads: everything saved for offline, storage used, Wi-Fi only.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var downloads = model.downloads
        let records = downloads.index.records
        List {
            if records.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Tap Download on a video to watch it without a connection."))
            }
            ForEach(records) { record in
                NavigationLink {
                    ClaimDetailView(claim: record.claim)
                } label: {
                    DownloadRow(record: record)
                }
                .swipeActions {
                    Button(role: .destructive) { downloads.remove(record.id) } label: { Label("Delete", systemImage: "trash") }
                    if record.state == .downloading {
                        Button { downloads.pause(record.id) } label: { Label("Pause", systemImage: "pause") }
                    } else if record.state == .paused {
                        Button { Task { await downloads.resume(record.id, client: model.client) } } label: {
                            Label("Resume", systemImage: "play")
                        }
                        .tint(Color.carrelAccent)
                    }
                }
            }
            Section {
                Toggle("Download over Wi-Fi only", isOn: $downloads.wifiOnly)
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: downloads.bytesOnDisk, countStyle: .file))
            } footer: {
                Text("Downloads stay on this iPhone and aren't included in iCloud backups. The Wi-Fi setting applies to new downloads.")
            }
        }
        .navigationTitle("Downloads")
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            VideoThumb(claim: record.claim, progress: record.state == .finished ? nil : record.progress)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.claim.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let channel = record.claim.signingChannel {
                    Text(channel.name).font(.caption).foregroundStyle(.secondary)
                }
                Text(status).font(.caption2).foregroundStyle(statusColor)
            }
        }
    }

    private var status: String {
        let size = ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file)
        switch record.state {
        case .queued: return "Starting…"
        case .downloading:
            if let p = record.progress {
                let total = record.bytesExpected > 0 ? " of " + ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file) : ""
                return "\(Int(p * 100))% · \(size)\(total)"
            }
            return "Downloading…"
        case .paused: return "Paused"
        case .finished: return "Downloaded · \(size)"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private var statusColor: Color {
        switch record.state {
        case .finished: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
