import CryptoKit
import Foundation

/// An age X25519 recipient: the public key notes are encrypted to. Not secret.
nonisolated struct AgeRecipient: Equatable, Sendable {
    /// 32-byte X25519 public key.
    let publicKey: Data

    init(publicKey: Data) {
        self.publicKey = publicKey
    }

    /// Parses `age1...`. Nil unless it is valid Bech32 with the `age` prefix and 32 bytes.
    init?(bech32: String) {
        guard let decoded = Bech32.decode(bech32.trimmingCharacters(in: .whitespacesAndNewlines)),
              decoded.hrp == "age", decoded.data.count == 32 else { return nil }
        publicKey = decoded.data
    }

    /// The `age1...` form.
    var string: String {
        Bech32.encode(hrp: "age", data: publicKey)
    }
}

/// An age X25519 identity: the private key that decrypts. Its `string` is the secret.
nonisolated struct AgeIdentity: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    static func generate() -> AgeIdentity {
        AgeIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Parses `AGE-SECRET-KEY-1...`. Nil unless it is valid Bech32 with that prefix and 32 bytes.
    init?(bech32: String) {
        guard let decoded = Bech32.decode(bech32.trimmingCharacters(in: .whitespacesAndNewlines)),
              decoded.hrp == "age-secret-key-", decoded.data.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decoded.data) else { return nil }
        privateKey = key
    }

    /// The `AGE-SECRET-KEY-1...` form (uppercase, as the age tools print it).
    var string: String {
        Bech32.encode(hrp: "age-secret-key-", data: privateKey.rawRepresentation).uppercased()
    }

    var recipient: AgeRecipient {
        AgeRecipient(publicKey: privateKey.publicKey.rawRepresentation)
    }
}
