import Foundation

/// The wallet's Ethereum account, from the same recovery phrase as LBC.
///
/// LBC follows the LBRY SDK (seed salted "lbryum"); Ethereum follows the standard
/// (BIP39 seed, BIP44 `m/44'/60'/0'/0/i`), so importing the phrase into MetaMask or
/// any other Ethereum wallet shows the same address and balances.
public struct EthereumAccount: Sendable {

    public static let defaultPath = "m/44'/60'/0'/0/0"

    public let address: String
    public let path: String
    private let privateKey: [UInt8]

    public init(phrase: String, path: String = EthereumAccount.defaultPath) throws {
        let key = try HDKey.master(seed: Mnemonic.bip39Seed(phrase)).derive(path: path)
        guard let privateKey = key.privateKey else { throw HDKey.Error.derivationFailed }
        self.privateKey = privateKey
        self.path = path
        self.address = try EthereumAddress.from(publicKey: Secp256k1.uncompressedPublicKey(privateKey: privateKey))
    }

    /// For signing Ethereum transactions (next step); never leaves the wallet.
    func signingKey() -> [UInt8] { privateKey }
}

public enum EthereumAddress {

    /// EIP-55 checksummed address from a 65-byte uncompressed public key.
    public static func from(publicKey: [UInt8]) throws -> String {
        guard publicKey.count == 65, publicKey[0] == 0x04 else { throw Secp256k1Error.invalidPublicKey }
        return checksummed(Array(Keccak256.hash(Array(publicKey[1...])).suffix(20)).hex)
    }

    /// EIP-55: upper-case each hex letter whose nibble in keccak(lowercase address) is ≥ 8.
    public static func checksummed(_ address: String) -> String {
        let lower = address.lowercased().replacingOccurrences(of: "0x", with: "")
        let hash = Keccak256.hash(lower).hex
        var out = "0x"
        for (c, h) in zip(lower, hash) {
            out.append(c.isLetter && Int(String(h), radix: 16)! >= 8 ? Character(c.uppercased()) : c)
        }
        return out
    }

    public static func isValid(_ address: String) -> Bool {
        let body = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard body.count == 40, body.allSatisfy(\.isHexDigit) else { return false }
        // All-lower or all-upper carries no checksum; mixed case must match EIP-55.
        if body == body.lowercased() || body == body.uppercased() { return true }
        return checksummed(body) == "0x" + body
    }

    /// 20 raw bytes.
    static func bytes(_ address: String) -> [UInt8]? {
        let body = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard let b = [UInt8](hex: body.lowercased()), b.count == 20 else { return nil }
        return b
    }
}

/// EIP-191 `personal_sign` messages, as the bridge uses to sign deposit addresses.
public enum PersonalMessage {

    public static func hash(_ message: String) -> [UInt8] {
        let bytes = Array(message.utf8)
        return Keccak256.hash(Array("\u{19}Ethereum Signed Message:\n\(bytes.count)".utf8) + bytes)
    }

    /// The address that signed `message`, or nil if the signature is malformed.
    public static func signer(of message: String, signature hex: String) -> String? {
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let signature = [UInt8](hex: body.lowercased()),
              let publicKey = Secp256k1.recoverPublicKey(signature: signature, digest: hash(message)) else { return nil }
        return try? EthereumAddress.from(publicKey: publicKey)
    }
}

// MARK: - Tokens and amounts

public struct ERC20Token: Hashable, Sendable, Identifiable {
    public let symbol: String
    public let name: String
    public let contract: String
    public let decimals: Int
    public var id: String { symbol }

    public static let usdc = ERC20Token(symbol: "USDC", name: "USD Coin", contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6)
    public static let usdt = ERC20Token(symbol: "USDT", name: "Tether USD", contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6)
    /// Wrapped LBC from lbc.exchange: 8 decimals, so 1 wLBC unit = 1 dewey.
    public static let wlbc = ERC20Token(symbol: "wLBC", name: "Wrapped LBC", contract: "0xB0F2C4f8b7c0f088f7844947EcBf1220bFCa08C1", decimals: 8)

    public static let mainnetDefaults: [ERC20Token] = [.usdc, .usdt, .wlbc]
}

/// An amount in an asset's smallest unit (wei, or token units), kept exact.
public struct TokenAmount: Hashable, Sendable {
    /// Smallest units, as a decimal string (wei can exceed UInt64).
    public let units: Decimal
    public let decimals: Int

    public init(units: Decimal, decimals: Int) {
        self.units = units
        self.decimals = decimals
    }

    /// From an Ethereum hex quantity ("0x1bc16d674ec80000").
    public init?(hex: String, decimals: Int) {
        var body = hex.hasPrefix("0x") ? Substring(hex.dropFirst(2)) : Substring(hex)
        while body.count > 1, body.first == "0" { body = body.dropFirst() }
        var value = Decimal(0)
        for c in body {
            guard let digit = c.hexDigitValue else { return nil }
            value = value * 16 + Decimal(digit)
        }
        self.init(units: value, decimals: decimals)
    }

    public var isZero: Bool { units == 0 }

    /// Whole-unit value (e.g. 1.5 for 1.5 ETH).
    public var value: Decimal {
        var result = Decimal()
        var u = units
        _ = NSDecimalMultiplyByPowerOf10(&result, &u, Int16(-decimals), .plain)
        return result
    }

    /// Human-readable, trimmed to `maxFractionDigits`.
    public func formatted(maxFractionDigits: Int = 6) -> String {
        var rounded = Decimal()
        var v = value
        NSDecimalRound(&rounded, &v, maxFractionDigits, .down)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFractionDigits
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = false
        return f.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
    }
}
