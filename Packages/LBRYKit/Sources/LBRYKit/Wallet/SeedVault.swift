import Foundation

#if canImport(Security)
import Security

/// Keeps the recovery phrase in the Keychain.
///
/// With `syncsToICloud` (the default) the item is synchronizable, so iCloud Keychain
/// carries it, end-to-end encrypted, to the user's other devices and to a new
/// iPhone: no seed phrase to write down up front, Breez-style. The trade-off is
/// that anyone who takes over the Apple ID can restore the wallet, so the app
/// should nudge larger balances towards an offline backup of the phrase.
public struct SeedVault: Sendable {

    public enum Error: Swift.Error, Equatable {
        case keychain(OSStatus)
        case corrupt
    }

    public let service: String
    public let account: String
    public let syncsToICloud: Bool

    public init(service: String = "au.com.bitcoinbrisbane.carrel.wallet", account: String = "lbc-main", syncsToICloud: Bool = true) {
        self.service = service
        self.account = account
        self.syncsToICloud = syncsToICloud
    }

    public func save(phrase: String) throws {
        let data = Data(phrase.utf8)
        var add = baseQuery()
        add[kSecValueData as String] = data
        // Synced items can't be "ThisDeviceOnly"; AfterFirstUnlock lets background refresh read it.
        add[kSecAttrAccessible as String] = syncsToICloud
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Error.keychain(status) }
    }

    /// The stored phrase, or nil if there is none on this device or in iCloud Keychain.
    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.keychain(status) }
        guard let data = item as? Data, let phrase = String(data: data, encoding: .utf8) else { throw Error.corrupt }
        return phrase
    }

    /// Removes the phrase here and, if synced, from every device on the Apple ID.
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.keychain(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: syncsToICloud ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }
}
#endif
