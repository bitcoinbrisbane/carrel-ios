import SwiftUI
import CoreImage.CIFilterBuiltins
import LBRYKit

/// Wallet tab: setup on first use, then balance, receive, send and activity.
struct WalletView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let wallet = model.wallet
        Group {
            switch wallet.phase {
            case .idle, .loading:
                ProgressView("Opening wallet…")
            case .needsSetup:
                WalletSetupView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Wallet unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await wallet.startIfNeeded() } }
                }
            case .ready:
                WalletHomeView()
            }
        }
        .navigationTitle("Wallet")
        .task { await wallet.startIfNeeded() }
    }
}

// MARK: - Home

private struct WalletHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showPhrase = false

    var body: some View {
        let wallet = model.wallet
        let snap = wallet.snapshot
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Balance").font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(LBCAmount.format(snap?.confirmedBalance ?? 0, maxFractionDigits: 4))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("LBC").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let pending = snap?.pendingBalance, pending > 0 {
                        Label("\(LBCAmount.format(pending)) LBC arriving", systemImage: "clock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let supported = snap?.supportedBalance, supported > 0 {
                        Label("\(LBCAmount.format(supported)) LBC in supports and tips received", systemImage: "hand.thumbsup")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)

                HStack(spacing: 12) {
                    Button { showReceive = true } label: {
                        Label("Receive", systemImage: "arrow.down").frame(maxWidth: .infinity)
                    }
                    Button { showSend = true } label: {
                        Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity)
                    }
                    .disabled((snap?.confirmedBalance ?? 0) + (snap?.pendingBalance ?? 0) == 0)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.carrelAccent)
                .foregroundStyle(.black)
                .controlSize(.large)
            }

            if let error = wallet.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }

            Section("Activity") {
                if let activity = snap?.activity, !activity.isEmpty {
                    ForEach(activity) { item in ActivityRow(item: item) }
                } else {
                    Text(wallet.isRefreshing ? "Checking the blockchain…" : "No transactions yet. Tap Receive to get your address.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let height = wallet.verifiedHeight {
                    Label("Headers verified on this phone to block \(height)", systemImage: "checkmark.shield")
                }
                if let hub = wallet.hubName {
                    Label("Connected to \(hub)", systemImage: "antenna.radiowaves.left.and.right")
                }
            } footer: {
                Text("Your keys stay on this phone and in your iCloud Keychain. Recent transactions are checked against block headers Carrel verifies itself.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .refreshable { await wallet.refresh() }
        .toolbar {
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await wallet.refresh() } }
                Button("Show recovery phrase", systemImage: "key") { showPhrase = true }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Wallet options")
            }
        }
        .sheet(isPresented: $showReceive) {
            NavigationStack { ReceiveView(address: snap?.receiveAddress ?? "") }
        }
        .sheet(isPresented: $showSend) {
            NavigationStack { SendView() }
        }
        .sheet(isPresented: $showPhrase) {
            NavigationStack { RecoveryPhraseView() }
        }
    }
}

private struct ActivityRow: View {
    let item: WalletSnapshot.Activity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.supported > 0 ? "hand.thumbsup" : item.net >= 0 ? "arrow.down.left" : "arrow.up.right")
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Text(item.isConfirmed ? "Block \(item.height)" : "Pending")
                    if item.verified {
                        Image(systemName: "checkmark.shield.fill").accessibilityLabel("Verified on this phone")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text((item.net >= 0 ? "+" : "−") + LBCAmount.format(UInt64(abs(item.net)), maxFractionDigits: 4))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(item.net >= 0 ? Color.green : Color.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if item.supported > 0 { return "Tip or support" }
        return item.net >= 0 ? "Received" : "Sent"
    }
}

// MARK: - Receive

