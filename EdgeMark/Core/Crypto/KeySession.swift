import Foundation
import Observation

nonisolated enum KeySessionError: Error, Equatable {
    /// Setup is not done: there is no store or no recipient.
    case notConfigured
    /// The store returned an identity for another recipient than the one in settings.
    case recipientMismatch
}

extension Notification.Name {
    static let keySessionDidUnlock = Notification.Name("io.github.ender-wang.EdgeMark.keySessionDidUnlock")
    static let keySessionDidLock = Notification.Name("io.github.ender-wang.EdgeMark.keySessionDidLock")
}

/// Holds the unlocked age identity in memory, and nowhere else, for as long as the
/// session lasts. On the main actor because `FileStorage` reads it synchronously there.
@MainActor
@Observable
final class KeySession {
    static let shared = KeySession()

    private(set) var identity: AgeIdentity?

    var isUnlocked: Bool {
        identity != nil
    }

    /// The configured store, the recipient setup recorded, and the idle time before the
    /// session locks. Set by the app at launch; tests inject their own.
    @ObservationIgnored var store: () -> (any KeyStore)? = { nil }
    @ObservationIgnored var expectedRecipient: () -> AgeRecipient? = { nil }
    @ObservationIgnored var idleSeconds: () -> TimeInterval = { 600 }

    @ObservationIgnored private var idleTask: Task<Void, Never>?

    /// The store read in flight, shared by every caller that asks while it runs, so the
    /// user sees one presence prompt.
    @ObservationIgnored private var loading: Task<AgeIdentity, any Error>?
    /// Bumped by `lock()`, so an unlock that was waiting on the store when the session
    /// was told to lock does not unlock it afterwards.
    @ObservationIgnored private var lockCount = 0

    /// Loads the identity from the store. Throws the store's `KeyStoreError`
    /// (`cancelled` when `lock()` ran meanwhile), or a `KeySessionError` when setup is
    /// missing or the key is not the one notes use.
    func unlock() async throws {
        guard !isUnlocked else { return touch() }
        guard let store = store(), let expected = expectedRecipient() else { throw KeySessionError.notConfigured }
        let startedAt = lockCount
        let task = loading ?? Task { try await store.load() }
        loading = task
        let result = await task.result
        if loading == task {
            loading = nil
        }
        let loaded = try result.get()
        guard lockCount == startedAt else { throw KeyStoreError.cancelled }
        guard loaded.recipient == expected else { throw KeySessionError.recipientMismatch }
        guard !isUnlocked else { return }
        identity = loaded
        touch()
        NotificationCenter.default.post(name: .keySessionDidUnlock, object: nil)
    }

    /// Starts a session with an identity the caller just loaded from the store and checked
    /// (the setup wizard), so the user is not asked for presence twice in a row.
    func begin(with identity: AgeIdentity) {
        self.identity = identity
        touch()
        NotificationCenter.default.post(name: .keySessionDidUnlock, object: nil)
    }

    /// Forgets the identity. The notification is posted on every call, also when already
    /// locked, so views holding a secret of their own (a recovery key) drop it too.
    func lock() {
        lockCount += 1
        loading = nil
        idleTask?.cancel()
        idleTask = nil
        identity = nil
        NotificationCenter.default.post(name: .keySessionDidLock, object: nil)
    }

    /// Restarts the idle timer. Called on every decrypt and encrypt.
    func touch() {
        guard isUnlocked else { return }
        idleTask?.cancel()
        // A broken setting must not lock at once or trap in `.seconds`.
        let configured = idleSeconds()
        let seconds = configured.isFinite && configured > 0 ? configured : 600
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }
}
