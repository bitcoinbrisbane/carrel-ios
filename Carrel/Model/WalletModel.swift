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
        let hub = try await connectHub()
        self.hub = hub
        wallet = Wallet(account: account, backend: hub)
        phase = .ready
        await refresh()
    }

    // MARK: Refresh

    func refresh() async {
        guard let wallet, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let headers = try await syncHeaders()
            snapshot = try await wallet.scan(headers: headers)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
            // A dropped hub connection: try another next time.
            if error is HubError { hub = nil; self.wallet = nil; phase = .idle; await startIfNeeded() }
        }
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
        default:
            return error.localizedDescription
        }
    }
}
