import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Linking Apple TV to the iPhone's encrypted backup without putting the recovery
/// phrase on the TV.
///
/// 1. The TV makes a one-off X25519 key pair and shows `carrel://pair-tv?id=…&pk=…`
///    as a QR code.
/// 2. The iPhone (which has the phrase) derives the backup key, encrypts it to the
///    TV's public key (ephemeral X25519 → HKDF-SHA256 → AES-GCM), and leaves the
///    result in iCloud key-value storage under `carrel.tvpair.<id>`.
/// 3. The TV, signed in to the same iCloud account, picks it up, decrypts it with
///    its private key, keeps the backup key in its own Keychain and deletes the entry.
///
/// The backup key reads and writes taste, follows and history; it can't spend or
/// derive anything in the wallet.
public enum TVPairing {

    public enum Error: Swift.Error, Equatable {
        case badLink
        case cannotDecrypt
    }

    /// iCloud key-value key for a pairing's sealed backup key.
    public static func storeKey(id: String) -> String { "carrel.tvpair.\(id)" }

    /// The TV's side: a one-off key pair and the link to show as a QR code.
    public struct Request: Sendable {
        public let id: String
        public let privateKey: Curve25519.KeyAgreement.PrivateKey

        public init(id: String = Self.newID(), privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
            self.id = id
            self.privateKey = privateKey
        }

        public var link: URL {
            var c = URLComponents()
            c.scheme = "carrel"
            c.host = "pair-tv"
            c.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "pk", value: TVPairing.base64url(privateKey.publicKey.rawRepresentation)),
            ]
            return c.url!
        }

        /// Six characters, also shown on screen so the phone can confirm it's this TV.
        public static func newID() -> String {
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            return String((0..<6).map { _ in alphabet.randomElement()! })
        }

        /// The backup key from the phone's sealed entry.
        public func open(_ sealed: Data) throws -> SymmetricKey {
            guard sealed.count > 32,
                  let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.prefix(32)),
                  let shared = try? privateKey.sharedSecretFromKeyAgreement(with: ephemeral) else {
                throw Error.cannotDecrypt
            }
            let wrap = TVPairing.wrappingKey(shared, ephemeral: ephemeral, recipient: privateKey.publicKey, id: id)
            guard let box = try? AES.GCM.SealedBox(combined: sealed.dropFirst(32)),
                  let raw = try? AES.GCM.open(box, using: wrap, authenticating: Array(id.utf8)) else {
                throw Error.cannotDecrypt
            }
            return SymmetricKey(data: raw)
        }
    }

    /// What the phone reads from the TV's QR code.
    public struct Offer: Equatable, Sendable {
        public let id: String
        public let publicKey: Data

        /// Parses `carrel://pair-tv?id=…&pk=…`.
        public init(link: String) throws {
            guard let c = URLComponents(string: link), c.scheme?.lowercased() == "carrel", c.host == "pair-tv",
                  let id = c.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty, id.count <= 16,
                  let pk = c.queryItems?.first(where: { $0.name == "pk" })?.value,
                  let key = TVPairing.data(base64url: pk), key.count == 32,
                  (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil else {
                throw Error.badLink
            }
            self.id = id
            self.publicKey = key
        }

        /// `ephemeral public key (32) ‖ AES-GCM(nonce ‖ ciphertext ‖ tag)` of the backup key.
        public func seal(backupKey: SymmetricKey) throws -> Data {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            let wrap = TVPairing.wrappingKey(shared, ephemeral: ephemeral.publicKey, recipient: recipient, id: id)
            let raw = backupKey.withUnsafeBytes { Data($0) }
            let box = try AES.GCM.seal(raw, using: wrap, authenticating: Array(id.utf8))
            guard let combined = box.combined else { throw Error.cannotDecrypt }
            return ephemeral.publicKey.rawRepresentation + combined
        }
    }

    static func wrappingKey(_ shared: SharedSecret, ephemeral: Curve25519.KeyAgreement.PublicKey,
                            recipient: Curve25519.KeyAgreement.PublicKey, id: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Array("carrel-tv-pair-v1".utf8),
            sharedInfo: ephemeral.rawRepresentation + recipient.rawRepresentation + Data(id.utf8),
            outputByteCount: 32
        )
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
