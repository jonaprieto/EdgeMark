import Foundation
import LocalAuthentication

/// The age identity as a generic-password item in the login Keychain, read only after
/// the user proved presence (Touch ID, or the login password without a sensor).
///
/// The build is ad-hoc signed, so the item cannot carry a biometric access control: the
/// prompt is a gate in the app, not something the Keychain enforces.
struct KeychainKeyStore: KeyStore {
    static let item = KeychainStore(service: "io.github.ender-wang.EdgeMark.encryption", account: "age-identity")

    /// Shown in the system prompt, after "EdgeMark is trying to".
    let reason: String

    func unavailableReason() async -> String? {
        nil
    }

    func save(_ identity: AgeIdentity) async throws {
        guard Self.item.write(identity.string) else {
            throw KeyStoreError.unavailable("The Keychain refused to store the key")
        }
    }

    func load() async throws -> AgeIdentity {
        do {
            _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            throw KeyStoreError.cancelled
        } catch {
            throw KeyStoreError.unavailable(error.localizedDescription)
        }
        guard let value = Self.item.read() else { throw KeyStoreError.missing }
        guard let identity = AgeIdentity(bech32: value) else { throw KeyStoreError.invalid }
        return identity
    }
}
