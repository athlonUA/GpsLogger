import Foundation
import Security

/// Stable, never-rotated device identifier.
///
/// Storage strategy (in order):
///   1. Keychain (`kSecClassGenericPassword`, accessible after first unlock)
///      — survives app reinstalls as long as the device has been unlocked
///      once since boot and the Keychain group isn't cleared.
///   2. UserDefaults — fallback only, used if Keychain writes fail (rare: e.g.
///      simulator edge cases, Keychain access denied). Any ID found here is
///      opportunistically promoted to the Keychain on next read.
///   3. New UUID — generated once on first launch when neither store has a
///      value, then persisted via the same two paths.
///
/// The function is idempotent: once an ID exists, `get()` always returns the
/// same string for the lifetime of the install.
enum DeviceIdentity {
    private static let keychainService = "com.gpslogger.personal"
    private static let keychainAccount = "device_id"
    private static let userDefaultsKey = "device_id"

    static func get() -> String {
        if let id = readKeychain(), !id.isEmpty {
            return id
        }
        if let id = UserDefaults.standard.string(forKey: userDefaultsKey), !id.isEmpty {
            // Migrate pre-existing UD value into the Keychain so future reads
            // prefer the stronger store. A failure here is non-fatal — the
            // UD copy remains authoritative.
            _ = writeKeychain(id)
            return id
        }
        let newId = UUID().uuidString
        if !writeKeychain(newId) {
            UserDefaults.standard.set(newId, forKey: userDefaultsKey)
        }
        return newId
    }

    // MARK: - Keychain

    private static func readKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func writeKeychain(_ id: String) -> Bool {
        guard let data = id.data(using: .utf8) else { return false }

        // Keychain inserts are not upserts; delete any prior row for this
        // (service, account) pair first, then add fresh. Errors from delete
        // are ignored — errSecItemNotFound is expected on first write.
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)

        var attrs = base
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}
