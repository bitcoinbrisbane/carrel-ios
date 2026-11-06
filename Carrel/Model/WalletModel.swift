import Foundation
import LBRYKit

/// The app's view of the wallet: setup, hub connection, header sync, scans,
/// tips and sends. All LBC logic lives in LBRYKit; this only coordinates it.
@Observable
@MainActor
final class WalletModel {

    enum Phase {
        case idle
        case loading
        case needsSetup
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: WalletSnapshot?
    private(set) var isRefreshing = false
    private(set) var hubName: String?
    private(set) var verifiedHeight: Int?
    var lastError: String?
    /// Called once a wallet is open (created, restored or loaded).
    var onReady: (() -> Void)?

    // Ethereum, from the same phrase (standard path, so MetaMask shows the same address).
    private(set) var ethereum: EthereumAccount?
    private(set) var ethBalances: EthereumBalances?
    private(set) var bridgeDeposits: [LBCBridge.Deposit] = []
    let ethRPC = EthereumRPC()
    let bridge = LBCBridge()
    /// Ethereum transactions sent from Carrel, newest first.
    private(set) var ethActivity: [EthereumActivity] = EthereumActivityStore.load() {
        didSet { EthereumActivityStore.save(ethActivity) }
    }
    private var following: Set<String> = []

    private var wallet: Wallet?
    private var hub: HubClient?
    private var chain: HeaderChain?
    private let vault = SeedVault()

    var isReady: Bool { if case .ready = phase { return true } else { return false } }

    // MARK: Lifecycle

