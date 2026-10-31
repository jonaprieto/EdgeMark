import XCTest
@testable import EdgePhoneSync

final class TreeSyncTests: XCTestCase {
    private var dir: URL!
    private var mirror: NotesMirror!
    private let noon = Date(timeIntervalSince1970: 1_793_448_000)

    override func setUpWithError() throws {
        FakeGitHub.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mirror = try NotesMirror(root: dir.appendingPathComponent("notes"), baseURL: dir.appendingPathComponent("base.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func sync(hold: @escaping TreeSync.Hold = { _ in [:] }) async throws -> SyncReport {
        let date = noon
        return try await TreeSync(repo: FakeGitHub.repo, mirror: mirror, hold: hold, now: { date }).run()
    }

    private func text(_ path: String) throws -> String {
        try String(decoding: mirror.read(path), as: UTF8.self)
    }

    private func edit(_ path: String, _ text: String) throws {
        try mirror.write(Data(text.utf8), to: path)
    }

    private var day: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: noon)
    }

    func testFirstSyncDownloadsEverything() async throws {
        FakeGitHub.push(["Note.md": "# Note\n", "Folder/Inner.md": "# Inner\n", ".edgemark/meta.json": "{}"])
        let report = try await sync()
        XCTAssertEqual(report.pulled, 3)
        XCTAssertEqual(try text("Folder/Inner.md"), "# Inner\n")
    }

    func testLocalEditMakesOneCommitThenNothing() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        try await sync()
        try edit("Note.md", "# Note\n\nfrom the phone\n")
        try edit("New.md", "# New\n")
        let report = try await sync()
        XCTAssertEqual(report.pushed, 2)
        XCTAssertEqual(FakeGitHub.files["Note.md"], "# Note\n\nfrom the phone\n")
        XCTAssertEqual(FakeGitHub.files["New.md"], "# New\n")
        XCTAssertTrue(FakeGitHub.with { $0.commits[$0.head]!.message }.hasPrefix("notes: phone \(day) "))

