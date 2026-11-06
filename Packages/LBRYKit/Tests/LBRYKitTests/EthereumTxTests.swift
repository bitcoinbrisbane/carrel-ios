import XCTest
@testable import LBRYKit

/// Expected bytes come from eth-account / eth-abi / pyrlp (Fixtures/eth_tx_vectors.json),
/// signed with the "abandon … about" phrase on the MetaMask path.
final class EthereumTxTests: XCTestCase {

    struct Vectors: Decodable {
        struct RLPCase: Decodable { let value: String; let rlp: String }
        struct Tx: Decodable {
            let nonce: UInt64
            let to: String
            let value: String
            let data: String
            let gas: UInt64
            let maxPriorityFeePerGas: String
            let maxFeePerGas: String
            let signingHash: String
            let raw: String
            let hash: String
        }
        struct WrapCase: Decodable {
            let nonce: UInt64; let to: String; let data: String; let gas: UInt64
            let maxPriorityFeePerGas: String; let maxFeePerGas: String
            let signingHash: String; let raw: String; let hash: String
            let args: LBCBridge.WrapArgs
            let wrapMessageHash: String
            let signer: String
        }
        struct UnwrapArgs: Decodable { let amount: String; let lbcAddress: String }
        struct UnwrapCase: Decodable {
            let nonce: UInt64; let to: String; let data: String; let gas: UInt64
            let maxPriorityFeePerGas: String; let maxFeePerGas: String
            let signingHash: String; let raw: String; let hash: String
            let args: UnwrapArgs
        }
        let from: String
        let rlp: [RLPCase]
        let ethTransfer: Tx
        let erc20Transfer: Tx
        let bridgeWrap: WrapCase
        let bridgeUnwrap: UnwrapCase
    }

    private var v: Vectors!
    private var account: EthereumAccount!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "eth_tx_vectors", withExtension: "json", subdirectory: "Fixtures"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        account = try EthereumAccount(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertEqual(account.address, v.from)
    }

    private func fees(_ tip: String, _ max: String) throws -> EthereumFees {
        EthereumFees(maxPriorityFeePerGas: try XCTUnwrap(UInt256(decimal: tip)), maxFeePerGas: try XCTUnwrap(UInt256(decimal: max)))
    }

    private func assertSigned(_ call: EthereumCall, nonce: UInt64, gas: UInt64, tip: String, max: String,
                              data: String, signingHash: String, raw: String, hash: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual("0x" + call.data.hex, data, "calldata", file: file, line: line)
        let tx = call.transaction(nonce: nonce, fees: try fees(tip, max), gasLimit: gas)
        XCTAssertEqual(try tx.signingHash().hex, signingHash, "signing hash", file: file, line: line)
        let signed = try account.sign(tx)
        XCTAssertEqual("0x" + signed.raw.hex, raw, "raw", file: file, line: line)
        XCTAssertEqual(signed.hash, hash, "hash", file: file, line: line)
    }

    func testRLP() {
        for c in v.rlp {
            let bytes = c.value == "long" ? [UInt8](repeating: 0x78, count: 60) : [UInt8](hex: c.value)!
            XCTAssertEqual(RLP.encode(.bytes(bytes)).hex, c.rlp, c.value)
        }
        XCTAssertEqual(RLP.encode(.list([])).hex, "c0")
        XCTAssertEqual(RLP.encode(.uint(UInt64(0))).hex, "80")
        XCTAssertEqual(RLP.encode(.list([.bytes(Array("cat".utf8)), .bytes(Array("dog".utf8))])).hex, "c88363617483646f67")
    }

    func testSendETH() throws {
        let t = v.ethTransfer
        let call = try EthereumCall.sendETH(to: t.to, wei: try XCTUnwrap(UInt256(decimal: t.value)))
        try assertSigned(call, nonce: t.nonce, gas: t.gas, tip: t.maxPriorityFeePerGas, max: t.maxFeePerGas,
                         data: t.data, signingHash: t.signingHash, raw: t.raw, hash: t.hash)
        XCTAssertEqual(try XCTUnwrap(UInt256(units: "0.01", decimals: 18)), try XCTUnwrap(UInt256(decimal: t.value)))
    }

    func testTokenTransfer() throws {
        let t = v.erc20Transfer
        let amount = try XCTUnwrap(UInt256(units: "1.5", decimals: 6))
        XCTAssertEqual(amount, UInt256(1_500_000))
        let call = try EthereumCall.transfer(.usdc, to: "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0", amount: amount)
        XCTAssertEqual(call.to, t.to)
        try assertSigned(call, nonce: t.nonce, gas: t.gas, tip: t.maxPriorityFeePerGas, max: t.maxFeePerGas,
                         data: t.data, signingHash: t.signingHash, raw: t.raw, hash: t.hash)
    }

