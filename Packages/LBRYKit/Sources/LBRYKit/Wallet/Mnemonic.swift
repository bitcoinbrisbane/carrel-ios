import Foundation

/// Recovery phrases. New wallets get a standard 12-word BIP39 phrase; the seed is
/// derived the LBRY SDK way (PBKDF2, salt "lbryum"), so the same phrase restores
/// in LBRY Desktop and Odysee, and their phrases restore here.
public enum Mnemonic {

    public enum Error: Swift.Error, Equatable {
        case badEntropyLength
    }

    /// New phrase from fresh randomness (12 words = 128 bits, 24 words = 256 bits).
    public static func generate(words: Int = 12) -> String {
        let bytes = words == 24 ? 32 : 16
        return try! phrase(entropy: LBRYHash.randomBytes(bytes))
    }

    /// BIP39 entropy → phrase (entropy + first ENT/32 bits of its SHA-256 as checksum).
    public static func phrase(entropy: [UInt8]) throws -> String {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { throw Error.badEntropyLength }
        let checksumBits = entropy.count * 8 / 32
        let checksum = LBRYHash.sha256(entropy)[0]
        var bits: [Bool] = []
        for byte in entropy { for i in (0..<8).reversed() { bits.append(byte >> UInt8(i) & 1 == 1) } }
        for i in 0..<checksumBits { bits.append(checksum >> UInt8(7 - i) & 1 == 1) }
        var words: [String] = []
        for start in stride(from: 0, to: bits.count, by: 11) {
            let index = bits[start..<start + 11].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
            words.append(english[index])
        }
        return words.joined(separator: " ")
    }

    /// True when every word is on the list and the BIP39 checksum matches.
    /// (LBRY Desktop accepts any phrase on restore; Carrel warns but still allows it.)
    public static func isValidBIP39(_ phrase: String) -> Bool {
        let words = clean(phrase).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count) else { return false }
        var bits: [Bool] = []
        for word in words {
            guard let index = wordIndex[word] else { return false }
            for i in (0..<11).reversed() { bits.append(index >> i & 1 == 1) }
        }
        let checksumBits = words.count * 11 / 33
        let entropyBits = bits.count - checksumBits
        var entropy: [UInt8] = []
        for start in stride(from: 0, to: entropyBits, by: 8) {
            entropy.append(bits[start..<start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) })
        }
        let hash = LBRYHash.sha256(entropy)[0]
        for i in 0..<checksumBits where bits[entropyBits + i] != (hash >> UInt8(7 - i) & 1 == 1) {
            return false
        }
        return true
    }

    /// Words not on the English list (for highlighting typos while typing).
    public static func unknownWords(in phrase: String) -> [String] {
        clean(phrase).split(separator: " ").map(String.init).filter { wordIndex[$0] == nil }
    }

    public static func suggestions(for prefix: String, limit: Int = 6) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return [] }
        return Array(english.lazy.filter { $0.hasPrefix(p) }.prefix(limit))
    }

    // MARK: Seeds

    /// LBRY SDK seed (`Account.get_private_key_from_seed`):
    /// PBKDF2-HMAC-SHA512(normalize(phrase), salt "lbryum", 2048 rounds, 64 bytes).
    public static func lbrySeed(_ phrase: String) -> [UInt8] {
        LBRYHash.pbkdf2SHA512(
            password: Array(normalizeLBRY(phrase).utf8),
            salt: Array("lbryum".utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    /// Standard BIP39 seed: PBKDF2-HMAC-SHA512(phrase, "mnemonic" + passphrase, 2048).
    public static func bip39Seed(_ phrase: String, passphrase: String = "") -> [UInt8] {
        LBRYHash.pbkdf2SHA512(
            password: Array(clean(phrase).utf8),
            salt: Array(("mnemonic" + passphrase.decomposedStringWithCompatibilityMapping).utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    // MARK: Normalisation

    /// Lower-case, NFKD, single spaces: so pasted phrases validate predictably.
    public static func clean(_ phrase: String) -> String {
        phrase.decomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// lbry-sdk `normalize_text`: NFKD, lower-case, drop combining marks, collapse
    /// whitespace, and drop whitespace between CJK characters.
    public static func normalizeLBRY(_ text: String) -> String {
        let scalars = text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return false
            default: return true
            }
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let chars = Array(collapsed.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in chars.enumerated() {
            if c == " ", i > 0, i < chars.count - 1, isCJK(chars[i - 1]), isCJK(chars[i + 1]) { continue }
            out.append(c)
        }
        return String(out)
    }

    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
        0xF900...0xFAFF, 0x2F800...0x2FA1D, 0x3190...0x319F, 0x2E80...0x2EFF, 0x2F00...0x2FDF,
        0x31C0...0x31EF, 0x2FF0...0x2FFF, 0xE0100...0xE01EF, 0x3100...0x312F, 0x31A0...0x31BF,
        0xFF00...0xFFEF, 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x1B000...0x1B0FF,
        0xAC00...0xD7AF, 0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF, 0x3130...0x318F,
        0xA4D0...0xA4FF, 0x16F00...0x16F9F, 0xA000...0xA48F, 0xA490...0xA4CF,
    ]

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        cjkRanges.contains { $0.contains(scalar.value) }
    }

    private static let wordIndex: [String: Int] = Dictionary(uniqueKeysWithValues: english.enumerated().map { ($1, $0) })
}
