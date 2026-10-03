import XCTest
@testable import EdgeStorageLogic

final class NoteComplexityTests: XCTestCase {
    private func lines(_ line: String, count: Int) -> String {
        Array(repeating: line, count: count).joined(separator: "\n")
    }

    func testOrdinaryNotesAreLight() {
        XCTAssertFalse(NoteComplexity.isHeavy(""))
        XCTAssertFalse(NoteComplexity.isHeavy("# Title\n\nSome **bold** text, $x^2$ and [a link](https://example.com).\n> quote\n"))
    }

    func testTotalSizeBoundary() {
        // Short lines so only the size limit applies.
        let line = String(repeating: "a", count: 1023) + "\n"
        let atLimit = String(repeating: line, count: 400)
        XCTAssertEqual(atLimit.utf8.count, NoteComplexity.maxBytes)
        XCTAssertFalse(NoteComplexity.isHeavy(atLimit))
        XCTAssertTrue(NoteComplexity.isHeavy(atLimit + "a"))
    }

    func testLineLengthBoundary() {
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "a", count: 20000)))
        XCTAssertTrue(NoteComplexity.isHeavy(String(repeating: "a", count: 20001)))
        // Counted per line: two lines at the limit are fine.
        let two = String(repeating: "a", count: 20000) + "\r\n" + String(repeating: "b", count: 20000)
        XCTAssertFalse(NoteComplexity.isHeavy(two))
        // Characters, not bytes: 20,000 two-byte letters are at the limit.
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "\u{E9}", count: 20000)))
    }

    func testQuoteDepthBoundary() {
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: ">", count: 100) + " deep"))
        XCTAssertTrue(NoteComplexity.isHeavy(String(repeating: ">", count: 101) + " deep"))
        XCTAssertTrue(NoteComplexity.isHeavy(String(repeating: "> ", count: 101) + "deep"))
        // `>` after text is not a quote marker.
        XCTAssertFalse(NoteComplexity.isHeavy("a " + String(repeating: ">", count: 200)))
    }

    func testDollarSignBoundary() {
        XCTAssertFalse(NoteComplexity.isHeavy(lines("$x$", count: 500)))
        XCTAssertTrue(NoteComplexity.isHeavy(lines("$x$", count: 500) + "$"))
    }

    func testBracketAndParenRunBoundary() {
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "[", count: 499)))
        XCTAssertTrue(NoteComplexity.isHeavy(String(repeating: "[", count: 500)))
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "(", count: 499)))
        XCTAssertTrue(NoteComplexity.isHeavy(String(repeating: "(", count: 500)))
        // Runs are consecutive and per line.
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "[a", count: 600)))
        XCTAssertFalse(NoteComplexity.isHeavy(String(repeating: "[", count: 300) + "\n" + String(repeating: "[", count: 300)))
    }

    func testTwoMegabyteLineIsCheckedQuickly() {
        let huge = "# Huge\n\n" + String(repeating: "lorem **bold** `code` [x](y) $z$ ", count: 62000)
        XCTAssertGreaterThan(huge.utf8.count, 2_000_000)
        let start = Date()
        XCTAssertTrue(NoteComplexity.isHeavy(huge))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    func testJustUnderSizeLimitWithLongScanIsQuick() {
        // Worst case for the scan itself: nothing trips until the end.
        let text = String(repeating: String(repeating: "a", count: 1000) + "\n", count: 400)
        let start = Date()
        XCTAssertFalse(NoteComplexity.isHeavy(text))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }
}
