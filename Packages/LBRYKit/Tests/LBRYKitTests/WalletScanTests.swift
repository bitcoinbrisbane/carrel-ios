import XCTest
@testable import LBRYKit

/// Scanning and spending against an in-memory hub.
final class WalletScanTests: XCTestCase {

    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    /// A pretend hub holding a handful of transactions.
    final class FakeHub: WalletBackend, @unchecked Sendable {
        var txs: [String: FetchedTransaction] = [:]
        var historyByAddress: [String: [(txid: String, height: Int)]] = [:]
        var broadcasted: [String] = []

        func add(_ tx: Transaction, height: Int, branch: [String]? = nil, position: Int? = nil) {
            txs[tx.txid] = FetchedTransaction(hex: tx.hex, height: height, merkleBranch: branch, merklePosition: position)
            let addresses = tx.outputs.compactMap { LBCAddress.address(for: $0.script) }
            for a in Set(addresses) { historyByAddress[a, default: []].append((tx.txid, height)) }
        }
        func addSpend(_ tx: Transaction, height: Int, from address: String) {
            add(tx, height: height)
            historyByAddress[address, default: []].append((tx.txid, height))
        }

        func history(of address: String) async throws -> [(txid: String, height: Int)] { historyByAddress[address] ?? [] }
        func transactions(_ txids: [String]) async throws -> [String: FetchedTransaction] {
            txids.reduce(into: [:]) { $0[$1] = txs[$1] }
        }
        func broadcast(_ rawHex: String) async throws -> String {
            broadcasted.append(rawHex)
            return try Transaction(hex: rawHex).txid
        }
    }

    /// A transaction from someone else paying `value` to `address`.
    private func payment(to address: String, value: UInt64, nonce: UInt32) throws -> Transaction {
        var tx = Transaction()
        tx.inputs = [.init(txid: String(repeating: "ab", count: 32), vout: nonce, scriptSig: [0x00])]
        tx.outputs = [.init(value: value, script: try LBCAddress.script(for: address))]
        return tx
    }

    func testScanFindsCoinsAcrossTheGapAndBuildsATip() async throws {
        let account = try WalletAccount(phrase: phrase)
        let hub = FakeHub()
        let a0 = try account.address(.receive, 0).address
        let a5 = try account.address(.receive, 5).address     // used after a gap of unused ones
        hub.add(try payment(to: a0, value: 300_000_000, nonce: 0), height: 100)
        hub.add(try payment(to: a5, value: 50_000_000, nonce: 1), height: 0)  // still in the mempool

        let wallet = Wallet(account: account, backend: hub)
        let snap = try await wallet.scan()
        XCTAssertEqual(snap.confirmedBalance, 300_000_000)
        XCTAssertEqual(snap.pendingBalance, 50_000_000)
        XCTAssertEqual(snap.usedAddressCount, 2)
        XCTAssertEqual(snap.receiveAddress, try account.address(.receive, 6).address)
        XCTAssertEqual(snap.activity.count, 2)
        XCTAssertEqual(snap.activity.first?.height, 0, "unconfirmed first")

        // Tip 1 LBC to a creator.
        let creator = try WalletAccount(phrase: "legal winner thank year wave sausage worth useful legal winner thank yellow")
            .address(.receive, 0).address   // someone else's wallet
        let prepared = try await wallet.prepareTip(claimName: "hello", claimID: "a1b2c3d4e5f60718293a4b5c6d7e8f9001122334",
                                                   ownerAddress: creator, amount: 100_000_000)
        XCTAssertEqual(prepared.amount, 100_000_000)
        XCTAssertEqual(prepared.transaction.inputs.count, 1)
        XCTAssertTrue(Script.isClaimOrSupport(prepared.transaction.outputs[0].script))
        XCTAssertEqual(LBCAddress.address(for: prepared.transaction.outputs[0].script), creator)
        let change = try account.address(.change, 0).address
        XCTAssertEqual(LBCAddress.address(for: prepared.transaction.outputs[1].script), change)
        XCTAssertEqual(prepared.transaction.outputs[1].value, 300_000_000 - 100_000_000 - prepared.fee,
                       "confirmed coin preferred over the pending one")

        let txid = try await wallet.broadcast(prepared)
        XCTAssertEqual(txid, prepared.transaction.txid)
        XCTAssertEqual(hub.broadcasted.count, 1)

        // After it confirms, a rescan shows the spend and the change.
        hub.addSpend(prepared.transaction, height: 101, from: a0)
        let after = try await wallet.scan()
        XCTAssertEqual(after.confirmedBalance, 300_000_000 - 100_000_000 - prepared.fee)
        XCTAssertEqual(after.pendingBalance, 50_000_000)
        let tipActivity = try XCTUnwrap(after.activity.first { $0.txid == txid })
        XCTAssertEqual(tipActivity.net, -Int64(100_000_000 + prepared.fee))
        XCTAssertEqual(tipActivity.supported, 100_000_000)
    }