    /// Opens the stored wallet, or asks for setup. Safe to call repeatedly.
    func startIfNeeded() async {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .loading
        do {
            if let phrase = try vault.load() {
                try await open(phrase: phrase)
            } else {
                phase = .needsSetup
            }
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// New wallet. Returns the phrase so the UI can offer an offline copy.
    func create() async throws -> String {
        let phrase = Mnemonic.generate()
        try vault.save(phrase: phrase)
        try await open(phrase: phrase)
        return phrase
    }

    /// Restore from a phrase (LBRY Desktop / Odysee phrases work).
    func restore(phrase: String) async throws {
        let cleaned = Mnemonic.clean(phrase)
        _ = try WalletAccount(phrase: cleaned)      // fails fast on nonsense
        try vault.save(phrase: cleaned)
        try await open(phrase: cleaned)
    }

    func recoveryPhrase() throws -> String? {
        try vault.load()
    }

    private func open(phrase: String) async throws {
        let account = try WalletAccount(phrase: phrase)
        ethereum = try EthereumAccount(phrase: phrase)
        let hub = try await connectHub()
        self.hub = hub
        wallet = Wallet(account: account, backend: hub)
        phase = .ready
        onReady?()
        await refresh()
    }

    // MARK: Refresh

    func refresh() async {
        guard let wallet, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let eth: Void = refreshEthereum()
        do {
            let headers = try await syncHeaders()
            snapshot = try await wallet.scan(headers: headers)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
            // A dropped hub connection: try another next time.
            if error is HubError { hub = nil; self.wallet = nil; phase = .idle; await startIfNeeded() }
        }
        await eth
    }

    /// ETH, USDC, USDT and wLBC balances, plus any lbc.exchange deposits in flight.
    func refreshEthereum() async {
        guard let address = ethereum?.address else { return }
        resumeEthereumActivity()
        ethBalances = await EthereumBalances.fetch(for: address, rpc: ethRPC)
        if let deposits = try? await bridge.deposits(for: address) { bridgeDeposits = deposits }
    }

    // MARK: Ethereum transactions

    /// Nonce, gas, fees and an ETH balance check for a call from this wallet.
    func prepareEthereum(_ call: EthereumCall) async throws -> PreparedEthereumTx {
        guard let address = ethereum?.address else { throw WalletError.watchOnly }
        return try await ethRPC.prepare(call, from: address)
    }

    /// Signs and broadcasts, then follows it in the background (and, for an unwrap,
    /// asks the bridge for the LBC once Ethereum has 12 confirmations).
    @discardableResult
    func submitEthereum(_ prepared: PreparedEthereumTx, kind: EthereumActivity.Kind, title: String) async throws -> String {
        guard let ethereum else { throw WalletError.watchOnly }
        let signed = try ethereum.sign(prepared.transaction)
        let hash = try await ethRPC.sendRawTransaction(signed.raw)
        ethActivity.insert(EthereumActivity(hash: hash, kind: kind, title: title, date: Date(), state: .submitted), at: 0)
        Task { await follow(hash) }
        return hash
    }

    enum MintReadiness {
        case ready(EthereumCall, dewies: UInt64)
        case waiting(confirmations: Int, required: Int)
        case alreadyMinted
    }

    /// Asks lbc.exchange to approve a mint for this deposit and checks the approval
    /// (it mints to us, signed by `Bridge.signer()` read from Ethereum) before any gas is spent.
    func mintCall(for deposit: LBCBridge.Deposit) async throws -> MintReadiness {
        guard let address = ethereum?.address else { throw WalletError.watchOnly }
        let bridge = self.bridge, rpc = ethRPC
        async let approval = bridge.mintApproval(ethAddress: address, lbcTxid: deposit.lbcTxid)
        async let signer = rpc.readAddress(contract: bridge.bridgeAddress, function: "signer()")
        switch try await approval {
        case .alreadyMinted:
            return .alreadyMinted
        case .waiting(let confirmations, let required):
            return .waiting(confirmations: confirmations, required: required)
        case .approved(let args):
            try bridge.verify(args, ethAddress: address, onChainSigner: try await signer)
            return .ready(try EthereumCall.bridgeWrap(args, bridge: bridge.bridgeAddress), dewies: args.dewies)
        }
    }

    /// Picks up anything still open from an earlier launch.
    func resumeEthereumActivity() {
        for item in ethActivity where item.isOpen && !following.contains(item.hash) {
            Task { await follow(item.hash) }
        }
    }

    private func follow(_ hash: String) async {
        guard !following.contains(hash) else { return }
        following.insert(hash)
        defer { following.remove(hash) }

        if activity(hash)?.state == .submitted {
            guard let receipt = try? await ethRPC.waitForReceipt(hash) else { return }   // still pending: resume later
            let isUnwrap = activity(hash)?.kind == .unwrap
            update(hash) {
                $0.state = receipt.succeeded ? (isUnwrap ? .awaitingPayout : .confirmed) : .failed
                if !receipt.succeeded { $0.detail = "Reverted on Ethereum" }
            }
            await refreshBalancesAfterSend()
        }

        guard activity(hash)?.state == .awaitingPayout else { return }
        // POST unwrap is safe to repeat: the bridge never pays the same burn twice.
        for _ in 0..<90 {
            if let status = try? await bridge.requestPayout(burnTxid: hash) {
                switch status.state {
                case .paid:
                    let payout = status.payoutTxids.first.map { txid in "LBC sent · \(txid.prefix(10))…" }
                    update(hash) { $0.state = .paid; $0.detail = payout }
                    await refresh()
                    return
                case .failed, .reverted, .noEvent:
                    update(hash) { $0.state = .failed; $0.detail = status.error ?? "The bridge couldn't pay this unwrap" }
                    return
                default:
                    update(hash) { $0.detail = "\(min(status.confirmations, status.required)) of \(status.required) Ethereum confirmations" }
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    private func refreshBalancesAfterSend() async {
        guard let address = ethereum?.address else { return }
        ethBalances = await EthereumBalances.fetch(for: address, rpc: ethRPC)
        if let deposits = try? await bridge.deposits(for: address) { bridgeDeposits = deposits }
    }

    private func activity(_ hash: String) -> EthereumActivity? {
        ethActivity.first { $0.hash == hash }
    }

    private func update(_ hash: String, _ change: (inout EthereumActivity) -> Void) {
        guard let i = ethActivity.firstIndex(where: { $0.hash == hash }) else { return }
        change(&ethActivity[i])
    }

    // MARK: lbc.exchange

    /// This wallet's lbc.exchange deposit address, only after checking the bridge's
    /// signature against `Bridge.signer()` read from Ethereum.
    func verifiedDepositOffer() async throws -> LBCBridge.DepositOffer {
        guard let address = ethereum?.address else { throw WalletError.watchOnly }
        let bridge = self.bridge, rpc = ethRPC
        async let offer = bridge.depositOffer(for: address)
        async let signer = rpc.readAddress(contract: bridge.bridgeAddress, function: "signer()")
        let (o, s) = try await (offer, signer)
        try bridge.verify(o, onChainSigner: s)
        return o
    }

    /// CarrelChain: validate headers from our checkpoint (or the saved window) to the hub's tip.
    private func syncHeaders() async throws -> HeaderChain? {
        guard let hub else { return nil }
        var current: HeaderChain
        if let saved = chain ?? ChainStore.load() {
            current = saved
        } else {
            current = try HeaderChain(checkpoint: .latest)
        }
        do {
            let sync = ChainSync(chain: current, source: hub)
            try await sync.sync()
            current = await sync.chain
        } catch ChainSync.SyncError.forkBeyondWindow {
            // Our saved window is on a dead branch: start again from the shipped checkpoint.
            let fresh = ChainSync(chain: try HeaderChain(checkpoint: .latest), source: hub)
            try await fresh.sync()
            current = await fresh.chain
        }
        chain = current
        verifiedHeight = current.height
        ChainStore.save(current)
        return current
    }

    private func connectHub() async throws -> HubClient {
        var lastError: Error = HubError.notConnected
        for server in HubServer.defaults {
            let client = HubClient(server: server)
            do {
                try await client.connect()
                hubName = server.host
                return client
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Spending

    func prepareTip(for claim: Claim, amount: UInt64) async throws -> Wallet.Prepared {
        guard let wallet else { throw WalletError.watchOnly }
        guard let owner = claim.address else { throw TipError.noOwnerAddress }
        return try await wallet.prepareTip(claimName: claim.name, claimID: claim.claimId, ownerAddress: owner, amount: amount)
    }

    func prepareSend(to address: String, amount: UInt64) async throws -> Wallet.Prepared {
        guard let wallet else { throw WalletError.watchOnly }
        return try await wallet.prepareSend(to: address, amount: amount)
    }

    /// Broadcasts, then rescans so the balance moves straight away.
    func broadcast(_ prepared: Wallet.Prepared) async throws -> String {
        guard let wallet else { throw WalletError.watchOnly }
        let txid = try await wallet.broadcast(prepared)
        await refresh()
        return txid
    }

    enum TipError: LocalizedError {
        case noOwnerAddress
        var errorDescription: String? { "This video doesn't list an address to tip." }
    }

    // MARK: Messages

    static func describe(_ error: Error) -> String {
        switch error {
        case TxBuilderError.insufficientFunds(let needed, let available):
            return "Not enough LBC: this needs \(LBCAmount.format(needed)) including the fee, and the wallet has \(LBCAmount.format(available))."
        case TxBuilderError.tooManyInputs:
            return "Too many small coins for one transaction. Try a smaller amount."
        case ScriptError.badAddress:
            return "That isn't an LBC address."
        case WalletError.merkleProofFailed:
            return "The hub's answer didn't match the blockchain. Carrel stopped to keep you safe; it will try another hub."
        case is HubError:
            return "Couldn't reach an LBRY hub. Check your connection and try again."
        case EthereumRPCError.rpc(let message):
            return message.localizedCaseInsensitiveContains("revert")
                ? "Ethereum says this would fail (\(message)). Nothing was sent."
                : "Ethereum node: \(message)"
        case is EthereumRPCError:
            return "Couldn't reach Ethereum. Check your connection and try again."
        default:
            return error.localizedDescription
        }
    }
}
