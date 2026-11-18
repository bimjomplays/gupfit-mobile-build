import Foundation
#if canImport(Security)
import Security

/// The PC pairing (its address and this phone's token) in the Keychain: this device only, readable while unlocked,
/// never synced or backed up to another device. Nothing about it goes to files or UserDefaults.
final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    private let service = "app.gupfit.phone.pc-pairing"
    private let account = "pc"

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() -> PCPairing? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PCPairing.self, from: data)
    }

    @discardableResult
    func save(_ pairing: PCPairing) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(item as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(attrs) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func clear() {
        SecItemDelete(item as CFDictionary)
    }
}
#endif
