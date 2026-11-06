import SwiftUI
import LBRYKit

// MARK: - Shared pieces

/// ETH or one of the tokens Carrel shows.
enum EthereumAsset: Hashable, Identifiable {
    case eth
    case token(ERC20Token)

    static let all: [EthereumAsset] = [.eth] + ERC20Token.mainnetDefaults.map { .token($0) }

    var symbol: String {
        switch self {
        case .eth: return "ETH"
        case .token(let t): return t.symbol
        }
    }
    var decimals: Int {
        switch self {
        case .eth: return 18
        case .token(let t): return t.decimals
        }
    }
    var id: String { symbol }

    func call(to address: String, amount: UInt256) throws -> EthereumCall {
        switch self {
        case .eth: return try EthereumCall.sendETH(to: address, wei: amount)
        case .token(let t): return try EthereumCall.transfer(t, to: address, amount: amount)
        }
    }
}

extension WalletModel {
    /// Balance of one asset, in its smallest units, if it has been read.
    func ethereumBalance(_ asset: EthereumAsset) -> TokenAmount? {
        ethBalances?.rows.first { $0.symbol == asset.symbol }?.amount
    }
}

extension TokenAmount {
    /// Whether this balance covers `amount` smallest units.
    func covers(_ amount: UInt256) -> Bool {
        guard let needed = Decimal(string: amount.decimalString) else { return false }
        return units >= needed
    }
}

/// The fee lines every Ethereum review shows.
struct EthereumFeeRows: View {
    let prepared: PreparedEthereumTx