    func testBridgeWrap() throws {
        let t = v.bridgeWrap
        let call = try EthereumCall.bridgeWrap(t.args)
        XCTAssertEqual(call.data.count, 260)
        try assertSigned(call, nonce: t.nonce, gas: t.gas, tip: t.maxPriorityFeePerGas, max: t.maxFeePerGas,
                         data: t.data, signingHash: t.signingHash, raw: t.raw, hash: t.hash)

        // The approval check Carrel runs before spending gas.
        let bridge = LBCBridge()
        XCTAssertEqual(try bridge.wrapMessageHash(t.args).hex, t.wrapMessageHash)
        XCTAssertNoThrow(try bridge.verify(t.args, ethAddress: v.from, onChainSigner: t.signer))
        XCTAssertThrowsError(try bridge.verify(t.args, ethAddress: v.from, onChainSigner: v.from), "wrong signer")
        XCTAssertThrowsError(try bridge.verify(t.args, ethAddress: t.to.replacingOccurrences(of: "94", with: "95"), onChainSigner: t.signer),
                             "mints to someone else")
        let tampered = LBCBridge.WrapArgs(to: t.args.to, amount: "999999999", lbcTxid: t.args.lbcTxid, signature: t.args.signature)
        XCTAssertThrowsError(try bridge.verify(tampered, ethAddress: v.from, onChainSigner: t.signer), "amount changed")
    }

    func testBridgeUnwrap() throws {
        let t = v.bridgeUnwrap
        let call = try EthereumCall.bridgeUnwrap(amount: try XCTUnwrap(UInt256(decimal: t.args.amount)), lbcAddress: t.args.lbcAddress)
        XCTAssertEqual(call.data.count, 164)
        try assertSigned(call, nonce: t.nonce, gas: t.gas, tip: t.maxPriorityFeePerGas, max: t.maxFeePerGas,
                         data: t.data, signingHash: t.signingHash, raw: t.raw, hash: t.hash)
        XCTAssertThrowsError(try EthereumCall.bridgeUnwrap(amount: UInt256(1), lbcAddress: "not an address"))
    }

    func testAmounts() throws {
        XCTAssertEqual(UInt256(hex: "0x5208"), UInt256(21_000))
        XCTAssertEqual(UInt256(21_000).hexQuantity, "0x5208")
        XCTAssertEqual(UInt256.zero.hexQuantity, "0x0")
        let wei = try XCTUnwrap(UInt256(decimal: "123456789012345678901234"))   // > UInt64
        XCTAssertEqual(wei.decimalString, "123456789012345678901234")
        XCTAssertEqual(wei.formatted(decimals: 18), "123456.789012345678901234")
        XCTAssertEqual(wei.formatted(decimals: 18, maxFractionDigits: 4), "123456.789")
        XCTAssertEqual(UInt256(1_500_000).formatted(decimals: 6), "1.5")
        XCTAssertEqual(UInt256(5).formatted(decimals: 6), "0.000005")
        XCTAssertNil(UInt256(units: "1.1234567", decimals: 6), "more decimals than the token has")
        XCTAssertNil(UInt256(units: "abc", decimals: 6))
        XCTAssertEqual(UInt256(units: ".5", decimals: 8), UInt256(50_000_000))
        XCTAssertEqual(UInt256(30).adding(UInt256(12)), UInt256(42))
        XCTAssertNil(UInt256(1).subtracting(UInt256(2)))
        let fees = EthereumFees.suggested(baseFee: UInt256(10_000_000_000), priorityFee: UInt256(1_000_000_000))
        XCTAssertEqual(fees.maxFeePerGas, UInt256(21_000_000_000))
    }

    func testRecoverableSignatureRecovers() throws {
        let digest = Keccak256.hash("carrel")
        let (r, s, recid) = try Secp256k1.signRecoverable(digest: digest, privateKey: account.signingKey())
        let recovered = try XCTUnwrap(Secp256k1.recoverPublicKey(signature: r + s + [UInt8(recid)], digest: digest))
        XCTAssertEqual(try EthereumAddress.from(publicKey: recovered), account.address)
    }

    func testUnwrapStatusParsing() {
        let pending = LBCBridge.unwrapStatus(from: ["burnTxid": "0x1", "status": "pending", "confirmations": 3, "required": 12])
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.required, 12)
        let paid = LBCBridge.unwrapStatus(from: ["status": "paid", "confirmations": 14, "minConfirmations": 12,
                                                 "payouts": [["status": "paid", "lbcTxid": "ab"]]])
        XCTAssertEqual(paid.state, .paid)
        XCTAssertEqual(paid.payoutTxids, ["ab"])
        // POST unwrap returns payouts without a top-level status once paid.
        let posted = LBCBridge.unwrapStatus(from: ["burnTxid": "0x1", "payouts": [["status": "paid", "lbcTxid": "cd"]]])
        XCTAssertEqual(posted.state, .paid)
    }
}
