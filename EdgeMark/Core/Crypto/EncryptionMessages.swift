import Foundation

/// User-facing text for encryption failures.
enum EncryptionMessages {
    /// Nil for a dismissed presence prompt, which needs no message beyond the system's.
    static func text(for error: Error, l10n: L10n) -> String? {
        switch error {
        case KeyStoreError.cancelled: nil
        case KeyStoreError.missing: l10n["encryption.error.keyMissing"]
        case KeyStoreError.invalid: l10n["encryption.error.keyInvalid"]
        case let KeyStoreError.unavailable(reason): reason
        case KeySessionError.notConfigured: l10n["encryption.error.notSetUp"]
        case KeySessionError.recipientMismatch: l10n["encryption.error.recipientMismatch"]
        case let error as AgeError: l10n["encryption.error.\(error)"]
        default: error.localizedDescription
        }
    }

    /// True when running setup again, with its restore step, is the way out.
    static func needsSetup(_ error: Error) -> Bool {
        switch error {
        case KeyStoreError.missing, KeyStoreError.invalid,
             KeySessionError.notConfigured, KeySessionError.recipientMismatch: true
        default: false
        }
    }
}
