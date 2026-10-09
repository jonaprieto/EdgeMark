import Foundation

/// Where the age identity is kept between sessions. `KeySession` and the UI depend on
/// this protocol only; the setup wizard is the one place that knows the implementations.
protocol KeyStore: Sendable {
    /// Human-readable reason when the store cannot be used right now, else nil.
    func unavailableReason() async -> String?
    func save(_ identity: AgeIdentity) async throws
    func load() async throws -> AgeIdentity
}

nonisolated enum KeyStoreError: Error, Equatable {
    /// The user dismissed the presence prompt.
    case cancelled
    /// The store holds no key item.
    case missing
    /// The item is there but is not an age identity.
    case invalid
    /// The store cannot be reached; the text is its own error line.
    case unavailable(String)
}
