import XCTest
@testable import EdgeSync

final class GistCatalogTests: XCTestCase {
    func testParsesAccountsFromAuthStatus() {
        let text = """
        github.com
          ✓ Logged in to github.com account jonaprieto (keyring)
          - Active account: true
          ✓ Logged in to github.com account jonadc (keyring)
        """
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), ["jonaprieto", "jonadc"])
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: "You are not logged into any GitHub hosts."), [])
    }

    func testDirectoryName() {
        XCTAssertEqual(GistCatalog.directoryName(description: "Agda: graph lemmas (draft)", id: "abc123"), "Agda-graph-lemmas-draft")
        XCTAssertEqual(GistCatalog.directoryName(description: "", id: "abc123"), "abc123")
        XCTAssertEqual(GistCatalog.directoryName(description: "   ", id: "abc123"), "abc123")
        XCTAssertEqual(GistCatalog.directoryName(description: ".hidden", id: "abc123"), "hidden")
        XCTAssertLessThanOrEqual(GistCatalog.directoryName(description: String(repeating: "x", count: 500), id: "id").utf8.count, 100)
    }

    func testGistIDFromOrigin() {
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "https://jonaprieto@gist.github.com/0c5db1061f0d4dc8873fda4.git"), "0c5db1061f0d4dc8873fda4")
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "git@gist.github.com:0c5db1061f0d4dc8873fda4.git"), "0c5db1061f0d4dc8873fda4")
        XCTAssertNil(GistCatalog.gistID(fromOrigin: "https://github.com/jonaprieto/notes.git"))
    }

    func testParsesGistLines() {
        let ndjson = """
        {"id":"a1","description":"First","html_url":"https://gist.github.com/jonaprieto/a1","files":["README.md"]}
        {"id":"b2","description":null,"html_url":"https://gist.github.com/jonaprieto/b2","files":["x.agda","notes.md"]}

        """
        let gists = GistCatalog.parseGistLines(ndjson)
        XCTAssertEqual(gists.count, 2)
        XCTAssertEqual(gists[0], Gist(id: "a1", description: "First", htmlURL: "https://gist.github.com/jonaprieto/a1", files: ["README.md"]))
        XCTAssertEqual(gists[1].description, "")
        XCTAssertEqual(gists[1].files, ["x.agda", "notes.md"])
    }

    func testGistIDFromCreateOutput() {
        XCTAssertEqual(GistCatalog.gistID(fromCreateOutput: "- Creating gist note.md\n✓ Created secret gist note.md\nhttps://gist.github.com/9f8e7d6c5b4a\n"), "9f8e7d6c5b4a")
        XCTAssertEqual(GistCatalog.gistID(fromCreateOutput: "https://gist.github.com/jonaprieto/9f8e7d6c5b4a"), "9f8e7d6c5b4a")
        XCTAssertNil(GistCatalog.gistID(fromCreateOutput: "error"))
    }

    func testAnchorAndWebURL() {
        XCTAssertEqual(GistCatalog.anchor(forFile: "My Note (v2).md"), "file-my-note-v2-md")
        XCTAssertEqual(
            GistCatalog.webURL(account: "jonaprieto", id: "a1", file: nil).absoluteString,
            "https://gist.github.com/jonaprieto/a1",
        )
        XCTAssertEqual(
            GistCatalog.webURL(account: "jonaprieto", id: "a1", file: "notes.md").absoluteString,
            "https://gist.github.com/jonaprieto/a1#file-notes-md",
        )
        XCTAssertEqual(GistCatalog.cloneURL(account: "jonaprieto", id: "a1"), "https://jonaprieto@gist.github.com/a1.git")
    }

    func testWebURLWithoutAccount() {
        XCTAssertEqual(
            GistCatalog.webURL(account: nil, id: "a1", file: "notes.md").absoluteString,
            "https://gist.github.com/a1#file-notes-md",
        )
    }
}
