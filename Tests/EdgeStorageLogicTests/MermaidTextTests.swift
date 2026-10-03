@testable import EdgeStorageLogic
import XCTest

final class MermaidTextTests: XCTestCase {
    private func codes(_ text: String) -> [String] {
        MermaidText.blocks(in: text).map(\.code)
    }

    // MARK: - Fences

    func testBacktickFence() {
        let text = "Intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n\nAfter"
        XCTAssertEqual(codes(text), ["graph TD\n  A-->B"])
        XCTAssertNotNil(MermaidText.blocks(in: text).first?.closeLineEnd)
    }

    func testTildeFence() {
        XCTAssertEqual(codes("~~~mermaid\npie\n~~~\n"), ["pie"])
    }

    func testLongerFenceNeedsLongEnoughClose() {
        let text = "````mermaid\ngraph LR\n```\nA-->B\n````\n"
        XCTAssertEqual(codes(text), ["graph LR\n```\nA-->B"])
    }

    func testCloseMustUseSameCharacter() {
        let text = "```mermaid\ngraph LR\n~~~\n```"
        XCTAssertEqual(codes(text), ["graph LR\n~~~"])
    }

    func testIndentationUpToThreeSpaces() {
        XCTAssertEqual(codes("   ```mermaid\n   graph TD\n     A\n   ```"), ["graph TD\n  A"])
        XCTAssertEqual(codes("    ```mermaid\ngraph TD\n```"), [])
    }

    func testInfoStringWithExtraWordsAndCase() {
        XCTAssertEqual(codes("``` Mermaid title=\"x\"\npie\n```"), ["pie"])
        XCTAssertEqual(codes("```MERMAID\npie\n```"), ["pie"])
        XCTAssertEqual(codes("```mermaidjs\npie\n```"), [])
        XCTAssertEqual(codes("```js mermaid\npie\n```"), [])
    }

    func testBacktickInInfoStringIsNotAFence() {
        XCTAssertEqual(codes("```mermaid `x`\npie\n```"), [])
    }

    func testNotInsideAnotherFencedBlock() {
        let text = "````md\n```mermaid\ngraph TD\n```\n````\n\n~~~\n```mermaid\npie\n```\n~~~\n"
        XCTAssertEqual(codes(text), [])
        let after = text + "```mermaid\nflowchart LR\n```\n"
        XCTAssertEqual(codes(after), ["flowchart LR"])
    }

    func testUnclosedFenceRunsToTheEnd() {
        let text = "```mermaid\ngraph TD\nA-->B\n\n```js\nx\n"
        let blocks = MermaidText.blocks(in: text)
        XCTAssertEqual(blocks.map(\.code), ["graph TD\nA-->B\n\n```js\nx"])
        XCTAssertNil(blocks.first?.closeLineEnd)
    }

    func testCRLF() {
        XCTAssertEqual(codes("```mermaid\r\ngraph TD\r\nA-->B\r\n```\r\n"), ["graph TD\nA-->B"])
    }

    func testSeveralBlocks() {
        let text = "```mermaid\npie\n```\ntext\n```python\nx\n```\n```mermaid\ngantt\n```"
        XCTAssertEqual(codes(text), ["pie", "gantt"])
    }

    // MARK: - Cache key

    func testCacheKeyIsStableAndSensitiveToEveryPart() {
        let key = MermaidText.cacheKey(code: "pie", theme: "dark", fontFamily: "Inter", version: "11")
        XCTAssertEqual(key.count, 64)
        XCTAssertEqual(key, MermaidText.cacheKey(code: "pie", theme: "dark", fontFamily: "Inter", version: "11"))
        XCTAssertNotEqual(key, MermaidText.cacheKey(code: "pie ", theme: "dark", fontFamily: "Inter", version: "11"))
        XCTAssertNotEqual(key, MermaidText.cacheKey(code: "pie", theme: "default", fontFamily: "Inter", version: "11"))
        XCTAssertNotEqual(key, MermaidText.cacheKey(code: "pie", theme: "dark", fontFamily: "Menlo", version: "11"))
        XCTAssertNotEqual(key, MermaidText.cacheKey(code: "pie", theme: "dark", fontFamily: "Inter", version: "12"))
        // Separated parts cannot run into each other.
        XCTAssertNotEqual(
            MermaidText.cacheKey(code: "b", theme: "a", fontFamily: "", version: "1"),
            MermaidText.cacheKey(code: "", theme: "a", fontFamily: "b", version: "1"),
        )
    }

    // MARK: - Display round trip

    private let note = "# Title\n\nText\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n~~~ Mermaid\npie\n~~~\nEnd"