        let writes = FakeGitHub.with { $0.writes }
        try await sync()
        XCTAssertEqual(FakeGitHub.with { $0.writes }, writes)
    }

    func testRemoteEditAndDeleteArrive() async throws {
        FakeGitHub.push(["Note.md": "# Note\n", "Gone.md": "# Gone\n"])
        try await sync()
        FakeGitHub.push(["Note.md": "# Note\n\nfrom the mac\n", "Gone.md": nil])
        try await sync()
        XCTAssertEqual(try text("Note.md"), "# Note\n\nfrom the mac\n")
        XCTAssertFalse(mirror.exists("Gone.md"))
    }

    func testEditsOnBothSidesMerge() async throws {
        FakeGitHub.push(["Note.md": "one\ntwo\nthree\nfour\n"])
        try await sync()
        try edit("Note.md", "ONE\ntwo\nthree\nfour\n")
        FakeGitHub.push(["Note.md": "one\ntwo\nthree\nFOUR\n"])
        let report = try await sync()
        XCTAssertEqual(report.conflicts, [])
        XCTAssertEqual(try text("Note.md"), "ONE\ntwo\nthree\nFOUR\n")
        XCTAssertEqual(FakeGitHub.files["Note.md"], "ONE\ntwo\nthree\nFOUR\n")
    }

    func testOverlappingEditsKeepBothTexts() async throws {
        FakeGitHub.push(["Folder/Note.md": "# Note\nline\n"])
        try await sync()
        try edit("Folder/Note.md", "# Note\nmine\n")
        FakeGitHub.push(["Folder/Note.md": "# Note\ntheirs\n"])
        let report = try await sync()

        let copy = "Folder/Note-phone-conflict-\(day).md"
        XCTAssertEqual(report.conflicts, [copy])
        XCTAssertEqual(try text("Folder/Note.md"), "# Note\ntheirs\n")
        XCTAssertEqual(FakeGitHub.files["Folder/Note.md"], "# Note\ntheirs\n")
        XCTAssertEqual(FakeGitHub.files[copy], "# Note (phone conflict \(day))\nmine\n")
    }

    func testSecondConflictTheSameDayGetsItsOwnCopy() async throws {
        FakeGitHub.push(["Note.md": "a\n"])
        try await sync()
        try edit("Note.md", "mine\n")
        FakeGitHub.push(["Note.md": "theirs\n"])
        try await sync()
        try edit("Note.md", "mine again\n")
        FakeGitHub.push(["Note.md": "theirs again\n"])
        let report = try await sync()
        XCTAssertEqual(report.conflicts, ["Note-phone-conflict-\(day)-2.md"])
    }

    func testADayStartedOnBothDevicesMerges() async throws {
        FakeGitHub.push(["Note.md": "a\n"])
        try await sync()
        try edit("Journal/2026-10-31.md", "# 2026-10-31\n\n## Meals\n\n- 09:00 phone\n")
        FakeGitHub.push(["Journal/2026-10-31.md": "# 2026-10-31\n\n## Meals\n\n- 08:00 mac\n"])
        let report = try await sync()
        XCTAssertEqual(report.conflicts, [])
        XCTAssertEqual(FakeGitHub.files["Journal/2026-10-31.md"], "# 2026-10-31\n\n## Meals\n\n- 08:00 mac\n- 09:00 phone\n")
    }

    func testTwoNewNotesWithOneNameStayApart() async throws {
        FakeGitHub.push(["Note.md": "a\n"])
        try await sync()
        try edit("Same.md", "# Same\nmine\n")
        FakeGitHub.push(["Same.md": "# Same\ntheirs\n"])
        let report = try await sync()
        XCTAssertEqual(report.conflicts, ["Same-phone-conflict-\(day).md"])
        XCTAssertEqual(try text("Same.md"), "# Same\ntheirs\n")
    }

    func testRemoteDeleteKeepsLocalEdit() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        try await sync()
        try edit("Note.md", "# Note\n\nkept\n")
        FakeGitHub.push(["Note.md": nil])
        try await sync()
        XCTAssertEqual(FakeGitHub.files["Note.md"], "# Note\n\nkept\n")
    }

    func testAMissingFileComesBackRatherThanDeletingRemotely() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        try await sync()
        try mirror.remove("Note.md")
        try await sync()
        XCTAssertEqual(try text("Note.md"), "# Note\n")
        XCTAssertEqual(FakeGitHub.files["Note.md"], "# Note\n")
    }

    func testSidecarIsNeverUploaded() async throws {
        FakeGitHub.push([".edgemark/meta.json": "{\"mac\":1}"])
        try await sync()
        try edit(".edgemark/meta.json", "{\"phone\":1}")
        let report = try await sync()
        XCTAssertEqual(report.pushed, 0)
        XCTAssertEqual(try text(".edgemark/meta.json"), "{\"mac\":1}")
    }

    func testRejectedMoveRunsAgain() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        try await sync()
        try edit("Note.md", "# Note\n\nmine\n")
        FakeGitHub.with { $0.movesToReject = 1 }
        let report = try await sync()
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(FakeGitHub.files["Note.md"], "# Note\n\nmine\n")
    }

    func testGivesUpAfterThreeRejections() async throws {
        FakeGitHub.push(["Note.md": "a\n"])
        try await sync()
        try edit("Note.md", "b\n")
        FakeGitHub.with { $0.movesToReject = 3 }
        do {
            try await sync()
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? SyncError, .busy)
        }
        XCTAssertEqual(try text("Note.md"), "b\n")
    }

    func testHeldFileStaysThenGoesWhenReleased() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        try await sync()
        try edit("Secret.md", "key\n")
        try edit("Fine.md", "fine\n")
        let report = try await sync(hold: { items in
            Dictionary(uniqueKeysWithValues: items.filter { $0.path == "Secret.md" }.map { ($0.path, ["a credential"]) })
        })
        XCTAssertEqual(report.held, ["Secret.md": ["a credential"]])
        XCTAssertEqual(report.pushed, 1)
        XCTAssertNil(FakeGitHub.files["Secret.md"])

        try await sync()
        XCTAssertEqual(FakeGitHub.files["Secret.md"], "key\n")
    }

    func testTruncatedTreeFails() async throws {
        FakeGitHub.push(["Note.md": "# Note\n"])
        FakeGitHub.with { $0.truncated = true }
        do {
            try await sync()
            XCTFail("expected truncatedTree")
        } catch {
            XCTAssertEqual(error as? SyncError, .truncatedTree)
        }
    }

    func testConflictTextLeavesFrontMatterAlone() {
        XCTAssertEqual(TreeSync.conflictText("---\ntitle: a\n---\nbody", day: "D"), "---\ntitle: a\n---\nbody")
        XCTAssertEqual(TreeSync.conflictText("Plain first line", day: "D"), "Plain first line (phone conflict D)")
    }
}
