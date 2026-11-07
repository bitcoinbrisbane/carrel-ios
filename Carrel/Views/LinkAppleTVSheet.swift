import SwiftUI
import LBRYKit

/// Confirms linking an Apple TV that showed a `carrel://pair-tv` QR code.
struct LinkAppleTVSheet: View {
    let offer: TVPairing.Offer
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linked = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: linked ? "checkmark.circle.fill" : "appletv")
                    .font(.system(size: 44))
                    .foregroundStyle(linked ? Color.green : Color.carrelAccent)
                if linked {
                    Text("Apple TV linked").font(.title2.bold())
                    Text("It picks up your taste, follows and history in a moment, and changes on either device sync from now on. Both need to be signed in to the same iCloud account.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sync with this Apple TV?").font(.title2.bold())
                    Text("Check the TV shows the code **\(offer.id)**.")
                    Text("The TV gets the key to your encrypted taste, follows and watch history. It doesn't get your recovery phrase and can't spend from your wallet.")
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Spacer()
                if linked {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                } else {
                    Button("Link Apple TV") { link() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(!model.wallet.isReady)
                    if !model.wallet.isReady {
                        Text("Open or create your wallet first: the sync key comes from its recovery phrase.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .toolbar {
                if !linked { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }

    private func link() {
        do {
            try model.linkAppleTV(offer)
            linked = true
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}
