import Foundation
import Observation

/// Options of note encryption, persisted in UserDefaults under `encryption.*` keys.
/// Nothing here is secret: the identity itself only ever lives in a `KeyStore`.
@Observable
final class EncryptionSettings {
    static let shared = EncryptionSettings()

    enum Store: String {
        case keychain
        case protonPass
    }

    /// The `age1...` recipient notes are encrypted to. Empty until setup is done.
    var recipient: String { didSet { defaults.set(recipient, forKey: "encryption.recipient") } }
    var store: Store { didSet { defaults.set(store.rawValue, forKey: "encryption.store") } }
    /// `pass://<share id>/<item title>` of the Proton Pass item. Empty for the Keychain store.
    var keyURI: String { didSet { defaults.set(keyURI, forKey: "encryption.keyURI") } }
    /// Minutes without reading or writing an encrypted note before the session locks.
    var idleMinutes: Double { didSet { defaults.set(idleMinutes, forKey: "encryption.idleMinutes") } }
    /// The one-time warning about plaintext left in git history has been shown.
    var historyWarningShown: Bool { didSet { defaults.set(historyWarningShown, forKey: "encryption.historyWarningShown") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recipient = defaults.string(forKey: "encryption.recipient") ?? ""
        store = defaults.string(forKey: "encryption.store").flatMap(Store.init(rawValue:)) ?? .keychain
        keyURI = defaults.string(forKey: "encryption.keyURI") ?? ""
        idleMinutes = defaults.object(forKey: "encryption.idleMinutes") as? Double ?? 10
        historyWarningShown = defaults.bool(forKey: "encryption.historyWarningShown")
    }

    /// The parsed recipient, nil until setup is done.
    var ageRecipient: AgeRecipient? {
        AgeRecipient(bech32: recipient)
    }

    var isSetUp: Bool {
        ageRecipient != nil
    }
}
