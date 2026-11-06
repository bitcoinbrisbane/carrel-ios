import XCTest
@testable import LBRYKit

/// Expected values come from eth-account / eth-utils (Fixtures/eth_vectors.json).
final class EthereumTests: XCTestCase {

    struct Vectors: Decodable {
        struct Key: Decodable { let privateKey: String; let publicKeyUncompressed: String; let address: String }
        struct Addr: Decodable { let address: String }
        struct Hash: Decodable { let input: String; let hash: String }
        struct Signed: Decodable { let message: String; let eip191Hash: String; let signature: String; let signer: String; let depositAddress: String }
        let phrase: String
        let path0: Key
        let path1: Addr
        let keccak: [Hash]
        let selectors: [String: String]
        let checksum: [String]
        let signedMessage: Signed
    }

    private var v: Vectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "eth_vectors", withExtension: "json", subdirectory: "Fixtures"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testKeccak() {
        for t in v.keccak { XCTAssertEqual(Keccak256.hash(t.input).hex, t.hash, "\(t.input.prefix(5))… (\(t.input.count))") }
        for (signature, selector) in v.selectors { XCTAssertEqual(ABI.selector(signature).hex, selector, signature) }
    }

    func testSamePhraseGivesMetaMaskAddress() throws {
        let account = try EthereumAccount(phrase: v.phrase)
        XCTAssertEqual(account.address, v.path0.address)
        XCTAssertEqual(account.address, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", "the well-known MetaMask vector")
        XCTAssertEqual(account.signingKey().hex, v.path0.privateKey)
        XCTAssertEqual(try Secp256k1.uncompressedPublicKey(privateKey: account.signingKey()).hex, v.path0.publicKeyUncompressed)
        XCTAssertEqual(try EthereumAccount(phrase: v.phrase, path: "m/44'/60'/0'/0/1").address, v.path1.address)
    }

    func testChecksums() {
        for expected in v.checksum {
            XCTAssertEqual(EthereumAddress.checksummed(expected.lowercased()), expected)
            XCTAssertTrue(EthereumAddress.isValid(expected))
            XCTAssertTrue(EthereumAddress.isValid(expected.lowercased()))
        }
        var broken = Array(v.checksum[0])
        if let i = broken.lastIndex(where: { $0.isLetter && $0 != "x" }) {
            broken[i] = Character(broken[i].isUppercase ? broken[i].lowercased() : broken[i].uppercased())
        }
        XCTAssertFalse(EthereumAddress.isValid(String(broken)), "wrong checksum case")
        XCTAssertFalse(EthereumAddress.isValid("0x1234"))
    }

    func testRecoversPersonalMessageSigner() {
        let s = v.signedMessage
        XCTAssertEqual(PersonalMessage.hash(s.message).hex, s.eip191Hash)
        XCTAssertEqual(PersonalMessage.signer(of: s.message, signature: "0x" + s.signature), s.signer)
        XCTAssertNotEqual(PersonalMessage.signer(of: s.message + " ", signature: s.signature), s.signer)
    }

    func testBridgeVerifiesDepositOffers() throws {
        let s = v.signedMessage
        let bridge = LBCBridge()
        let offer = LBCBridge.DepositOffer(
            depositAddress: s.depositAddress, ethAddress: v.path0.address.lowercased(),
            minConfirmations: 6, message: s.message, signature: s.signature, signer: s.signer)
        XCTAssertEqual(bridge.expectedMessage(depositAddress: offer.depositAddress, ethAddress: offer.ethAddress), s.message)
        XCTAssertNoThrow(try bridge.verify(offer, onChainSigner: s.signer))

        // Signed by someone other than the contract's signer.
        XCTAssertThrowsError(try bridge.verify(offer, onChainSigner: v.path0.address))
        // Address swapped after signing.
        let swapped = LBCBridge.DepositOffer(
            depositAddress: "bU3qvW4ecNWnnjpZffgGZKBYWaUfGwYP3n", ethAddress: offer.ethAddress,
            minConfirmations: 6, message: s.message, signature: s.signature, signer: s.signer)
        XCTAssertThrowsError(try bridge.verify(swapped, onChainSigner: s.signer))
    }

    func testAmounts() {
        XCTAssertEqual(TokenAmount(hex: "0x1bc16d674ec80000", decimals: 18)?.formatted(), "2")
        XCTAssertEqual(TokenAmount(hex: "0x0", decimals: 18)?.isZero, true)
        XCTAssertEqual(TokenAmount(hex: "0x00000000000000000000000000000000000000000000000000000000000f4240", decimals: 6)?.formatted(), "1")
        XCTAssertEqual(TokenAmount(hex: "0x5f5e100", decimals: 8)?.formatted(), "1", "1 wLBC")
        XCTAssertEqual(TokenAmount(hex: "0x2386f26fc10000", decimals: 18)?.formatted(maxFractionDigits: 4), "0.01")
        XCTAssertEqual(TokenAmount(hex: "0x3b9aca07", decimals: 18)?.formatted(), "0", "dust rounds down")
        XCTAssertNil(TokenAmount(hex: "0xzz", decimals: 18))
    }
}
