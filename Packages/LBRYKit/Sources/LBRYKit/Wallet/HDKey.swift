import Foundation

/// BIP32 hierarchical deterministic key.
public struct HDKey: Equatable, Sendable {

    public enum Error: Swift.Error, Equatable {
        case invalidSeed
        case hardenedFromPublic
        case invalidPath(String)
        case invalidExtendedKey
        case derivationFailed
    }

    public static let hardened: UInt32 = 0x8000_0000

    /// BIP32 version bytes. LBC mainnet uses Bitcoin's xprv/xpub.
    public struct Versions: Equatable, Sendable {
        public let `public`: UInt32
        public let `private`: UInt32
        public static let mainnet = Versions(public: 0x0488_B21E, private: 0x0488_ADE4)
    }

    public let privateKey: [UInt8]?
    public let publicKey: [UInt8]
    public let chainCode: [UInt8]
    public let depth: UInt8
    public let parentFingerprint: UInt32
    public let childIndex: UInt32

    init(privateKey: [UInt8]?, publicKey: [UInt8], chainCode: [UInt8], depth: UInt8, parentFingerprint: UInt32, childIndex: UInt32) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.chainCode = chainCode
        self.depth = depth
        self.parentFingerprint = parentFingerprint
        self.childIndex = childIndex
    }

    /// Master key from a 16–64 byte seed (HMAC-SHA512 keyed with "Bitcoin seed").
    public static func master(seed: [UInt8]) throws -> HDKey {
        guard (16...64).contains(seed.count) else { throw Error.invalidSeed }
        let i = LBRYHash.hmacSHA512(key: Array("Bitcoin seed".utf8), data: seed)
        let key = Array(i[0..<32])
        guard Secp256k1.isValidPrivateKey(key) else { throw Error.invalidSeed }
        return HDKey(
            privateKey: key, publicKey: try Secp256k1.publicKey(privateKey: key),
            chainCode: Array(i[32..<64]), depth: 0, parentFingerprint: 0, childIndex: 0
        )
    }

    public var fingerprint: UInt32 {
        let h = LBRYHash.hash160(publicKey)
        return UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
    }

    /// The same key without its private half.
    public var neutered: HDKey {
        HDKey(privateKey: nil, publicKey: publicKey, chainCode: chainCode, depth: depth,
              parentFingerprint: parentFingerprint, childIndex: childIndex)
    }

    /// Child key. Indexes ≥ 2^31 are hardened and need the private key.
    public func derive(_ index: UInt32) throws -> HDKey {
        let isHardened = index >= Self.hardened
        var data: [UInt8]
        if isHardened {
            guard let privateKey else { throw Error.hardenedFromPublic }
            data = [0] + privateKey
        } else {
            data = publicKey
        }
        data += [UInt8(index >> 24), UInt8((index >> 16) & 0xFF), UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)]

        let i = LBRYHash.hmacSHA512(key: chainCode, data: data)
        let tweak = Array(i[0..<32])
        let childChain = Array(i[32..<64])

        do {
            if let privateKey {
                let childKey = try Secp256k1.privateKeyTweakAdd(privateKey, tweak: tweak)
                return HDKey(privateKey: childKey, publicKey: try Secp256k1.publicKey(privateKey: childKey),
                             chainCode: childChain, depth: depth + 1, parentFingerprint: fingerprint, childIndex: index)
            }
            let childPublic = try Secp256k1.publicKeyTweakAdd(publicKey, tweak: tweak)
            return HDKey(privateKey: nil, publicKey: childPublic, chainCode: childChain,
                         depth: depth + 1, parentFingerprint: fingerprint, childIndex: index)
        } catch {
            // Probability ~2^-127; BIP32 says skip to the next index.
            throw Error.derivationFailed
        }
    }

    /// Path like `m/44'/140'/0'/0/7` (`'` or `h` marks hardened).
    public func derive(path: String) throws -> HDKey {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.first == "m" else { throw Error.invalidPath(path) }
        parts.removeFirst()
        var key = self
        for part in parts {
            let isHardened = part.hasSuffix("'") || part.hasSuffix("h")
            guard let n = UInt32(isHardened ? String(part.dropLast()) : part), n < Self.hardened else {
                throw Error.invalidPath(path)
            }
            key = try key.derive(isHardened ? n | Self.hardened : n)
        }
        return key
    }

    // MARK: Extended key serialisation (xprv / xpub)

    public func extendedPrivate(_ versions: Versions = .mainnet) -> String? {
        guard let privateKey else { return nil }
        return serialize(version: versions.private, key: [0] + privateKey)
    }

    public func extendedPublic(_ versions: Versions = .mainnet) -> String {
        serialize(version: versions.public, key: publicKey)
    }

    public init(extendedKey: String, versions: Versions = .mainnet) throws {
        guard let raw = Base58.decodeCheck(extendedKey.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 78 else {
            throw Error.invalidExtendedKey
        }
        func u32(_ i: Int) -> UInt32 { raw[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        let version = u32(0)
        let keyData = Array(raw[45..<78])
        let chain = Array(raw[13..<45])
        if version == versions.private, keyData[0] == 0 {
            let key = Array(keyData[1...])
            guard Secp256k1.isValidPrivateKey(key) else { throw Error.invalidExtendedKey }
            self.init(privateKey: key, publicKey: try Secp256k1.publicKey(privateKey: key), chainCode: chain,
                      depth: raw[4], parentFingerprint: u32(5), childIndex: u32(9))
        } else if version == versions.public {
            _ = try Secp256k1.publicKeyTweakAdd(keyData, tweak: [UInt8](repeating: 0, count: 31) + [1])   // validates the point
            self.init(privateKey: nil, publicKey: keyData, chainCode: chain,
                      depth: raw[4], parentFingerprint: u32(5), childIndex: u32(9))
        } else {
            throw Error.invalidExtendedKey
        }
    }

    private func serialize(version: UInt32, key: [UInt8]) -> String {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        return Base58.encodeCheck(be(version) + [depth] + be(parentFingerprint) + be(childIndex) + chainCode + key)
    }
}
