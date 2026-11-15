import Foundation
import Security

/// Keeps the sign-in in the keychain.
enum Keychain {
    private static let account = "tokens"
    private static let service = "app.kumori.tv"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account, kSecAttrService as String: service]
    }

    static func save(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
