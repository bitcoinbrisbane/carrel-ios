import XCTest
@testable import LBRYKit

/// Every expected value here was produced by lbc.exchange's TypeScript wallet
/// (Fixtures/wallet_vectors.json), which already moves LBC on mainnet, so the
/// Swift port must match it byte for byte.
final class WalletTests: XCTestCase {

    struct Vectors: Decodable {
        struct MnemonicVector: Decodable { let entropy: String; let phrase: String }
        struct Account: Decodable { let xprv: String; let xpub: String; let chainCode: String; let privateKey: String }
        struct AddressVector: Decodable { let chain: UInt32; let index: UInt32; let privateKey: String; let wif: String; let publicKey: String; let address: String }
        struct Node: Decodable { let privateKey: String; let chainCode: String?; let publicKey: String }
        struct BIP32: Decodable {
            let seed: String
            let master: Node
            let child: Node
            let deep: Node
            enum CodingKeys: String, CodingKey {
                case seed, master
                case child = "m/0'/1"
                case deep = "m/0'/1/2'/2/1000000000"
            }
        }
        struct Funding: Decodable { let txid: String; let vout: UInt32; let value: String; let script: String }
        struct Tip: Decodable {
            let funding: Funding
            let claimId: String; let claimName: String; let amount: String
            let supportScript: String; let changeScript: String
            let fee: String; let change: String; let size: Int
            let sighash0: String; let hex: String; let txid: String
        }
        struct Spend: Decodable { let fee: String; let change: String; let hex: String; let txid: String }

        let feePerByte: UInt64
        let mnemonics: [MnemonicVector]
        let phrase: String
        let lbrySeed: String
        let bip39Seed: String
        let account: Account
        let receive: [AddressVector]
        let change: [AddressVector]
        let bip32: BIP32
        let tip: Tip
        let spendSupport: Spend
    }

    private var v: Vectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wallet_vectors", withExtension: "json", subdirectory: "Fixtures"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    // MARK: Phrases and seeds

    func testEntropyToPhrase() throws {
        for m in v.mnemonics {
            XCTAssertEqual(try Mnemonic.phrase(entropy: XCTUnwrap([UInt8](hex: m.entropy))), m.phrase)
            XCTAssertTrue(Mnemonic.isValidBIP39(m.phrase))
        }
    }

    func testChecksumAndTypos() {
        XCTAssertFalse(Mnemonic.isValidBIP39(String(repeating: "abandon ", count: 12)))
        XCTAssertTrue(Mnemonic.isValidBIP39("  Abandon abandon abandon abandon abandon abandon\nabandon abandon abandon abandon abandon ABOUT "))
        XCTAssertEqual(Mnemonic.unknownWords(in: "abandon abandn about"), ["abandn"])
        XCTAssertEqual(Mnemonic.suggestions(for: "zo"), ["zone", "zoo"])
        XCTAssertEqual(Mnemonic.generate().split(separator: " ").count, 12)
        XCTAssertTrue(Mnemonic.isValidBIP39(Mnemonic.generate(words: 24)))
    }

    func testSeeds() {
        XCTAssertEqual(Mnemonic.lbrySeed(v.phrase).hex, v.lbrySeed)
        XCTAssertEqual(Mnemonic.bip39Seed(v.phrase).hex, v.bip39Seed)
    }

    // MARK: Keys and addresses

    func testBIP32Vector1() throws {
        let master = try HDKey.master(seed: XCTUnwrap([UInt8](hex: v.bip32.seed)))
        XCTAssertEqual(master.privateKey?.hex, v.bip32.master.privateKey)
        XCTAssertEqual(master.chainCode.hex, v.bip32.master.chainCode)
        XCTAssertEqual(master.publicKey.hex, v.bip32.master.publicKey)

        let child = try master.derive(path: "m/0'/1")
        XCTAssertEqual(child.privateKey?.hex, v.bip32.child.privateKey)
        XCTAssertEqual(child.chainCode.hex, v.bip32.child.chainCode)

        let deep = try master.derive(path: "m/0'/1/2'/2/1000000000")
        XCTAssertEqual(deep.privateKey?.hex, v.bip32.deep.privateKey)
        XCTAssertEqual(deep.publicKey.hex, v.bip32.deep.publicKey)
    }

