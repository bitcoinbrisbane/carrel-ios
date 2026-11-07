import SwiftUI
import LBRYKit

// App Store Guideline 1.2: terms on first launch, report and block everywhere,
// a list of blocked channels, and a published support contact.

/// Shown once, full screen, before anything else.
struct TermsView: View {
    let onAgree: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "hand.raised.square.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.carrelAccent)
                    Text("Before you start").font(.largeTitle.bold())
                    Text(Support.terms).font(.body)
                    if let privacy = Support.privacyURL {
                        Link("Privacy policy", destination: privacy)
                    }
                    if Support.hasEmail {
                        Text("Questions or reports: \(Support.email)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onAgree) {
                    Text("I agree").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.carrelAccent)
                .foregroundStyle(.black)
                .padding(24)
                .background(.bar)
            }
        }
    }
}

/// "…" menu on a video page: Report, Block channel.
struct ModerationMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let claim: Claim
    @State private var reporting = false
    @State private var confirmBlock = false

    var body: some View {
        Menu {
            Button { reporting = true } label: { Label("Report video…", systemImage: "flag") }
            if let channel = claim.signingChannel {
                Button(role: .destructive) { confirmBlock = true } label: {
                    Label("Block \(channel.name)", systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 24, minHeight: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .accessibilityLabel("More: report or block")
        .sheet(isPresented: $reporting) {
            ReportSheet(report: ContentReport(claim: claim), channel: claim.signingChannel) { dismiss() }
        }
        .confirmationDialog(blockTitle, isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let channel = claim.signingChannel { model.block(channel) }
                dismiss()
            }
        } message: {
            Text("You won't see its videos anywhere in Carrel. Unblock in Library › Blocked channels.")
        }
    }

    private var blockTitle: String { "Block \(claim.signingChannel?.name ?? "this channel")?" }
}

/// Pick a reason, add a note, send by email; the video is hidden for you straight away.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var report: ContentReport
    /// The channel to offer blocking (the video's channel, or the channel itself).
    let channel: ChannelRef?
    /// Called after a report is sent, e.g. to leave the reported page.
    var onSent: () -> Void = {}
    @State private var alsoBlock = true
    @State private var mailFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $report.reason) {
                        ForEach(ReportReason.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What's wrong with this \(report.isChannel ? "channel" : "video")?")
                }
                Section("Details (optional)") {
                    TextField("Anything that helps us review it", text: $report.note, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let channel {
                    Section {
                        Toggle("Also block \(channel.name)", isOn: $alsoBlock)
                    }
                }
                if mailFailed {
                    Section {
                        Text("No mail app is set up. Email the report to \(Support.email):")
                        Button("Copy report") { UIPasteboard.general.string = report.subject + "\n\n" + report.body }
                    }
                }
                Section {
                    Button("Send report") { send() }
                        .disabled(!Support.hasEmail)
                } footer: {
                    Text(Support.hasEmail
                         ? "Reports go to \(Support.email) and are reviewed within 24 hours. Anything that breaks Carrel's terms is removed for everyone."
                         : "Reporting isn't set up in this build (no support address).")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func send() {
        // Hide it for this viewer now, whatever happens with the email.
        if !report.isChannel { model.blocks.hide(claimID: report.claimID) }
        if alsoBlock, let channel { model.block(channel) }
        guard let url = report.mailtoURL(to: Support.email) else { return }
        openURL(url) { accepted in
            if accepted {
                dismiss()
                onSent()
            } else {
                mailFailed = true
            }
        }
    }
}

/// Library › Blocked channels.
struct BlockedChannelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let channels = model.blocks.sortedChannels
        List {
            if channels.isEmpty {
                ContentUnavailableView("No blocked channels", systemImage: "hand.raised",
                                       description: Text("Block a channel from a video's ⋯ menu or its channel page."))
            }
            ForEach(channels, id: \.id) { channel in
                HStack {
                    Text(channel.name)
                    Spacer()
                    Button("Unblock") { model.unblock(channelID: channel.id) }.buttonStyle(.bordered)
                }
            }
            if !model.blocks.claims.isEmpty {
                Section {
                    Button("Show \(model.blocks.claims.count) reported videos again") {
                        model.blocks.claims.removeAll()
                    }
                } footer: {
                    Text("Videos you reported are hidden for you.")
                }
            }
        }
        .navigationTitle("Blocked channels")
    }
}

/// Library's About section: support, terms, privacy.
struct SupportSection: View {
    @State private var showTerms = false

    var body: some View {
        Section("About") {
            if Support.hasEmail, let mail = URL(string: "mailto:\(Support.email)") {
                Link(destination: mail) { Label("Contact support", systemImage: "envelope") }
            }
            Button { showTerms = true } label: { Label("Terms of use", systemImage: "doc.text") }
            if let privacy = Support.privacyURL {
                Link(destination: privacy) { Label("Privacy policy", systemImage: "hand.raised") }
            }
        }
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                ScrollView { Text(Support.terms).padding() }
                    .navigationTitle("Terms of use")
                    .toolbar { Button("Done") { showTerms = false } }
            }
        }
    }
}
