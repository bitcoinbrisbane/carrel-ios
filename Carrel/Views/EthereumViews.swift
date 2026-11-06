import SwiftUI
import LBRYKit

/// Ethereum section of the Wallet tab: balances, receive, and wrapping LBC.
struct EthereumSection: View {
    @Environment(AppModel.self) private var model
    @State private var showReceive = false
    @State private var showWrap = false

    var body: some View {
        let wallet = model.wallet
        Section {
            if let balances = wallet.ethBalances {
                ForEach(balances.rows) { row in
                    HStack {
                        TokenBadge(symbol: row.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.symbol).font(.subheadline.weight(.semibold))
                            Text(row.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.amount?.formatted(maxFractionDigits: row.symbol == "ETH" ? 5 : 2) ?? "—")
                            .font(.body.monospacedDigit())
                            .accessibilityLabel(row.amount == nil ? "unavailable" : "\(row.amount!.formatted()) \(row.symbol)")
                    }
                }
            } else if wallet.ethereum != nil {
                HStack { ProgressView(); Text("Reading Ethereum…").foregroundStyle(.secondary) }
            }

            HStack(spacing: 12) {
                Button { showReceive = true } label: {
                    Label("Receive", systemImage: "arrow.down").frame(maxWidth: .infinity)
                }
                Button { showWrap = true } label: {
                    Label("Wrap LBC", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(wallet.ethereum == nil)

            if !wallet.bridgeDeposits.isEmpty {
                ForEach(wallet.bridgeDeposits.prefix(3)) { BridgeDepositRow(deposit: $0) }
            }
        } header: {
            Text("Ethereum")
        } footer: {
            if let address = wallet.ethereum?.address {
                Text("\(address.prefix(8))…\(address.suffix(6)) · same recovery phrase, so it also opens in MetaMask")
            }
        }
        .sheet(isPresented: $showReceive) {
            NavigationStack { EthereumReceiveView(address: wallet.ethereum?.address ?? "") }
        }
        .sheet(isPresented: $showWrap) {
            NavigationStack { WrapView() }
        }
    }
}

private struct TokenBadge: View {
    let symbol: String

    var body: some View {
        Text(String(symbol.prefix(symbol == "wLBC" ? 4 : 1)))
            .font(.caption2.weight(.bold))
            .frame(width: 32, height: 32)
            .background(color.opacity(0.2), in: Circle())
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch symbol {
        case "ETH": return .indigo
        case "USDC": return .blue
        case "USDT": return .green
        default: return .carrelAccent
        }
    }
}

struct BridgeDepositRow: View {
    let deposit: LBCBridge.Deposit

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(deposit.status == .minted ? Color.green : Color.carrelAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wrap \(LBCAmount.format(deposit.amount)) LBC").font(.subheadline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch deposit.status {
        case .pending: return "clock"
        case .ready: return "checkmark.circle"
        case .minted: return "checkmark.seal.fill"
        }
    }

    private var caption: String {
        switch deposit.status {
        case .pending: return "\(deposit.confirmations) of 6 confirmations"
        case .ready: return "Ready to mint wLBC"
        case .minted: return "wLBC minted"
        }
    }
}

struct EthereumReceiveView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            if let qr = QRCode.image(for: address) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code for your Ethereum address")
            }
            Text(address).font(.callout.monospaced()).multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal)
            HStack {
                Button {
                    UIPasteboard.general.string = address
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: address) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)
            Text("Ethereum mainnet only: ETH, USDC, USDT and wLBC. Sending from another network can lose funds.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 32)
        .navigationTitle("Receive on Ethereum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
}

/// Wrap LBC into wLBC with lbc.exchange: get this wallet's verified deposit address,
/// send LBC to it from the Carrel wallet, and follow it to "minted".
struct WrapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var offer: LBCBridge.DepositOffer?
    @State private var amountText = ""
    @State private var prepared: Wallet.Prepared?
    @State private var isWorking = false
    @State private var error: String?
    @State private var sentTxid: String?

    var body: some View {
        let wallet = model.wallet
        Form {
            Section {
                Text("lbc.exchange holds your LBC and mints the same amount of wLBC on Ethereum, 1:1, to your Ethereum address in this wallet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Section("Deposit address") {
                if let offer {
                    Text(offer.depositAddress).font(.callout.monospaced()).textSelection(.enabled)
                    Label("Signed by the bridge's on-chain signer", systemImage: "checkmark.shield")
                        .font(.footnote).foregroundStyle(.green)
                } else if error == nil {
                    HStack { ProgressView(); Text("Getting your address…").foregroundStyle(.secondary) }
                }
            }

            if offer != nil, sentTxid == nil {
                Section {
                    HStack {
                        TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                            .onChange(of: amountText) { prepared = nil }
                        Text("LBC").foregroundStyle(.secondary)
                    }
                    if let prepared {
                        LabeledContent("Network fee", value: "\(LBCAmount.format(prepared.fee)) LBC")
                    }
                    Button(prepared == nil ? "Review" : "Send \(amountText) LBC to the bridge") { Task { await primary() } }
                        .disabled(isWorking || LBCAmount.parse(amountText) == nil)
                } header: {
                    Text("Wrap from this wallet")
                } footer: {
                    if let balance = wallet.snapshot?.confirmedBalance {
                        Text("Available: \(LBCAmount.format(balance)) LBC. Needs \(offer?.minConfirmations ?? 6) confirmations (about 15 minutes).")
                    }
                }
            }

            if let sentTxid {
                Section {
                    Label("Sent to the bridge", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentTxid).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            if !wallet.bridgeDeposits.isEmpty {
                Section {
                    ForEach(wallet.bridgeDeposits) { BridgeDepositRow(deposit: $0) }
                } header: {
                    Text("Your deposits")
                } footer: {
                    Text("Once a deposit is ready, mint it at lbc.exchange by connecting a wallet with this same recovery phrase (MetaMask shows the same Ethereum address). Minting from inside Carrel is coming next.")
                }
                Section {
                    Button("Open lbc.exchange") { openURL(LBCBridge.website) }
                }
            }

            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("Wrap LBC → wLBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
        .refreshable { await model.wallet.refreshEthereum() }
        .task { await loadOffer() }
    }

    private func loadOffer() async {
        do {
            offer = try await model.wallet.verifiedDepositOffer()
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
        await model.wallet.refreshEthereum()
    }

    private func primary() async {
        guard let offer, let amount = LBCAmount.parse(amountText) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepared {
                sentTxid = try await model.wallet.broadcast(prepared)
                await model.wallet.refreshEthereum()
            } else {
                prepared = try await model.wallet.prepareSend(to: offer.depositAddress, amount: amount)
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}