struct ReceiveView: View {
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
                    .accessibilityLabel("QR code for your LBC address")
            }
            Text(address)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal)
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
            Text("Send only LBC (LBRY Credits) to this address. A new address appears after each payment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 32)
        .navigationTitle("Receive LBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
}

enum QRCode {
    static func image(for text: String) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

// MARK: - Send

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var amountText = ""
    @State private var prepared: Wallet.Prepared?
    @State private var isWorking = false
    @State private var error: String?
    @State private var sentTxid: String?

    var body: some View {
        Form {
            if let sentTxid {
                Section {
                    Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sentTxid).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else {
                Section("To") {
                    TextField("LBC address (starts with b)", text: $address, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) { prepared = nil }
                    if !address.isEmpty, !LBCAddress.isValid(address) {
                        Text("That isn't a valid LBC address.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Amount") {
                    HStack {
                        TextField("0.0", text: $amountText).keyboardType(.decimalPad)
                            .onChange(of: amountText) { prepared = nil }
                        Text("LBC").foregroundStyle(.secondary)
                    }
                    if let balance = model.wallet.snapshot?.confirmedBalance {
                        Text("Available: \(LBCAmount.format(balance)) LBC").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let prepared {
                    Section("Review") {
                        LabeledContent("Amount", value: "\(LBCAmount.format(prepared.amount)) LBC")
                        LabeledContent("Network fee", value: "\(LBCAmount.format(prepared.fee)) LBC")
                        LabeledContent("Total", value: "\(LBCAmount.format(prepared.amount + prepared.fee)) LBC")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.orange) }
                }
                Section {
                    Button(prepared == nil ? "Review" : "Send now") { Task { await primaryAction() } }
                        .disabled(isWorking || !LBCAddress.isValid(address) || LBCAmount.parse(amountText) == nil)
                }
            }
        }
        .navigationTitle("Send LBC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(sentTxid == nil ? "Cancel" : "Done") { dismiss() } }
    }

    private func primaryAction() async {
        guard let amount = LBCAmount.parse(amountText) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepared {
                sentTxid = try await model.wallet.broadcast(prepared)
            } else {
                prepared = try await model.wallet.prepareSend(to: address, amount: amount)
            }
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}

// MARK: - Setup

struct WalletSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false
    @State private var phrase = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var newPhrase: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(Color.carrelAccent)
                    Text("Your own LBC wallet").font(.title2.weight(.semibold))
                    Text("Tip creators and support videos with LBC. Keys are made on this phone and backed up to your iCloud Keychain, end-to-end encrypted. Nobody else holds them.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            if restoring {
                Section {
                    TextField("Twelve or more words", text: $phrase, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    let unknown = Mnemonic.unknownWords(in: phrase)
                    if !unknown.isEmpty {
                        Text("Not recognised: \(unknown.joined(separator: ", "))").font(.footnote).foregroundStyle(.orange)
                    } else if !phrase.isEmpty, !Mnemonic.isValidBIP39(phrase) {
                        Text("This isn't a standard phrase. Older LBRY phrases can still work, so check the balance after restoring.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recovery phrase")
                } footer: {
                    Text("Phrases from LBRY Desktop and Odysee work here.")
                }
                Section {
                    Button("Restore wallet") { Task { await run { try await model.wallet.restore(phrase: phrase) } } }
                        .disabled(isWorking || phrase.split(separator: " ").count < 12)
                    Button("Back", role: .cancel) { restoring = false }
                }
            } else {
                Section {
                    Button("Create a new wallet") {
                        Task { await run { newPhrase = try await model.wallet.create() } }
                    }
                    .disabled(isWorking)
                    Button("I already have a recovery phrase") { restoring = true }
                }
            }

            if isWorking { Section { ProgressView() } }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            error = nil
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}

// MARK: - Recovery phrase

struct RecoveryPhraseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var revealed: [String]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Anyone with these words can spend your LBC. Write them down and keep them offline; never paste them into a website.")
                .foregroundStyle(.secondary)
            if let words = revealed {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            Text(word).font(.body.monospaced())
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .privacySensitive()
            } else {
                Button("Show recovery phrase") { reveal() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.carrelAccent)
                    .foregroundStyle(.black)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            Spacer()
        }
        .padding()
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }

    private func reveal() {
        do {
            revealed = try model.wallet.recoveryPhrase()?.split(separator: " ").map(String.init)
            if revealed == nil { error = "No phrase is stored on this device." }
        } catch {
            self.error = WalletModel.describe(error)
        }
    }
}
