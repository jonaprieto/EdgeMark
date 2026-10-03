import XCTest
@testable import EdgeStorageLogic

final class GistTrashTests: XCTestCase {
    /// Files on disk per clone folder.
    private let disk: [String: [String]] = [
        "Gists/one": ["only.md"],
        "Gists/two": ["a.md", "b.py"],
        "Gists/hidden": ["shown.md", "image.png"],
    ]
    private let gists: Set<String> = ["Gists/one", "Gists/two", "Gists/hidden"]

    private func item(_ id: String, _ folder: String, _ file: String) -> GistTrash.Item<String> {
        GistTrash.Item(id: id, folder: folder, file: file)
    }

    private func plan(_ notes: [GistTrash.Item<String>], folders: [String] = [], gists: Set<String>? = nil) -> GistTrash.Plan<String> {
        GistTrash.plan(notes: notes, folders: folders, gists: gists ?? self.gists) { self.disk[$0] ?? [] }
    }

    func testGistFolder() {
        XCTAssertEqual(GistTrash.gistFolder(of: "Gists/one"), "Gists/one")
        XCTAssertEqual(GistTrash.gistFolder(of: "Gists/one/sub"), "Gists/one")
        XCTAssertNil(GistTrash.gistFolder(of: "Gists"))
        XCTAssertNil(GistTrash.gistFolder(of: "Gists/"))
        XCTAssertNil(GistTrash.gistFolder(of: "Notes/Gists/one"))
        XCTAssertNil(GistTrash.gistFolder(of: ""))
    }

    func testPlainNotesAndFoldersPassThrough() {
        let p = plan([item("n", "", "n.md"), item("w", "Work", "w.md")], folders: ["Work/Old"])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: ["n", "w"], folders: ["Work/Old"]))
    }

    func testLastFileOfAGistAsks() {
        let p = plan([item("o", "Gists/one", "only.md")])
        XCTAssertEqual(p, GistTrash.Plan(gists: ["Gists/one"], notes: [], folders: []))
    }

    func testOneFileOfSeveralIsAPlainRemoval() {
        let p = plan([item("a", "Gists/two", "a.md")])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: ["a"], folders: []))
    }

    func testEveryFileOfAGistSelectedAsksOnce() {
        let p = plan([item("a", "Gists/two", "a.md"), item("b", "Gists/two", "b.py")])
        XCTAssertEqual(p, GistTrash.Plan(gists: ["Gists/two"], notes: [], folders: []))
    }

    func testAFileEdgeMarkDoesNotShowStillCounts() {
        let p = plan([item("s", "Gists/hidden", "shown.md")])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: ["s"], folders: []))
    }

    func testCloneFolderAsksAndSwallowsItsNotes() {
        let p = plan([item("a", "Gists/two", "a.md")], folders: ["Gists/two"])
        XCTAssertEqual(p, GistTrash.Plan(gists: ["Gists/two"], notes: [], folders: []))
    }

    func testSubfolderOfAKeptGistIsAPlainFolder() {
        let p = plan([], folders: ["Gists/two/sub"])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: [], folders: ["Gists/two/sub"]))
    }

    func testGistsFolderAsksAboutEveryGistAndIsDropped() {
        let p = plan([item("x", "Gists/two", "a.md")], folders: ["Gists"])
        XCTAssertEqual(p, GistTrash.Plan(gists: ["Gists/hidden", "Gists/one", "Gists/two"], notes: [], folders: []))
    }

    func testGistsFolderWithoutKnownGistsIsAPlainFolder() {
        let p = plan([], folders: ["Gists"], gists: [])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: [], folders: ["Gists"]))
    }

    func testUnknownCloneIsTrashedNormally() {
        // A clone whose id could not be resolved is not in `gists`.
        let p = plan([item("o", "Gists/one", "only.md")], folders: ["Gists/two"], gists: ["Gists/hidden"])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: ["o"], folders: ["Gists/two"]))
    }

    func testMixedSelectionAsksPerGistAndKeepsTheRest() {
        let p = plan(
            [item("n", "", "n.md"), item("o", "Gists/one", "only.md"), item("a", "Gists/two", "a.md")],
            folders: ["Work", "Gists/hidden"],
        )
        XCTAssertEqual(p, GistTrash.Plan(gists: ["Gists/hidden", "Gists/one"], notes: ["n", "a"], folders: ["Work"]))
    }

    func testNotesDirectlyInGistsAreNotGistFiles() {
        let p = plan([item("g", "Gists", "loose.md")])
        XCTAssertEqual(p, GistTrash.Plan(gists: [], notes: ["g"], folders: []))
    }
}
