import SwiftUI
import LBRYKit

/// Tip a video's creator in LBC: pick an amount, review the fee, send.
/// The tip is an LBRY support output paying the claim's address, so it shows
/// as a tip on the creator's side in Odysee and LBRY Desktop too.
struct TipSheet: View {
    let claim: Claim

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount: UInt64 = 1 * LBCNetwork.dewiesPerLBC
    @State private var customText = ""
    @State private var prepared: Wallet.Prepared?
    @State private var isWorking = false
    @State private var error: String?
    @State private var sent = false

    private let presets: [UInt64] = [1, 5, 10, 25].map { $0 * LBCNetwork.dewiesPerLBC }

    var body: some View {
        let wallet = model.wallet
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(claim.title).font(.headline).lineLimit(2)
                    if let channel = claim.signingChannel {
                        Text(channel.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            switch wallet.phase {
            case .needsSetup:
                Section {
                    Text("Set up your wallet first, then come back to tip.").foregroundStyle(.secondary)
                    NavigationLink("Set up wallet") { WalletSetupView().navigationTitle("Wallet") }
                }
            case .ready:
                if sent {
                    Section {
                        Label("Tip sent. Thanks for supporting \(claim.signingChannel?.name ?? "this creator").",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    tipForm(wallet)
                }
            case .failed(let message):
                Section { Text(message).foregroundStyle(.orange) }
            case .idle, .loading:
                Section { ProgressView("Opening wallet…") }
            }
        }
        .navigationTitle("Tip in LBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(sent ? "Done" : "Cancel") { dismiss() } }
        .task { await wallet.startIfNeeded() }
    }

    @ViewBuilder
    private func tipForm(_ wallet: WalletModel) -> some View {
        Section {
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { value in
                    Button("\(LBCAmount.format(value))") {
                        amount = value
                        customText = ""
                        prepared = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(amount == value && customText.isEmpty ? Color.carrelAccent : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                TextField("Other amount", text: $customText)
                    .keyboardType(.decimalPad)
                    .onChange(of: customText) {
                        if let v = LBCAmount.parse(customText), v > 0 { amount = v }
                        prepared = nil
                    }
                Text("LBC").foregroundStyle(.secondary)
            }
        } header: {
            Text("Amount")
        } footer: {
            if let balance = wallet.snapshot?.confirmedBalance {
                Text("Balance: \(LBCAmount.format(balance)) LBC")
            }
        }

        if let prepared {
            Section("Review") {
                LabeledContent("Tip", value: "\(LBCAmount.format(prepared.amount)) LBC")
                LabeledContent("Network fee", value: "\(LBCAmount.format(prepared.fee)) LBC")
            }
        }
        if let error {
            Section { Text(error).foregroundStyle(.orange) }
        }
        Section {
            Button(prepared == nil ? "Review tip" : "Send \(LBCAmount.format(amount)) LBC") {
                Task { await primaryAction(wallet) }
            }
            .disabled(isWorking || amount == 0 || claim.address == nil)
            if claim.address == nil {
                Text("This video doesn't list an address to tip.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func primaryAction(_ wallet: WalletModel) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepared {
                _ = try await wallet.broadcast(prepared)
                sent = true
            } else {
                prepared = try await wallet.prepareTip(for: claim, amount: amount)
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}
