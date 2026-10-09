import XCTest
@testable import EdgeCrypto

@MainActor
final class EncryptedFileTests: XCTestCase {
    private var dir: URL!
    private let identity = AgeIdentity.generate()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadRejectsPayloadThatIsNotUTF8() throws {
        let url = dir.appendingPathComponent("Binary.md.age")
        try Data(Age.encrypt(Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]), to: identity.recipient).utf8).write(to: url)
        XCTAssertThrowsError(try EncryptedFile.read(at: url, identity: identity)) { error in
            XCTAssertEqual(error as? AgeError, .corruptPayload)
        }
    }

    func testWriteSkipsUnchangedText() throws {
        let url = dir.appendingPathComponent("Note.md.age")
        XCTAssertTrue(try EncryptedFile.write("# One\n", to: url, recipient: identity.recipient, identity: identity))
        let first = try Data(contentsOf: url)
        XCTAssertFalse(try EncryptedFile.write("# One\n", to: url, recipient: identity.recipient, identity: identity))
        XCTAssertEqual(try Data(contentsOf: url), first, "same text must not be sealed again")
        XCTAssertTrue(try EncryptedFile.write("# Two\n", to: url, recipient: identity.recipient, identity: identity))
        XCTAssertEqual(try EncryptedFile.read(at: url, identity: identity), "# Two\n")
    }

    func testWriteAfterReadSkipsToo() throws {
        let url = dir.appendingPathComponent("Read.md.age")
        try Data(Age.encrypt(Data("body".utf8), to: identity.recipient).utf8).write(to: url)
        XCTAssertEqual(try EncryptedFile.read(at: url, identity: identity), "body")
        XCTAssertFalse(try EncryptedFile.write("body", to: url, recipient: identity.recipient, identity: identity))
    }

    func testWriteRestoresDeletedFile() throws {
        let url = dir.appendingPathComponent("Gone.md.age")
        try EncryptedFile.write("x", to: url, recipient: identity.recipient, identity: identity)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try EncryptedFile.write("x", to: url, recipient: identity.recipient, identity: identity))
    }

    /// A note retitled and then retitled back: the file moves away and returns holding
    /// other text, so what was last written to this path says nothing about its content.
    func testWriteAfterTheFileWasMovedAwayAndBack() throws {
        let a = dir.appendingPathComponent("A.md.age")
        let b = dir.appendingPathComponent("B.md.age")
        try EncryptedFile.write("# A\nbody", to: a, recipient: identity.recipient, identity: identity)
        try FileManager.default.moveItem(at: a, to: b)
        try EncryptedFile.write("# B\n", to: b, recipient: identity.recipient, identity: identity)
        try FileManager.default.moveItem(at: b, to: a)
        XCTAssertTrue(try EncryptedFile.write("# A\nbody", to: a, recipient: identity.recipient, identity: identity))
        XCTAssertEqual(try EncryptedFile.read(at: a, identity: identity), "# A\nbody")
    }

    func testWriteReplacesAFileItCannotRead() throws {
        let url = dir.appendingPathComponent("Broken.md.age")
        try EncryptedFile.write("text", to: url, recipient: identity.recipient, identity: identity)
        try Data("not an age file".utf8).write(to: url)
        XCTAssertTrue(try EncryptedFile.write("text", to: url, recipient: identity.recipient, identity: identity))
        XCTAssertEqual(try EncryptedFile.read(at: url, identity: identity), "text")
    }

    func testWriteWithoutAnIdentityAlwaysSeals() throws {
        let url = dir.appendingPathComponent("Locked.md.age")
        XCTAssertTrue(try EncryptedFile.write("old", to: url, recipient: identity.recipient, identity: nil))
        XCTAssertTrue(try EncryptedFile.write("edit", to: url, recipient: identity.recipient, identity: nil))
        XCTAssertEqual(try EncryptedFile.read(at: url, identity: identity), "edit")
    }

    func testSealAndUnseal() throws {
        let plain = dir.appendingPathComponent("Title.md")
        try Data("# Title\n".utf8).write(to: plain)
        let sealed = try EncryptedFile.seal("# Title\n", at: plain, recipient: identity.recipient, identity: identity)
        XCTAssertEqual(sealed.lastPathComponent, "Title.md.age")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertEqual(try EncryptedFile.read(at: sealed, identity: identity), "# Title\n")
        let back = try EncryptedFile.unseal("# Title\n", at: sealed)
        XCTAssertEqual(back, plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.path))
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "# Title\n")
    }

    func testSealKeepsPlaintextWhenReadBackFails() throws {
        let plain = dir.appendingPathComponent("Keep.md")
        try Data("secret".utf8).write(to: plain)
        // The recipient belongs to another key, so the read-back cannot decrypt.
        let other = AgeIdentity.generate().recipient
        XCTAssertThrowsError(try EncryptedFile.seal("secret", at: plain, recipient: other, identity: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathExtension("age").path))
    }

    func testSealRefusesExistingTarget() throws {
        let plain = dir.appendingPathComponent("Taken.md")
        try Data("a".utf8).write(to: plain)
        try Data("other".utf8).write(to: plain.appendingPathExtension("age"))
        XCTAssertThrowsError(try EncryptedFile.seal("a", at: plain, recipient: identity.recipient, identity: identity))
        XCTAssertEqual(try String(contentsOf: plain.appendingPathExtension("age"), encoding: .utf8), "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
    }

    func testUnsealRefusesAFileThatIsNotEncrypted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("Title.md")
        try Data("text".utf8).write(to: plain)
        XCTAssertThrowsError(try EncryptedFile.unseal("text", at: plain))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Title").path))
    }
}
