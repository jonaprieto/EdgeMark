import XCTest
@testable import EdgeCrypto

final class EncryptionSettingsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let suite = "EncryptionSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EncryptionSettings(defaults: defaults)
        XCTAssertFalse(settings.isSetUp)
        XCTAssertEqual(settings.store, .keychain)
        XCTAssertEqual(settings.idleMinutes, 10)
        XCTAssertTrue(settings.lockOnLeave, "leaving an encrypted note locks unless turned off")
        settings.lockOnLeave = false
        XCTAssertFalse(EncryptionSettings(defaults: defaults).lockOnLeave)
        settings.recipient = TestKeys.recipientString
        settings.store = .protonPass
        settings.keyURI = "pass://abc/EdgeMark encryption key"
        settings.idleMinutes = 5
        let reloaded = EncryptionSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isSetUp)
        XCTAssertEqual(reloaded.ageRecipient?.string, TestKeys.recipientString)
        XCTAssertEqual(reloaded.store, .protonPass)
        XCTAssertEqual(reloaded.keyURI, "pass://abc/EdgeMark encryption key")
        XCTAssertEqual(reloaded.idleMinutes, 5)
    }

    func testGarbageRecipientIsNotSetUp() {
        let suite = "EncryptionSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EncryptionSettings(defaults: defaults)
        settings.recipient = "age1notakey"
        XCTAssertFalse(settings.isSetUp)
    }
}
