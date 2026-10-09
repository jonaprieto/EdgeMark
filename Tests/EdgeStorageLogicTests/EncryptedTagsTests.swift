import XCTest
@testable import EdgeStorageLogic

final class EncryptedTagsTests: XCTestCase {
    func testNoTagsLeavesTextAlone() {
        XCTAssertEqual(EncryptedTags.embed([], in: "# Title\nbody"), "# Title\nbody")
        let parts = EncryptedTags.extract(from: "# Title\nbody")
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(parts.text, "# Title\nbody")
    }

    func testOneTagRoundTrip() {
        let payload = EncryptedTags.embed(["red"], in: "# Title\nbody")
        XCTAssertEqual(payload, "<!-- edgemark-tags: red -->\n# Title\nbody")
        let parts = EncryptedTags.extract(from: payload)
        XCTAssertEqual(parts.tags, ["red"])
        XCTAssertEqual(parts.text, "# Title\nbody")
    }

    func testSeveralTagsRoundTrip() {
        let payload = EncryptedTags.embed(["red", "blue", "green"], in: "text")
        XCTAssertEqual(payload, "<!-- edgemark-tags: red, blue, green -->\ntext")
        let parts = EncryptedTags.extract(from: payload)
        XCTAssertEqual(parts.tags, ["red", "blue", "green"])
        XCTAssertEqual(parts.text, "text")
    }

    func testMarkerOnLaterLineIsLeftAlone() {
        let text = "# Title\n<!-- edgemark-tags: red -->\nmore"
        let parts = EncryptedTags.extract(from: text)
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(parts.text, text)
    }

    func testOrdinaryCommentOnFirstLineIsLeftAlone() {
        let text = "<!-- a note to self -->\n# Title"
        let parts = EncryptedTags.extract(from: text)
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(parts.text, text)
    }

    func testCRLFAfterTagLine() {
        let parts = EncryptedTags.extract(from: "<!-- edgemark-tags: red, blue -->\r\n# Title\r\nbody")
        XCTAssertEqual(parts.tags, ["red", "blue"])
        XCTAssertEqual(parts.text, "# Title\r\nbody")
    }

    func testEmptyTextWithTags() {
        let payload = EncryptedTags.embed(["red"], in: "")
        let parts = EncryptedTags.extract(from: payload)
        XCTAssertEqual(parts.tags, ["red"])
        XCTAssertEqual(parts.text, "")
    }

    func testTextThatStartsWithATagShapedLine() {
        let text = "<!-- edgemark-tags: blue -->\n# Title"
        let parts = EncryptedTags.extract(from: EncryptedTags.embed(["red"], in: text))
        XCTAssertEqual(parts.tags, ["red"])
        XCTAssertEqual(parts.text, text)
    }

    func testTagShapedTextWithoutTagsSurvives() {
        let text = "<!-- edgemark-tags: blue -->\n# Title"
        let parts = EncryptedTags.extract(from: EncryptedTags.embed([], in: text))
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(parts.text, text)
    }

    func testTagLineWithoutNewlineIsLeftAlone() {
        let text = "<!-- edgemark-tags: red -->"
        let parts = EncryptedTags.extract(from: text)
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(parts.text, text)
    }
}