    func testWatchOnlyCannotSpend() async throws {
        let account = try WalletAccount(phrase: phrase)
        let watch = try WalletAccount(extendedKey: account.extendedPublicKey)
        let hub = FakeHub()
        hub.add(try payment(to: try account.address(.receive, 0).address, value: 10_000_000, nonce: 0), height: 5)
        let wallet = Wallet(account: watch, backend: hub)
        let snap = try await wallet.scan()
        XCTAssertEqual(snap.confirmedBalance, 10_000_000)
        do {
            _ = try await wallet.prepareSend(to: try account.address(.receive, 1).address, amount: 1_000_000)
            XCTFail("watch-only wallet signed something")
        } catch {
            XCTAssertEqual(error as? WalletError, .watchOnly)
        }
    }

    func testMerkleProofIsCheckedInsideTheHeaderWindow() async throws {
        // Real mainnet block 2 has a single (coinbase) transaction, so its merkle root is its txid
        // and the proof is an empty branch at position 0.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "headers_0_19", withExtension: "hex", subdirectory: "Fixtures"))
        let hex = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var chain = try HeaderChain(checkpoint: .genesis)
        try chain.connect(raw: XCTUnwrap([UInt8](hex: hex)).suffix(18 * 112).map { $0 }, startingAt: 2)
        let root = try XCTUnwrap(chain.header(at: 2)).merkleRoot
        let txid = root.reversed().hex

        XCTAssertTrue(MerkleProof.verify(txid: txid, branch: [], position: 0, merkleRoot: root))
        XCTAssertFalse(MerkleProof.verify(txid: txid, branch: [], position: 1, merkleRoot: root))
        XCTAssertFalse(MerkleProof.verify(txid: String(repeating: "0", count: 64), branch: [], position: 0, merkleRoot: root))
    }

    func testMerkleBranchOfFourLeaves() {
        let leaves = (0..<4).map { LBRYHash.sha256d([UInt8($0)]) }        // internal order
        let l01 = LBRYHash.sha256d(leaves[0] + leaves[1])
        let l23 = LBRYHash.sha256d(leaves[2] + leaves[3])
        let root = LBRYHash.sha256d(l01 + l23)
        let display = { (b: [UInt8]) in b.reversed().hex }
        XCTAssertTrue(MerkleProof.verify(txid: display(leaves[2]), branch: [display(leaves[3]), display(l01)], position: 2, merkleRoot: root))
        XCTAssertFalse(MerkleProof.verify(txid: display(leaves[2]), branch: [display(leaves[3]), display(l01)], position: 3, merkleRoot: root))
    }

    func testParsesWhatItSerialises() throws {
        var tx = Transaction()
        tx.inputs = [.init(txid: String(repeating: "cd", count: 32), vout: 3, scriptSig: [1, 2, 3], sequence: 7)]
        tx.outputs = [.init(value: 12_345, script: [0x6a, 0x01, 0x00])]
        tx.locktime = 99
        XCTAssertEqual(try Transaction(hex: tx.hex), tx)
        XCTAssertThrowsError(try Transaction(hex: tx.hex + "00"))
    }
}
