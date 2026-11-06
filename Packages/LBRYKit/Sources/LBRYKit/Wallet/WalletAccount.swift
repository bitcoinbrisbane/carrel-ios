import Foundation

/// One LBC account in the LBRY SDK layout, so phrases move freely between Carrel,
/// LBRY Desktop and Odysee:
///
///     seed    = PBKDF2-HMAC-SHA512(phrase, "lbryum", 2048)
///     account = BIP32 master key from that seed
///     receive = account/0/i      change = account/1/i
public struct WalletAccount: Sendable {

    public enum Chain: UInt32, Sendable, Codable, CaseIterable {
        case receive = 0
        case change = 1
    }

    public struct Address: Equatable, Hashable, Sendable, Codable {
        public let chain: Chain
        public let index: UInt32
        public let address: String
        public let publicKey: [UInt8]
        public var path: String { "m/\(chain.rawValue)/\(index)" }
    }

    /// lbry-sdk's default gap: how many unused addresses to keep watching past the last used one.
    public static let receiveGap = 20
    public static let changeGap = 6

    private let accountKey: HDKey
    private let chainKeys: [Chain: HDKey]

    public var extendedPublicKey: String { accountKey.extendedPublic() }
    public var canSign: Bool { accountKey.privateKey != nil }

    /// From a recovery phrase (any phrase is accepted, as in LBRY Desktop).
    public init(phrase: String) throws {
        try self.init(accountKey: HDKey.master(seed: Mnemonic.lbrySeed(phrase)))
    }

    /// From an xprv (spending) or xpub (watch-only).
    public init(extendedKey: String) throws {
        try self.init(accountKey: HDKey(extendedKey: extendedKey))
    }

    init(accountKey: HDKey) throws {
        self.accountKey = accountKey
        var chains: [Chain: HDKey] = [:]
        for chain in Chain.allCases { chains[chain] = try accountKey.derive(chain.rawValue) }
        chainKeys = chains
    }

    public func address(_ chain: Chain, _ index: UInt32) throws -> Address {
        let key = try chainKeys[chain]!.neutered.derive(index)
        return Address(chain: chain, index: index, address: LBCAddress.p2pkh(publicKey: key.publicKey), publicKey: key.publicKey)
    }

    public func addresses(_ chain: Chain, _ range: Range<UInt32>) throws -> [Address] {
        try range.map { try address(chain, $0) }
    }

    /// Private key for an address; throws on a watch-only account.
    public func privateKey(_ chain: Chain, _ index: UInt32) throws -> [UInt8] {
        guard canSign else { throw HDKey.Error.hardenedFromPublic }
        guard let key = try chainKeys[chain]!.derive(index).privateKey else { throw HDKey.Error.derivationFailed }
        return key
    }

    public func privateKey(for address: Address) throws -> [UInt8] {
        try privateKey(address.chain, address.index)
    }
}
