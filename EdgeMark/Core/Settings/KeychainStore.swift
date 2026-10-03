import Foundation
import Security

/// The TypeSafe API key as a generic-password item in the login Keychain.
/// Values are never logged.
enum KeychainStore {
    private nonisolated static let service = "io.github.ender-wang.EdgeMark.typesafe"
    private nonisolated static let account = "api-key"

    private nonisolated static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or nil when there is none.
    nonisolated static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    /// Updates the item, or adds it when missing. Returns true on success.
    @discardableResult
    nonisolated static func write(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var q = query
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the item. Returns true when it is gone (or was never there).
    @discardableResult
    nonisolated static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