    var body: some View {
        LabeledContent("Network fee", value: "≈ \(prepared.expectedFeeETH) ETH")
        LabeledContent("At most", value: "\(prepared.maxFeeETH) ETH")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

struct EthereumActivityRow: View {
    let item: EthereumActivity

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isOpen { ProgressView().controlSize(.small) }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = item.hash } label: { Label("Copy transaction hash", systemImage: "doc.on.doc") }
            Link(destination: URL(string: "https://etherscan.io/tx/\(item.hash)")!) {
                Label("View on Etherscan", systemImage: "safari")
            }
        }
    }

    private var icon: String {
        switch item.state {
        case .submitted, .awaitingPayout: return "clock"
        case .confirmed, .paid: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .confirmed, .paid: return .green
        case .failed: return .orange
        default: return .carrelAccent
        }
    }

    private var caption: String {
        if let detail = item.detail { return detail }
        switch item.state {
        case .submitted: return "Waiting for Ethereum…"
        case .confirmed: return "Confirmed"
        case .awaitingPayout: return "Waiting for 12 Ethereum confirmations, then the bridge pays LBC"
        case .paid: return "LBC paid to your wallet"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Send ETH and tokens

struct EthereumSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var asset: EthereumAsset = .eth
    @State private var address = ""
    @State private var amountText = ""
    @State private var prepared: PreparedEthereumTx?
    @State private var isWorking = false
    @State private var error: String?
    @State private var sentHash: String?

    private var amount: UInt256? { UInt256(units: amountText, decimals: asset.decimals).flatMap { $0 == .zero ? nil : $0 } }
    private var addressIsValid: Bool { EthereumAddress.isValid(address.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Form {
            if let sentHash {
                Section {
                    Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentHash).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Shows as confirmed in the Wallet tab once it's in a block.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Asset", selection: $asset) {
                        ForEach(EthereumAsset.all) { Text($0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: asset) { prepared = nil }
                }
                Section("To") {
                    TextField("0x… Ethereum address", text: $address, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) { prepared = nil }
                    if !address.isEmpty, !addressIsValid {
                        Text("That isn't a valid Ethereum address (or its checksum is wrong).").font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    HStack {
                        TextField("0.0", text: $amountText).keyboardType(.decimalPad)
                            .onChange(of: amountText) { prepared = nil }
                        Text(asset.symbol).foregroundStyle(.secondary)
                    }
                    if !amountText.isEmpty, amount == nil {
                        Text("\(asset.symbol) has \(asset.decimals) decimal places.").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    if let balance = model.wallet.ethereumBalance(asset) {
                        Text("Available: \(balance.formatted(maxFractionDigits: 6)) \(asset.symbol). Ethereum mainnet only; fees are paid in ETH.")
                    }
                }
                if let prepared, let amount {
                    Section("Review") {
                        LabeledContent("Send", value: "\(amount.formatted(decimals: asset.decimals)) \(asset.symbol)")
                        LabeledContent("To", value: "\(address.prefix(8))…\(address.suffix(6))")
                        EthereumFeeRows(prepared: prepared)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button(prepared == nil ? "Review" : "Send now") { Task { await primary() } }
                        .disabled(isWorking || !addressIsValid || amount == nil)
                    if isWorking { ProgressView() }
                }
            }
        }
        .navigationTitle("Send on Ethereum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(sentHash == nil ? "Cancel" : "Done") { dismiss() } }
    }

    private func primary() async {
        guard let amount else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepared {
                sentHash = try await model.wallet.submitEthereum(
                    prepared, kind: .send,
                    title: "Sent \(amount.formatted(decimals: asset.decimals, maxFractionDigits: 6)) \(asset.symbol)")
            } else {
                if let balance = model.wallet.ethereumBalance(asset), !balance.covers(amount) {
                    throw SendCheck.notEnough(asset.symbol)
                }
                prepared = try await model.wallet.prepareEthereum(asset.call(to: address.trimmingCharacters(in: .whitespaces), amount: amount))
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}

private enum SendCheck: LocalizedError {
    case notEnough(String)
    var errorDescription: String? {
        switch self {
        case .notEnough(let symbol): return "Not enough \(symbol) in this wallet."
        }
    }
}

// MARK: - Mint wLBC

/// Mints wLBC for a confirmed lbc.exchange deposit: bridge approval → checked against
/// `Bridge.signer()` → `Bridge.wrap` from this wallet.
struct MintView: View {
    let deposit: LBCBridge.Deposit
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var call: EthereumCall?
    @State private var dewies: UInt64 = 0
    @State private var prepared: PreparedEthereumTx?
    @State private var status: String?
    @State private var error: String?
    @State private var isWorking = false
    @State private var sentHash: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Deposit", value: "\(LBCAmount.format(deposit.amount)) LBC")
                LabeledContent("You receive", value: "\(LBCAmount.format(dewies == 0 ? deposit.amount : dewies)) wLBC")
                if let address = model.wallet.ethereum?.address {
                    LabeledContent("To", value: "\(address.prefix(8))…\(address.suffix(6))")
                }
            }
            if call != nil {
                Section {
                    Label("Approval signed by the bridge contract's signer", systemImage: "checkmark.shield")
                        .font(.footnote).foregroundStyle(.green)
                }
            }
            if let prepared {
                Section("Review") { EthereumFeeRows(prepared: prepared) }
            }
            if let status { Section { Text(status).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            if let sentHash {
                Section {
                    Label("Mint submitted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentHash).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if prepared != nil {
                Section {
                    Button("Mint wLBC") { Task { await submit() } }.disabled(isWorking)
                    if isWorking { ProgressView() }
                }
            } else if isWorking {
                Section { HStack { ProgressView(); Text("Getting the bridge's approval…").foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle("Mint wLBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(sentHash == nil ? "Cancel" : "Done") { dismiss() } }
        .task { await load() }
    }

    private func load() async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await model.wallet.mintCall(for: deposit) {
            case .alreadyMinted:
                status = "This deposit has already been minted."
                await model.wallet.refreshEthereum()
            case .waiting(let confirmations, let required):
                status = "Waiting for LBC confirmations: \(confirmations) of \(required)."
            case .ready(let call, let dewies):
                self.call = call
                self.dewies = dewies
                prepared = try await model.wallet.prepareEthereum(call)
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }

    private func submit() async {
        guard let prepared else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            sentHash = try await model.wallet.submitEthereum(prepared, kind: .mint,
                                                              title: "Minted \(LBCAmount.format(dewies)) wLBC")
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}

// MARK: - Unwrap wLBC → LBC

/// Burns wLBC with `Bridge.unwrap`; lbc.exchange pays the same amount of LBC to an
/// LBC address (this wallet's by default) after 12 Ethereum confirmations.
struct UnwrapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var lbcAddress = ""
    @State private var prepared: PreparedEthereumTx?
    @State private var isWorking = false
    @State private var error: String?
    @State private var sentHash: String?

    private var dewies: UInt64? { LBCAmount.parse(amountText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        Form {
            Section {
                Text("Unwrapping burns wLBC on Ethereum. After 12 Ethereum confirmations (about 3 minutes) lbc.exchange sends the same amount of LBC to the address below, and pays the LBC network fee itself.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let sentHash {
                Section {
                    Label("Unwrap submitted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentHash).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Carrel asks the bridge for your LBC once Ethereum confirms it; follow it in the Wallet tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack {
                        TextField("0.0", text: $amountText).keyboardType(.decimalPad)
                            .onChange(of: amountText) { prepared = nil }
                        Text("wLBC").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    if let balance = model.wallet.ethereumBalance(.token(.wlbc)) {
                        Text("Available: \(balance.formatted(maxFractionDigits: 8)) wLBC")
                    }
                }
                Section {
                    TextField("LBC address", text: $lbcAddress, axis: .vertical)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: lbcAddress) { prepared = nil }
                    if !lbcAddress.isEmpty, !LBCAddress.isValid(lbcAddress) {
                        Text("That isn't an LBC address.").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Pay LBC to")
                } footer: {
                    if lbcAddress == model.wallet.snapshot?.receiveAddress {
                        Text("Your Carrel LBC wallet.")
                    }
                }
                if let prepared, let dewies {
                    Section("Review") {
                        LabeledContent("Burn", value: "\(LBCAmount.format(dewies)) wLBC")
                        LabeledContent("Receive", value: "\(LBCAmount.format(dewies)) LBC")
                        EthereumFeeRows(prepared: prepared)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button(prepared == nil ? "Review" : "Unwrap now") { Task { await primary() } }
                        .disabled(isWorking || dewies == nil || !LBCAddress.isValid(lbcAddress))
                    if isWorking { ProgressView() }
                }
            }
        }
        .navigationTitle("Unwrap wLBC → LBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(sentHash == nil ? "Cancel" : "Done") { dismiss() } }
        .onAppear {
            if lbcAddress.isEmpty, let mine = model.wallet.snapshot?.receiveAddress { lbcAddress = mine }
        }
    }

    private func primary() async {
        guard let dewies else { return }
        let amount = UInt256(dewies)   // wLBC has 8 decimals, the same as dewies
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepared {
                sentHash = try await model.wallet.submitEthereum(prepared, kind: .unwrap,
                                                                  title: "Unwrapped \(LBCAmount.format(dewies)) wLBC")
            } else {
                if let balance = model.wallet.ethereumBalance(.token(.wlbc)), !balance.covers(amount) {
                    throw UnwrapCheck.notEnough
                }
                prepared = try await model.wallet.prepareEthereum(
                    EthereumCall.bridgeUnwrap(amount: amount, lbcAddress: lbcAddress.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}

private enum UnwrapCheck: LocalizedError {
    case notEnough
    var errorDescription: String? { "Not enough wLBC in this wallet." }
}
