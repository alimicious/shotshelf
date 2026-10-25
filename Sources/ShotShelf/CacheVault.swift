import CryptoKit
import Foundation
import Security

/// Seals what ShotShelf remembers about your shots (their text, QR codes and fingerprints) with
/// AES-GCM, under a key kept in your login Keychain. macOS makes other apps ask before reading your
/// Desktop, but not Application Support, so a plain copy there would hand any script running as you
/// whatever your screenshots say, 2FA setup codes included. Without the key nothing is saved at
/// all, never a plain copy; the text is just read again on the next launch.
enum CacheVault {
    /// Nil when the Keychain won't hand the key over (you clicked Deny, or it's locked), and always in
    /// debug builds: each is signed differently, so the Keychain would ask about the key on every run.
    /// They keep the text in memory instead, or as plain JSON beside the samples with `--folder`.
    private static let key: SymmetricKey? = {
        #if DEBUG
        return nil
        #else
        return loadOrCreateKey()
        #endif
    }()

    static func seal(_ data: Data) -> Data? {
        guard let key else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    static func open(_ data: Data) -> Data? {
        guard let key, let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ShotShelf text cache key",
        kSecAttrAccount as String: "ShotShelf",
    ]

    private static func loadOrCreateKey() -> SymmetricKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Only make a key when there's none: replacing one the Keychain merely refused would strand
        // everything sealed with it.
        guard status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(item.merging([kSecValueData as String: raw]) { $1 } as CFDictionary, nil)
        return added == errSecSuccess ? key : nil
    }
}
