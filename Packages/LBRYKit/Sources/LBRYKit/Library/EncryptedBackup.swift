import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What gets backed up: the on-device taste profile and library.
public struct BackupPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let createdAt: Date
    public let taste: TasteProfile
    public let library: UserLibrary

    public init(taste: TasteProfile, library: UserLibrary, createdAt: Date = Date()) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.taste = taste
        self.library = library
    }
}

/// Encrypts the taste profile and library so they can sit in iCloud without
/// Apple (or anyone without the recovery phrase) being able to read them.
///
///     key   = HKDF-SHA256(LBRY seed, salt "carrel-backup-v1", info "taste+library", 32 bytes)
///     blob  = "CRB1" ‖ AES-256-GCM(nonce ‖ ciphertext ‖ tag) of compressed JSON
///
/// The key comes from the same phrase as the wallet, so restoring the wallet on
/// a new phone is all it takes to read the backup.
extension BackupPayload {
    /// This device's taste and library combined with another device's backup.
    public func merged(with other: BackupPayload, at date: Date = Date()) -> BackupPayload {
        BackupPayload(taste: taste.merged(with: other.taste), library: library.merged(with: other.library), createdAt: date)
    }
}

public enum EncryptedBackup {

    public enum Error: Swift.Error, Equatable {
        case notABackup
        case cannotDecrypt
        case tooLarge(Int)
        case newerVersion(Int)
    }

    static let magic = Array("CRB1".utf8)
    /// iCloud key-value storage allows 1 MB per value; leave headroom.
    public static let maxSize = 900_000

    public static func key(phrase: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Mnemonic.lbrySeed(phrase)),
            salt: Array("carrel-backup-v1".utf8),
            info: Array("taste+library".utf8),
            outputByteCount: 32
        )
    }

    /// Seals the payload, slimming history first if needed to fit `maxSize`.
    public static func seal(_ payload: BackupPayload, phrase: String) throws -> Data {
        try seal(payload, key: key(phrase: phrase))
    }

    public static func open(_ blob: Data, phrase: String) throws -> BackupPayload {
        try open(blob, key: key(phrase: phrase))
    }

    /// Seal with the backup key itself (Apple TV holds only this, never the phrase).
    public static func seal(_ payload: BackupPayload, key: SymmetricKey) throws -> Data {
        var library = slimmed(payload.library)
        while true {
            let current = BackupPayload(taste: payload.taste, library: library, createdAt: payload.createdAt)
            let plain = try compress(JSONEncoder().encode(current))
            let box = try AES.GCM.seal(plain, using: key)
            guard let combined = box.combined else { throw Error.cannotDecrypt }
            let blob = Data(magic) + combined
            if blob.count <= maxSize { return blob }
            // Too big: drop the oldest half of history and try again.
            guard library.history.count > 1 else { throw Error.tooLarge(blob.count) }
            library.trimHistory(to: library.history.count / 2)
        }
    }

    public static func open(_ blob: Data, key: SymmetricKey) throws -> BackupPayload {
        guard blob.count > magic.count, Array(blob.prefix(magic.count)) == magic else { throw Error.notABackup }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst(magic.count))
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw Error.cannotDecrypt
        }
        let payload = try JSONDecoder().decode(BackupPayload.self, from: try decompress(plain))
        guard payload.version <= BackupPayload.currentVersion else { throw Error.newerVersion(payload.version) }
        return payload
    }

    /// History keeps titles, channels and thumbnails but not descriptions, which
    /// are most of the bytes and come back on the next resolve anyway.
    public static func slimmed(_ library: UserLibrary) -> UserLibrary {
        var copy = library
        copy.mapHistoryClaims { claim in
            guard let value = claim.value, value.description != nil else { return claim }
            let slimValue = ClaimValue(
                title: value.title, description: nil, thumbnail: value.thumbnail, cover: nil, tags: value.tags,
                releaseTime: value.releaseTime, streamType: value.streamType, video: value.video, audio: value.audio,
                source: nil
            )
            var slim = Claim(claimId: claim.claimId, name: claim.name, canonicalURL: claim.canonicalURL,
                             permanentURL: claim.permanentURL, valueType: claim.valueType, timestamp: claim.timestamp,
                             signingChannel: claim.signingChannel, value: slimValue)
            slim.address = claim.address
            return slim
        }
        return copy
    }

    // MARK: Compression

    static func compress(_ data: Data) throws -> Data {
        #if canImport(Darwin)
        return try (data as NSData).compressed(using: .lzfse) as Data
        #else
        return data
        #endif
    }

    static func decompress(_ data: Data) throws -> Data {
        #if canImport(Darwin)
        return try (data as NSData).decompressed(using: .lzfse) as Data
        #else
        return data
        #endif
    }
}

extension UserLibrary {
    /// Keep only the newest `count` history entries.
    mutating func trimHistory(to count: Int) {
        replaceHistory(Array(history.prefix(max(0, count))))
    }

    mutating func mapHistoryClaims(_ transform: (Claim) -> Claim) {
        replaceHistory(history.map { entry in
            var e = entry
            e.replaceClaim(transform(entry.claim))
            return e
        })
    }
}
