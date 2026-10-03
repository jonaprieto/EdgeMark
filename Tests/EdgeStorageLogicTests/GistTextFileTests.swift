import XCTest
@testable import EdgeStorageLogic

final class GistTextFileTests: XCTestCase {
    private func text(_ name: String, _ s: String) -> Bool {
        GistTextFile.isEditableText(name: name, data: Data(s.utf8))
    }

    func testSourceFilesAreText() {
        for name in ["Graph.agda", "Main.lean", "mix.exs", "Token.sol", "mod.rs", "run.py", "data.json", "notes.txt", "LICENSE", "Makefile", "x.unknownext"] {
            XCTAssertTrue(text(name, "line one\r\nline two\tok\n"), name)
        }
    }

    func testMarkdownDotFilesAndBinaryExtensionsAreNot() {
        XCTAssertFalse(text("README.md", "# hi\n"))
        XCTAssertFalse(text(".gitignore", "*.o\n"))
        XCTAssertFalse(text(".DS_Store", "x"))
        XCTAssertFalse(text("logo.png", "looks like text"))
        XCTAssertFalse(text("", "x"))
    }

    func testBinaryBytesAreNot() {
        XCTAssertFalse(GistTextFile.isEditableText(name: "a.rs", data: Data([0x66, 0x00, 0x6E])))
        XCTAssertFalse(GistTextFile.isEditableText(name: "a.txt", data: Data([0xFF, 0xFE, 0x41])))
        XCTAssertFalse(GistTextFile.isEditableText(name: "blob", data: Data([0x41, 0x01, 0x42])))
        // A known text extension tolerates control characters such as an escape.
        XCTAssertTrue(GistTextFile.isEditableText(name: "build.log", data: Data([0x1B, 0x5B, 0x30, 0x6D, 0x0A])))
        XCTAssertTrue(text("empty.py", ""))
    }

    func testSizeLimit() {
        let atLimit = Data(repeating: 0x61, count: GistTextFile.maxBytes)
        XCTAssertTrue(GistTextFile.isEditableText(name: "big.txt", data: atLimit))
        XCTAssertFalse(GistTextFile.isEditableText(name: "big.txt", data: atLimit + Data([0x61])))
    }

    func testReadsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.lean")
        try Data("theorem t : True := trivial\n".utf8).write(to: good)
        XCTAssertTrue(GistTextFile.isEditableText(at: good))
        let bad = dir.appendingPathComponent("b.lean")
        try Data([0x00, 0x01]).write(to: bad)
        XCTAssertFalse(GistTextFile.isEditableText(at: bad))
        XCTAssertFalse(GistTextFile.isEditableText(at: dir.appendingPathComponent("missing.lean")))
    }

    func testDecodeRoundTripsBytes() {
        for bytes in [[0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A, 0x62], [0x61, 0x0D, 0x0A], [0x61, 0x0A, 0x0A], [0x61], []] as [[UInt8]] {
            let text = GistTextFile.decode(Data(bytes))
            XCTAssertEqual(text.map { Array(Data($0.utf8)) }, bytes)
        }
        XCTAssertNil(GistTextFile.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])))
    }

    func testRenamedFileNameKeepsTheExtension() {
        XCTAssertEqual(GistTextFile.renamedFileName(typed: "solver", keepingExtension: "py"), "solver.py")
        XCTAssertEqual(GistTextFile.renamedFileName(typed: " solver.py ", keepingExtension: "py"), "solver.py")
        XCTAssertEqual(GistTextFile.renamedFileName(typed: "Solver.PY", keepingExtension: "py"), "Solver.PY")
        XCTAssertEqual(GistTextFile.renamedFileName(typed: "solver.rs", keepingExtension: "py"), "solver.rs.py")
        XCTAssertEqual(GistTextFile.renamedFileName(typed: "notes", keepingExtension: "md"), "notes.md")
        XCTAssertEqual(GistTextFile.renamedFileName(typed: "COPYING", keepingExtension: ""), "COPYING")
    }

    func testRenamedFileNameRejectsBadNames() {
        for typed in ["", "   ", ".hidden", "a/b", "a:b", "tab\there", String(repeating: "x", count: 300)] {
            XCTAssertNil(GistTextFile.renamedFileName(typed: typed, keepingExtension: "md"), typed)
        }
    }
}
