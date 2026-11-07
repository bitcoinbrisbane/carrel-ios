import SwiftUI
import CryptoKit
import Security
import LBRYKit

/// The iPhone's backup key on this TV, in the TV's own Keychain (not synced anywhere).
enum TVKeyStore {
    private static let service = "au.com.bitcoinbrisbane.carrel.tv-backup-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "backup-key",
         kSecAttrSynchronizable as String: false]
    }

    static func load() -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    static func save(_ key: SymmetricKey) {
        delete()
        var q = query
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Shows the pairing QR code and waits for the iPhone to hand over the key.
struct TVLinkView: View {
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var request = TVPairing.Request()
    @State private var done = false
    /// Shown inside the iPhone tab rather than as a sheet: no Cancel / Done.
    var embedded = false

    var body: some View {
        HStack(spacing: 80) {
            QRCodeImage(text: request.link.absoluteString)
                .padding(28)
                .background(.white, in: RoundedRectangle(cornerRadius: 24))
                .frame(width: 480, height: 480)
                .accessibilityLabel("QR code to link Carrel on iPhone")
            VStack(alignment: .leading, spacing: 24) {
                if done {
                    Label("Linked", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
                    Text("Your taste, follows and history are coming across from the iPhone.").foregroundStyle(.secondary)
                    if !embedded { Button("Done") { dismiss() } }
                } else {
                    Text("Link Carrel on iPhone").font(.title2.bold())
                    Text("Scan with the iPhone camera, check the code matches, and tap Link Apple TV.")
                        .foregroundStyle(.secondary)
                    Text(request.id).font(.system(size: 64, weight: .bold, design: .monospaced)).foregroundStyle(Color.carrelAccent)
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Waiting for your iPhone…").foregroundStyle(.secondary)
                    }
                    if FileManager.default.ubiquityIdentityToken == nil {
                        Text("This Apple TV isn't signed in to iCloud (or this build lacks the iCloud entitlement), so the iPhone's answer can't arrive. Sign in under Settings › Users and Accounts.")
                            .font(.callout).foregroundStyle(.orange)
                    } else {
                        Text("Both need to be signed in to the same iCloud account.").font(.caption).foregroundStyle(.tertiary)
                    }
                    if !embedded { Button("Cancel") { dismiss() } }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(80)
        .task {
            // iCloud key-value changes can take a few seconds to arrive; check every 3 s for 10 minutes.
            for _ in 0..<200 {
                if model.completePairing(request) { done = true; return }
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            }
        }
    }
}

/// The iPhone tab: link (pairing QR right on the page) or the linked status, plus
/// blocked channels and Carrel's terms and support contact.
struct TVSyncTab: View {
    @Environment(TVModel.self) private var model
    @State private var showTerms = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if model.isLinked {
                    HStack(spacing: 40) {
                        Image(systemName: "checkmark.icloud").font(.system(size: 80)).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Synced with your iPhone").font(.title2.bold())
                            Text("Taste, follows and history stay in step through iCloud. Your recovery phrase stays on the phone."
                                 + (model.lastSync.map { " Updated \($0.formatted(.relative(presentation: .named)))." } ?? ""))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 24) {
                                Button("Sync now") { model.push() }
                                Button("Unlink") { model.unlink() }
                            }
                            .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 80)
                    .focusSection()
                } else {
                    TVLinkView(embedded: true)
                        .focusSection()
                }

                let blocked = model.blocks.sortedChannels
                if !blocked.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Blocked channels").font(.title3.weight(.semibold))
                        ForEach(blocked, id: \.id) { channel in
                            HStack(spacing: 32) {
                                Text(channel.name)
                                Button("Unblock") { model.blocks.unblock(channelID: channel.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .focusSection()
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("About").font(.title3.weight(.semibold))
                    Button("Terms of use") { showTerms = true }
                    if Support.hasEmail {
                        Text("Support and reports: \(Support.email)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()
            }
            .padding(.vertical, 40)
        }
        .sheet(isPresented: $showTerms) {
            ScrollView { Text(Support.terms).padding(80) }.focusable()
        }
    }
}
