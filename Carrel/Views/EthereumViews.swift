import SwiftUI
import LBRYKit

/// Ethereum section of the Wallet tab: balances, receive, and wrapping LBC.
struct EthereumSection: View {
    @Environment(AppModel.self) private var model
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showWrap = false
    @State private var showUnwrap = false

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

            EthereumActions(showReceive: $showReceive, showSend: $showSend, showWrap: $showWrap, showUnwrap: $showUnwrap)
                .disabled(wallet.ethereum == nil)

            ForEach(Array(wallet.ethActivity.prefix(3))) { item in
                EthereumActivityRow(item: item)
            }
            ForEach(openDeposits) { deposit in
                BridgeDepositRow(deposit: deposit, onMint: nil)
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
        .sheet(isPresented: $showSend) {
            NavigationStack { EthereumSendView() }
        }
        .sheet(isPresented: $showWrap) {
            NavigationStack { WrapView() }
        }
        .sheet(isPresented: $showUnwrap) {
            NavigationStack { UnwrapView() }
        }
    }
}

extension EthereumSection {
    /// Deposits not yet minted, newest few.
    fileprivate var openDeposits: [LBCBridge.Deposit] {
        Array(model.wallet.bridgeDeposits.filter { $0.status != .minted }.prefix(3))
    }
}

/// Receive / Send / Wrap / Unwrap buttons.
private struct EthereumActions: View {
    @Binding var showReceive: Bool
    @Binding var showSend: Bool
    @Binding var showWrap: Bool
    @Binding var showUnwrap: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                button("Receive", "arrow.down") { showReceive = true }
                button("Send", "arrow.up") { showSend = true }
            }
            HStack(spacing: 12) {
                button("Wrap LBC", "arrow.right.circle") { showWrap = true }
                button("Unwrap", "arrow.left.circle") { showUnwrap = true }
            }
        }
        .buttonStyle(.bordered)
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
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
    var onMint: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(deposit.status == .minted ? Color.green : Color.carrelAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wrap \(LBCAmount.format(deposit.amount)) LBC").font(.subheadline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if deposit.status == .ready, let onMint {
                Button("Mint", action: onMint).buttonStyle(.borderedProminent).controlSize(.small)
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
    @State private var minting: LBCBridge.Deposit?

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
                    ForEach(wallet.bridgeDeposits) { deposit in
                        BridgeDepositRow(deposit: deposit, onMint: { minting = deposit })
                    }
                } header: {
                    Text("Your deposits")
                } footer: {
                    Text("Once a deposit has 6 confirmations, Mint asks the bridge for a signed approval, checks it against the bridge contract, and submits Bridge.wrap from your Ethereum address. Minting costs ETH gas.")
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
        .sheet(item: $minting) { deposit in
            NavigationStack { MintView(deposit: deposit) }
        }
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
