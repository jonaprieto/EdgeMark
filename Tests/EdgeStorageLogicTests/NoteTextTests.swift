import XCTest
@testable import EdgeStorageLogic

final class NoteTextTests: XCTestCase {
    private let legacy = """
    ---
    id: 4F1C2A3B-0D9E-4A7B-8C6D-112233445566
    title: Old Note
    created: 2025-01-01T10:00:00Z
    modified: 2025-01-02T10:00:00Z
    tags: [red, blue]
    ---

    # Old Note

    Body.
    """

    // MARK: - Front matter

    func testLegacyEdgeMarkBlockIsStripped() {
        let parsed = NoteText.legacyFrontMatter(legacy)
        XCTAssertEqual(parsed?.metadata["title"], "Old Note")
        XCTAssertEqual(parsed?.metadata["tags"], "[red, blue]")
        XCTAssertEqual(parsed?.body, "# Old Note\n\nBody.")
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(legacy), "# Old Note\n\nBody.")
    }

    func testLegacyBlockWithCRLFIsStripped() {
        let crlf = legacy.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(crlf), "# Old Note\r\n\r\nBody.")
    }

    func testCustomYAMLIsPreserved() {
        let text = "---\ntitle: Mine\nauthor: Ana\nfolder: Elsewhere\n---\n\n# Mine\n"
        XCTAssertNil(NoteText.legacyFrontMatter(text))
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(text), text)
    }

    func testIdThatIsNotAUUIDIsPreserved() {
        let text = "---\nid: my-post\n---\nbody"
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(text), text)
    }

    func testHorizontalRuleIsPreserved() {
        let text = "---\n\nSome prose after a rule.\n"
        XCTAssertNil(NoteText.frontMatter(text))
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(text), text)
    }

    func testRuleThenProseThenRuleIsPreserved() {
        let text = "---\nFirst paragraph.\n\n---\nSecond paragraph.\n"
        XCTAssertEqual(NoteText.strippingLegacyFrontMatter(text), text)
        XCTAssertEqual(NoteText.title(from: text), "---")
    }

    func testGenericFrontMatterStillParsesFolderMetadata() {
        let meta = "---\ntrashedAt: 2025-01-01T10:00:00Z\noriginalPath: Work/Projects\n---"
        XCTAssertEqual(NoteText.frontMatter(meta)?.metadata["originalPath"], "Work/Projects")
    }

    func testUnclosedBlockIsNotFrontMatter() {
        XCTAssertNil(NoteText.frontMatter("---\nid: 4F1C2A3B-0D9E-4A7B-8C6D-112233445566\n"))
        XCTAssertNil(NoteText.frontMatter("---"))
        XCTAssertNil(NoteText.frontMatter(""))
    }

    // MARK: - First line and title

    func testFirstLineOfLFCRLFAndCR() {
        XCTAssertEqual(NoteText.firstLine("# A\nb"), "# A")
        XCTAssertEqual(NoteText.firstLine("# A\r\nb\r\n"), "# A")
        XCTAssertEqual(NoteText.firstLine("# A\rb"), "# A")
        XCTAssertEqual(NoteText.firstLine("only"), "only")
    }

    func testFirstLineOfEmptyText() {
        XCTAssertEqual(NoteText.firstLine(""), "")
        XCTAssertEqual(NoteText.firstLine("\r\nrest"), "")
    }

    func testTitleFromHeading() {
        XCTAssertEqual(NoteText.title(from: "# 17 CRLF\r\n\r\nBody\r\n"), "17 CRLF")
        XCTAssertEqual(NoteText.title(from: "## Plain\nx"), "Plain")
        XCTAssertEqual(NoteText.title(from: ""), "Untitled")
        XCTAssertEqual(NoteText.title(from: "#"), "Untitled")
    }

    func testTitleSkipsYAML() {
        XCTAssertEqual(NoteText.title(from: "---\ntitle: \"From YAML\"\n---\n# Heading\n"), "From YAML")
        XCTAssertEqual(NoteText.title(from: "---\nauthor: Ana\ntags:\n  - a\n---\n# Heading\n"), "Heading")
    }
}
