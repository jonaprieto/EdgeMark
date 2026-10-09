import XCTest
@testable import EdgeStorageLogic

final class EncryptedFileNameTests: XCTestCase {
    func testDetection() {
        XCTAssertTrue(EncryptedFileName.isEncrypted("Title.md.age"))
        XCTAssertTrue(EncryptedFileName.isEncrypted("script.py.age"))
        XCTAssertFalse(EncryptedFileName.isEncrypted("Title.md"))
        XCTAssertFalse(EncryptedFileName.isEncrypted(".age"))
        XCTAssertFalse(EncryptedFileName.isEncrypted("page"))
        XCTAssertTrue(EncryptedFileName.isEncryptedMarkdown("Title.md.age"))
        XCTAssertFalse(EncryptedFileName.isEncryptedMarkdown("script.py.age"))
        XCTAssertFalse(EncryptedFileName.isEncryptedMarkdown("Title.md"))
    }

    func testPlainNameAndStem() {
        XCTAssertEqual(EncryptedFileName.plainName("Title.md.age"), "Title.md")
        XCTAssertEqual(EncryptedFileName.plainName("Title.md"), "Title.md")
        XCTAssertEqual(EncryptedFileName.plainName("data.json.age"), "data.json")
        XCTAssertEqual(EncryptedFileName.stem("Title.md.age"), "Title")
        XCTAssertEqual(EncryptedFileName.stem("Title.md"), "Title")
        XCTAssertEqual(EncryptedFileName.stem("v1.2.md.age"), "v1.2")
        XCTAssertEqual(EncryptedFileName.stem("v1.2.md"), "v1.2")
    }

    func testLockedTitle() {
        XCTAssertEqual(EncryptedFileName.lockedTitle(fileName: "My-Note.md.age", inTrash: false), "My-Note")
        let id = "4F1C2A3B-0D9E-4A7B-8C6D-112233445566"
        XCTAssertEqual(EncryptedFileName.lockedTitle(fileName: "\(id)_My-Note.md.age", inTrash: true), "My-Note")
        XCTAssertEqual(EncryptedFileName.lockedTitle(fileName: "\(id)_My-Note.md.age", inTrash: false), "\(id)_My-Note")
        XCTAssertEqual(EncryptedFileName.lockedTitle(fileName: "Plain.md.age", inTrash: true), "Plain")
    }
}