    func testPublicDerivationCannotDoHardened() throws {
        let master = try HDKey.master(seed: XCTUnwrap([UInt8](hex: v.bip32.seed)))
        XCTAssertThrowsError(try master.neutered.derive(HDKey.hardened)) { error in
            XCTAssertEqual(error as? HDKey.Error, .hardenedFromPublic)
        }
        XCTAssertEqual(try master.neutered.derive(7).publicKey, try master.derive(7).publicKey)
    }

    func testLBRYAccountMatchesBridge() throws {
        let account = try WalletAccount(phrase: v.phrase)
        XCTAssertEqual(account.extendedPublicKey, v.account.xpub)

        for expected in v.receive + v.change {
            let chain = WalletAccount.Chain(rawValue: expected.chain)!
            let address = try account.address(chain, expected.index)
            XCTAssertEqual(address.address, expected.address, address.path)
            XCTAssertEqual(address.publicKey.hex, expected.publicKey, address.path)
            let key = try account.privateKey(chain, expected.index)
            XCTAssertEqual(key.hex, expected.privateKey, address.path)
            XCTAssertEqual(LBCAddress.wif(privateKey: key), expected.wif, address.path)
            XCTAssertTrue(expected.address.hasPrefix("b"))
        }
    }

    func testExtendedKeysRoundTrip() throws {
        let fromXprv = try HDKey(extendedKey: v.account.xprv)
        XCTAssertEqual(fromXprv.extendedPrivate(), v.account.xprv)
        XCTAssertEqual(fromXprv.extendedPublic(), v.account.xpub)

        let watchOnly = try WalletAccount(extendedKey: v.account.xpub)
        XCTAssertFalse(watchOnly.canSign)
        XCTAssertEqual(try watchOnly.address(.receive, 0).address, v.receive[0].address)
        XCTAssertThrowsError(try watchOnly.privateKey(.receive, 0))
    }

    func testAddressScripts() throws {
        let address = v.receive[0].address
        XCTAssertTrue(LBCAddress.isValid(address))
        XCTAssertEqual(try LBCAddress.script(for: address).hex, v.tip.funding.script)
        XCTAssertEqual(LBCAddress.address(for: try XCTUnwrap([UInt8](hex: v.tip.funding.script))), address)
        XCTAssertFalse(LBCAddress.isValid("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"), "Bitcoin addresses are not LBC")
        XCTAssertFalse(LBCAddress.isValid(String(address.dropLast()) + "x"), "bad checksum")
    }

    func testAmounts() {
        XCTAssertEqual(LBCAmount.parse("1.5"), 150_000_000)
        XCTAssertEqual(LBCAmount.parse(".00000001"), 1)
        XCTAssertNil(LBCAmount.parse("0.000000001"))
        XCTAssertNil(LBCAmount.parse("abc"))
        XCTAssertEqual(LBCAmount.format(150_000_000), "1.5")
        XCTAssertEqual(LBCAmount.format(1), "0.00000001")
        XCTAssertEqual(LBCAmount.format(1_000_000_000), "10")
    }

    // MARK: Transactions

    private func fundingUTXO() throws -> UTXO {
        UTXO(txid: v.tip.funding.txid, vout: v.tip.funding.vout, value: UInt64(v.tip.funding.value)!,
             script: try XCTUnwrap([UInt8](hex: v.tip.funding.script)), address: v.receive[0].address, height: 2_223_000)
    }

