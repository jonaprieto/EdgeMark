import XCTest
@testable import EdgeCrypto

/// A key store in memory; counts loads and can fail on demand.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    var identity: AgeIdentity?
    var error: KeyStoreError?
    private(set) var loads = 0
    /// How long `load` takes, standing in for the presence prompt.
    var delay: TimeInterval = 0

    init(identity: AgeIdentity? = nil) {
        self.identity = identity
    }

    func unavailableReason() async -> String? { nil }

    func save(_ identity: AgeIdentity) async throws {
        self.identity = identity
    }

    func load() async throws -> AgeIdentity {
        loads += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if let error { throw error }
        guard let identity else { throw KeyStoreError.missing }
        return identity
    }
}

@MainActor
final class KeySessionTests: XCTestCase {
    private func session(store: MemoryKeyStore, recipient: AgeRecipient?, idle: TimeInterval = 600) -> KeySession {
        let session = KeySession()
        session.store = { store }
        session.expectedRecipient = { recipient }
        session.idleSeconds = { idle }
        return session
    }

    func testUnlockLoadsOnceAndLockForgets() async throws {
        let identity = AgeIdentity.generate()
        let store = MemoryKeyStore(identity: identity)
        let session = session(store: store, recipient: identity.recipient)
        XCTAssertFalse(session.isUnlocked)
        try await session.unlock()
        try await session.unlock()
        XCTAssertEqual(session.identity?.string, identity.string)
        XCTAssertEqual(store.loads, 1)
        let locked = expectation(forNotification: .keySessionDidLock, object: nil)
        session.lock()
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertFalse(session.isUnlocked)
    }

    func testLockPostsEvenWhenAlreadyLocked() {
        let session = session(store: MemoryKeyStore(identity: AgeIdentity.generate()), recipient: AgeIdentity.generate().recipient)
        let locked = expectation(forNotification: .keySessionDidLock, object: nil)
        session.lock()
        wait(for: [locked], timeout: 1)
        XCTAssertFalse(session.isUnlocked)
    }

    func testRecipientMismatchStaysLocked() async {
        let store = MemoryKeyStore(identity: .generate())
        let session = session(store: store, recipient: AgeIdentity.generate().recipient)
        do {
            try await session.unlock()
            XCTFail("unlock should throw")
        } catch {
            XCTAssertEqual(error as? KeySessionError, .recipientMismatch)
        }
        XCTAssertFalse(session.isUnlocked)
    }

    func testStoreErrorsPassThrough() async {
        let store = MemoryKeyStore()
        store.error = .cancelled
        let session = session(store: store, recipient: AgeIdentity.generate().recipient)
        do {
            try await session.unlock()
            XCTFail("unlock should throw")
        } catch {
            XCTAssertEqual(error as? KeyStoreError, .cancelled)
        }
    }

    func testNotConfigured() async {
        let session = KeySession()
        do {
            try await session.unlock()
            XCTFail("unlock should throw")
        } catch {
            XCTAssertEqual(error as? KeySessionError, .notConfigured)
        }
    }

    func testBeginStartsASessionWithoutTheStore() {
        let store = MemoryKeyStore()
        let identity = AgeIdentity.generate()
        let session = session(store: store, recipient: identity.recipient)
        session.begin(with: identity)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(store.loads, 0)
    }

    func testConcurrentUnlocksShareOneLoad() async throws {
        let identity = AgeIdentity.generate()
        let store = MemoryKeyStore(identity: identity)
        store.delay = 0.1
        let session = session(store: store, recipient: identity.recipient)
        async let first: Void = session.unlock()
        async let second: Void = session.unlock()
        _ = try await (first, second)
        XCTAssertEqual(store.loads, 1, "one presence prompt")
        XCTAssertTrue(session.isUnlocked)
    }

    func testLockDuringUnlockStaysLocked() async throws {
        let identity = AgeIdentity.generate()
        let store = MemoryKeyStore(identity: identity)
        store.delay = 0.2
        let session = session(store: store, recipient: identity.recipient)
        let unlocking = Task { try await session.unlock() }
        try await Task.sleep(for: .seconds(0.05))
        session.lock()
        do {
            try await unlocking.value
            XCTFail("an unlock that was locked out must throw")
        } catch {
            XCTAssertEqual(error as? KeyStoreError, .cancelled)
        }
        XCTAssertFalse(session.isUnlocked)
    }

    func testLocksAfterIdleTime() async throws {
        let identity = AgeIdentity.generate()
        let session = session(store: MemoryKeyStore(identity: identity), recipient: identity.recipient, idle: 0.2)
        try await session.unlock()
        try await Task.sleep(for: .seconds(0.1))
        session.touch()
        try await Task.sleep(for: .seconds(0.15))
        XCTAssertTrue(session.isUnlocked, "touch restarts the timer")
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertFalse(session.isUnlocked)
    }
}
