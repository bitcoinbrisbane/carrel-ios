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

/// Library's sync card: link with the iPhone, or show it's linked.
struct TVSyncCard: View {
    @Environment(TVModel.self) private var model
    @State private var showLink = false

    var body: some View {
        HStack(spacing: 32) {
            Image(systemName: model.isLinked ? "checkmark.icloud" : "iphone.and.arrow.forward")
                .font(.system(size: 44))
                .foregroundStyle(model.isLinked ? Color.green : Color.carrelAccent)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.isLinked ? "Synced with your iPhone" : "Sync with your iPhone").font(.headline)
                Text(model.isLinked
                     ? "Taste, follows and history stay in step through iCloud" + (model.lastSync.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
                     : "Bring over what you follow and watch in Carrel on iPhone. Your recovery phrase stays on the phone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLinked {
                Button("Sync now") { model.push() }
                Button("Unlink") { model.unlink() }
            } else {
                Button("Link iPhone") { showLink = true }
            }
        }
        .padding(.horizontal, 80)
        .focusSection()
        .sheet(isPresented: $showLink) { TVLinkView() }
    }
}

/// Shows the pairing QR code and waits for the iPhone to hand over the key.
struct TVLinkView: View {
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var request = TVPairing.Request()
    @State private var done = false

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
                    Button("Done") { dismiss() }
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
                    Button("Cancel") { dismiss() }
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