    func testTipTransactionMatchesBridgeByteForByte() throws {
        let account = try WalletAccount(phrase: v.phrase)
        let coin = try fundingUTXO()

        let support = try Script.support(name: v.tip.claimName, claimID: v.tip.claimId,
                                         payee: LBCAddress.script(for: v.receive[2].address))
        XCTAssertEqual(support.hex, v.tip.supportScript)
        XCTAssertEqual(Script.stripClaimPrefix(support).hex, try LBCAddress.script(for: v.receive[2].address).hex)

        let changeScript = try LBCAddress.script(for: v.change[0].address)
        XCTAssertEqual(changeScript.hex, v.tip.changeScript)

        let tip = TxBuilder.Recipient(script: support, value: UInt64(v.tip.amount)!)
        let selection = try TxBuilder.selectCoins([coin], recipients: [tip], changeScript: changeScript, feePerByte: v.feePerByte)
        XCTAssertEqual(selection.fee, UInt64(v.tip.fee)!)
        XCTAssertEqual(selection.change, UInt64(v.tip.change)!)
        XCTAssertEqual(selection.size, v.tip.size)

        let unsigned = TxBuilder.assemble(inputs: selection.inputs, recipients: [tip],
                                          change: .init(script: changeScript, value: selection.change))
        XCTAssertEqual(unsigned.legacySighash(inputIndex: 0, scriptCode: coin.script).hex, v.tip.sighash0)

        let signed = try TxBuilder.sign(unsigned, spending: selection.inputs) { _ in try account.privateKey(.receive, 0) }
        XCTAssertEqual(signed.hex, v.tip.hex, "RFC 6979 + low-S makes signatures deterministic")
        XCTAssertEqual(signed.txid, v.tip.txid)
    }

    func testSpendingASupportOutput() throws {
        let account = try WalletAccount(phrase: v.phrase)
        let support = try XCTUnwrap([UInt8](hex: v.tip.supportScript))
        let coin = UTXO(txid: v.tip.txid, vout: 0, value: UInt64(v.tip.amount)!, script: support,
                        address: v.receive[2].address, height: 0)
        let to = TxBuilder.Recipient(script: try LBCAddress.script(for: v.receive[1].address), value: 50_000_000)
        let changeScript = try LBCAddress.script(for: v.change[0].address)
        let selection = try TxBuilder.selectCoins([coin], recipients: [to], changeScript: changeScript, feePerByte: v.feePerByte)
        XCTAssertEqual(selection.fee, UInt64(v.spendSupport.fee)!)
        let unsigned = TxBuilder.assemble(inputs: selection.inputs, recipients: [to],
                                          change: .init(script: changeScript, value: selection.change))
        let signed = try TxBuilder.sign(unsigned, spending: selection.inputs) { _ in try account.privateKey(.receive, 2) }
        XCTAssertEqual(signed.hex, v.spendSupport.hex)
        XCTAssertEqual(signed.txid, v.spendSupport.txid)
    }

    func testWrongKeyIsRefused() throws {
        let account = try WalletAccount(phrase: v.phrase)
        let coin = try fundingUTXO()
        let to = TxBuilder.Recipient(script: try LBCAddress.script(for: v.receive[1].address), value: 10_000_000)
        let unsigned = TxBuilder.assemble(inputs: [coin], recipients: [to], change: nil)
        XCTAssertThrowsError(try TxBuilder.sign(unsigned, spending: [coin]) { _ in try account.privateKey(.receive, 1) }) { error in
            XCTAssertEqual(error as? TxBuilderError, .keyMismatch(input: 0))
        }
    }

    func testInsufficientFunds() throws {
        let coin = try fundingUTXO()
        let tooMuch = TxBuilder.Recipient(script: coin.script, value: coin.value)
        XCTAssertThrowsError(try TxBuilder.selectCoins([coin], recipients: [tooMuch], changeScript: coin.script)) { error in
            guard case .insufficientFunds? = error as? TxBuilderError else { return XCTFail("\(error)") }
        }
    }

    func testSignatureVerifyRejectsTampering() throws {
        let key = try XCTUnwrap([UInt8](hex: v.receive[0].privateKey))
        let digest = LBRYHash.sha256d(Array("carrel".utf8))
        let sig = try Secp256k1.sign(digest: digest, privateKey: key)
        let pub = try Secp256k1.publicKey(privateKey: key)
        XCTAssertTrue(Secp256k1.verify(signature: sig, digest: digest, publicKey: pub))
        var other = digest
        other[0] ^= 1
        XCTAssertFalse(Secp256k1.verify(signature: sig, digest: other, publicKey: pub))
    }
}
