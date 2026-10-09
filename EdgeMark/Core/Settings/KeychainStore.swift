import Foundation
import Security

/// One generic-password item in the login Keychain. Values are never logged.
nonisolated struct KeychainStore: Sendable {
    let service: String
    let account: String

    /// The TypeSafe API key of the secrets guard.
    static let typeSafe = KeychainStore(service: "io.github.ender-wang.EdgeMark.typesafe", account: "api-key")

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored value, or nil when there is none.
    func read() -> String? {
        readWithStatus().value
    }

    /// The stored value and the Keychain's answer. The value is nil for any status but
    /// `errSecSuccess`: only `errSecItemNotFound` means there is no item, anything else
    /// (a denied prompt, a locked Keychain) means it could not be read.
    func readWithStatus() -> (value: String?, status: OSStatus) {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        let value = String(decoding: data, as: UTF8.self)
        return (value.isEmpty ? nil : value, status)
    }

    /// Adds the item and never replaces one: `errSecDuplicateItem` when it exists.
    func add(_ value: String) -> OSStatus {
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(q as CFDictionary, nil)
    }

    /// Updates the item, or adds it when missing. Returns true on success.
    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var q = query
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the item. Returns true when it is gone (or was never there).
    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