    func testToDisplayWrapsClosedBlocks() throws {
        let display = try XCTUnwrap(MermaidText.toDisplay(note))
        let m = MermaidText.mark
        let o = MermaidText.openMark
        XCTAssertEqual(
            display,
            "# Title\n\nText\n\n$$\(o)\n```mermaid\ngraph TD\n  A-->B\n`\(m)``\(m)$$\n\n$$\(o)\n~~~ Mermaid\npie\n~~~\(m)$$\nEnd",
        )
        XCTAssertEqual(MermaidText.fromDisplay(display), note)
    }

    func testRoundTripIsByteExact() throws {
        let samples = [
            note,
            note.replacingOccurrences(of: "\n", with: "\r\n"),
            "```mermaid\npie\n```",
            "  ```mermaid  \npie\n  ```   \n",
            "$$x$$\n\n```mermaid\npie\n```\n\n$$\ny\n$$\n",
            "```mermaid\npie \"$\" : 1\n```\n",
        ]
        for sample in samples {
            let display = try XCTUnwrap(MermaidText.toDisplay(sample), sample)
            XCTAssertEqual(MermaidText.fromDisplay(display), sample)
            XCTAssertEqual(Array(MermaidText.fromDisplay(display).utf8), Array(sample.utf8))
        }
    }

    func testNothingToWrap() {
        XCTAssertNil(MermaidText.toDisplay("plain\n```js\nx\n```"))
        XCTAssertNil(MermaidText.toDisplay("```mermaid\nunclosed"))
        // `$$` inside the diagram would end the engine's formula early.
        XCTAssertNil(MermaidText.toDisplay("```mermaid\npie \"$$\" : 1\n```"))
        // A backtick inside a backtick block would make a code span that stops the formula.
        XCTAssertNil(MermaidText.toDisplay("```mermaid\nflowchart LR\n  A[\"`**b**`\"]\n```"))
        XCTAssertNotNil(MermaidText.toDisplay("~~~mermaid\nflowchart LR\n  A[\"`**b**`\"]\n~~~"))
        // A closing run one longer than the opening would match it after the split.
        XCTAssertNil(MermaidText.toDisplay("```mermaid\npie\n````"))
        XCTAssertNotNil(MermaidText.toDisplay("```mermaid\npie\n`````"))
    }

    func testTextAlreadyHoldingTheMarkIsLeftAlone() {
        XCTAssertNil(MermaidText.toDisplay("a\u{2063}b\n```mermaid\npie\n```"))
        XCTAssertNil(MermaidText.toDisplay("a\u{2800}b\n```mermaid\npie\n```"))
        XCTAssertEqual(MermaidText.fromDisplay("plain $$ text"), "plain $$ text")
    }

    func testFromDisplayAfterEdits() {
        let m = MermaidText.mark
        let o = MermaidText.openMark
        // Typing inside the block keeps the wrapping marks; they still come off.
        XCTAssertEqual(
            MermaidText.fromDisplay("$$\(o)\n```mermaid\npie\n\"a\" : 1\n`\(m)``\(m)$$\n"),
            "```mermaid\npie\n\"a\" : 1\n```\n",
        )
        // A user `$$` next to the wrapping is kept.
        XCTAssertEqual(MermaidText.fromDisplay("$$$$\(o)\n```mermaid\npie\n```\(m)$$$$"), "$$```mermaid\npie\n```$$")
        // The line break after `$$⠀`, joined away by the user, is not taken from the fence.
        XCTAssertEqual(MermaidText.fromDisplay("$$\(o)```mermaid\npie\n```\(m)$$"), "```mermaid\npie\n```")
        // Marks whose `$$` was deleted are removed alone.
        XCTAssertEqual(MermaidText.fromDisplay("\(o)\n```mermaid\npie\n```\(m)"), "\n```mermaid\npie\n```")
    }

    func testCodeFromDisplayContent() {
        let m = MermaidText.mark
        let o = MermaidText.openMark
        XCTAssertEqual(MermaidText.code(fromDisplayContent: "\(o)\n```mermaid\ngraph TD\n  A-->B\n`\(m)``\(m)"), "graph TD\n  A-->B")
        XCTAssertEqual(MermaidText.code(fromDisplayContent: "\(o)\n  ~~~mermaid x\npie\n  ~~~   \(m)"), "pie")
        XCTAssertNil(MermaidText.code(fromDisplayContent: "x^2"))
        XCTAssertNil(MermaidText.code(fromDisplayContent: "\(o)\n```js\npie\n```\(m)"))
        XCTAssertNil(MermaidText.code(fromDisplayContent: "\(o)\n```mermaid\npie\(m)"))
    }

    func testDisplayContentMatchesBlockCode() throws {
        // The editor renders from the formula content; previews and export from the note.
        // Both must produce the same code, hence the same cache key.
        let display = try XCTUnwrap(MermaidText.toDisplay(note))
        let parts = display.components(separatedBy: "$$")
        XCTAssertEqual(parts.count, 5)
        let fromDisplay = [parts[1], parts[3]].map {
            MermaidText.code(fromDisplayContent: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(fromDisplay, codes(note))
    }
}
