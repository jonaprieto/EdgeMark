import XCTest
@testable import EdgeStorageLogic

final class FrontMatterDisplayTests: XCTestCase {
    private let mark = String(NoteText.frontMatterMark)

    private func assertRoundTrip(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let display = NoteText.frontMatterToDisplay(text) else {
            return XCTFail("expected a front matter block", file: file, line: line)
        }
        XCTAssertEqual(NoteText.frontMatterFromDisplay(display), text, file: file, line: line)
        XCTAssertEqual(Array(NoteText.frontMatterFromDisplay(display).utf8), Array(text.utf8), file: file, line: line)
    }

    func testTitleBlockIsMarked() {
        let text = "---\ntitle: On planarity of univalent graphs\n---\n\nBody.\n"
        XCTAssertEqual(
            NoteText.frontMatterToDisplay(text),
            "\(mark)---\ntitle: On planarity of univalent graphs\n\(mark)---\n\nBody.\n",
        )
        assertRoundTrip(text)
    }

    func testDotsCloseTheBlock() {
        let text = "---\ntitle: X\n...\nBody"
        XCTAssertEqual(NoteText.frontMatterToDisplay(text), "\(mark)---\ntitle: X\n\(mark)...\nBody")
        assertRoundTrip(text)
    }

    func testCorpusBlockWithListsCommentsAndBlanks() {
        let text = """
        ---
        title: 07 Front Matter
        author: Ada Lovelace
        tags: [red, blue]
        # a comment
        aliases:
          - one
        - two

        "quoted key": yes
        created: 2026-01-01T00:00:00Z
        ---
        # 07 Front Matter

        ---
        Note: this colon line sits between two rules.
        ---
        """
        let display = NoteText.frontMatterToDisplay(text)
        XCTAssertEqual(display?.filter { $0 == NoteText.frontMatterMark }.count, 2)
        assertRoundTrip(text)
    }

    func testCRLFAndTrailingSpacesRoundTrip() {
        assertRoundTrip("---  \r\ntitle: X\r\n---\t\r\nBody\r\n")
        assertRoundTrip("---\ntitle: X\n---")
    }

    func testRuleFollowedByProseIsNotFrontMatter() {
        XCTAssertNil(NoteText.frontMatterToDisplay("---\nSome prose here.\n---\n"))
        XCTAssertNil(NoteText.frontMatterToDisplay("---\n\nNote that: this is prose\n---\n"))
    }

    func testLoneRuleAndUnclosedBlockAreNotFrontMatter() {
        XCTAssertNil(NoteText.frontMatterToDisplay("---\n"))
        XCTAssertNil(NoteText.frontMatterToDisplay("---\n\nBody"))
        XCTAssertNil(NoteText.frontMatterToDisplay("---\ntitle: X\nBody"))
        XCTAssertNil(NoteText.frontMatterToDisplay("----\ntitle: X\n----\n"))
        XCTAssertNil(NoteText.frontMatterToDisplay("---\n---\nBody"))
    }

    func testBlockMustStartTheNote() {
        XCTAssertNil(NoteText.frontMatterToDisplay("\n---\ntitle: X\n---\n"))
        XCTAssertNil(NoteText.frontMatterToDisplay("# Title\n\n---\ntitle: X\n---\n"))
    }

    func testTextAlreadyHoldingTheMarkIsLeftAlone() {
        XCTAssertNil(NoteText.frontMatterToDisplay("---\ntitle: X\n---\nA\(mark)B"))
    }

    func testEditsAroundTheMarksStillRoundTrip() {
        let display = "x\(mark)---\ntitle: Y\n\(mark)---\nBody"
        XCTAssertEqual(NoteText.frontMatterFromDisplay(display), "x---\ntitle: Y\n---\nBody")
        XCTAssertEqual(NoteText.frontMatterFromDisplay("plain"), "plain")
    }
}
