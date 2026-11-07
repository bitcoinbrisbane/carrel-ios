import SwiftUI
import LBRYKit

/// Shown once before anything else (Guideline 1.2).
struct TVTermsView: View {
    let onAgree: () -> Void
    @FocusState private var agreeFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "hand.raised.square.fill").font(.system(size: 80)).foregroundStyle(Color.carrelAccent)
                Text("Before you start").font(.title.bold())
                Button("I agree", action: onAgree)
                    .focused($agreeFocused)
                if Support.hasEmail {
                    Text("Questions or reports:\n\(Support.email)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 520, alignment: .leading)
            ScrollView {
                Text(Support.terms).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()       // so the remote can scroll it
        }
        .padding(100)
        // A full-screen cover on tvOS is see-through by default: without this, Home
        // showed through and the "I agree" button was lost behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .defaultFocus($agreeFocused, true)
        .onAppear { agreeFocused = true }
    }
}

/// Reporting from the TV: pick a reason, then email it from the phone via a QR code.
/// The video is hidden on this TV either way.
struct TVReportView: View {
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var report: ContentReport
    var onDone: () -> Void = {}
    @State private var chosen = false

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            if chosen, let mail = report.mailtoURL(to: Support.email) {
                QRCodeImage(text: mail.absoluteString)
                    .padding(28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .frame(width: 480, height: 480)
                    .accessibilityLabel("QR code to email this report from your phone")
                VStack(alignment: .leading, spacing: 24) {
                    Text("Send the report").font(.title2.bold())
                    Text("Scan with your phone's camera to email it to \(Support.email). Reports are reviewed within 24 hours.")
                        .foregroundStyle(.secondary)
                    Text("Reason: \(report.reason.title)").font(.headline)
                    Text("This video is hidden on this Apple TV now.").font(.callout).foregroundStyle(.secondary)
                    Button("Done") { dismiss(); onDone() }
                }
                .frame(maxWidth: 760, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Report “\(report.title)”").font(.title2.bold()).lineLimit(2)
                    Text("What's wrong with it?").foregroundStyle(.secondary)
                    if !Support.hasEmail {
                        Text("Reporting isn't set up in this build (no support address).").foregroundStyle(.orange)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ReportReason.allCases) { reason in
                                Button(reason.title) {
                                    report.reason = reason
                                    model.blocks.hide(claimID: report.claimID)
                                    chosen = true
                                }
                                .disabled(!Support.hasEmail)
                            }
                            Button("Cancel") { dismiss() }
                        }
                        .padding(.vertical, 12)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(80)
    }
}
