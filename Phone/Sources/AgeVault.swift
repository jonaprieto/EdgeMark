import EdgeCrypto
import Foundation
import LocalAuthentication
import Security

/// The age identity in a Keychain item only Face ID releases. Unlike the app's other keys, the
/// Secure Enclave enforces this: no unlocked phone gets it without a current enrolled face.
enum AgeVault {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.jonaprieto.edgemark.age",
        kSecAttrAccount as String: "age-identity",
    ]

    /// Replaces the stored identity. A value that is no age identity is ignored.
    static func store(_ secret: String) {
        guard AgeIdentity(bech32: secret) != nil,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
        else { return }
        SecItemDelete(item as CFDictionary)
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrAccessControl as String: access]
        SecItemAdd(item.merging(attributes) { $1 } as CFDictionary, nil)
    }

    /// Prompts for Face ID. Nil when refused, or when no identity was installed.
    static func unlock() async -> AgeIdentity? {
        await Task.detached {
            let context = LAContext()
            context.localizedReason = "Open your encrypted note"
            let query = item.merging([
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]) { $1 }
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return AgeIdentity(bech32: String(decoding: data, as: UTF8.self))
        }.value
    }
}
