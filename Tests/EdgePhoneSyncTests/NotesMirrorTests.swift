import XCTest
@testable import EdgePhoneSync

final class NotesMirrorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeMirror() throws -> NotesMirror {
        try NotesMirror(root: dir.appendingPathComponent("notes"), baseURL: dir.appendingPathComponent("base.json"))
    }

    func testBlobSHAMatchesGit() {
        // printf 'hello\n' | git hash-object --stdin
        XCTAssertEqual(GitBlob.sha(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func testListsNestedAndHiddenFiles() throws {
        let mirror = try makeMirror()
        try mirror.write(Data("a".utf8), to: "Note.md")
        try mirror.write(Data("b".utf8), to: "Folder/Inner.md")
        try mirror.write(Data("c".utf8), to: ".edgemark/meta.json")
        XCTAssertEqual(try mirror.paths(), [".edgemark/meta.json", "Folder/Inner.md", "Note.md"])
    }

    /// Path resolving drops `/private`, as an iPhone's app container under `/private/var` would see.
    func testListsFilesUnderPrivate() throws {
        let linked = URL(fileURLWithPath: "/private/tmp/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linked) }
        let mirror = try NotesMirror(root: linked.appendingPathComponent("notes"), baseURL: linked.appendingPathComponent("base.json"))
        try mirror.write(Data("a".utf8), to: "Folder/Note.md")
        XCTAssertEqual(try mirror.paths(), ["Folder/Note.md"])
        XCTAssertEqual(try mirror.read("Folder/Note.md"), Data("a".utf8))
    }

    func testRefusesPathsOutsideTheRoot() throws {
        let mirror = try makeMirror()
        for path in ["../evil", "a/../../evil", "/etc/evil", "a//b", "./a", ""] {
            XCTAssertThrowsError(try mirror.write(Data(), to: path), path) {
                XCTAssertEqual($0 as? SyncError, .badPath(path))
            }
        }
    }

    func testRootIsExcludedFromBackup() throws {
        let mirror = try makeMirror()
        XCTAssertEqual(try mirror.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testBaseRoundTrips() throws {
        let mirror = try makeMirror()
        XCTAssertEqual(mirror.loadBase(), SyncBase())
        var base = SyncBase()
        base.commit = "abc"
        base.blobs = ["a.md": "123"]
        try mirror.saveBase(base)
        XCTAssertEqual(mirror.loadBase(), base)
    }
}
