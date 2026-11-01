import XCTest
@testable import EdgePhoneSync

/// The phone's sync against a real repository, with a real git clone playing the Mac. Skipped
/// unless these are set; it pushes to main, so only ever point it at a throwaway repository:
/// EDGEMARK_LIVE_REPO (owner/name), EDGEMARK_LIVE_TOKEN, EDGEMARK_LIVE_CLONE (a fresh clone).
final class LiveGitHubTests: XCTestCase {
    private var clone: URL!
    private var mirror: NotesMirror!
    private var repo: GitHubRepo!
    private var dir: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["EDGEMARK_LIVE_REPO"], let token = env["EDGEMARK_LIVE_TOKEN"], let path = env["EDGEMARK_LIVE_CLONE"] else {
            throw XCTSkip("no live repository configured")
        }
        clone = URL(fileURLWithPath: path)
        repo = GitHubRepo(repository: name, token: token)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mirror = try NotesMirror(root: dir.appendingPathComponent("notes"), baseURL: dir.appendingPathComponent("base.json"))
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private static func run(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SyncError.badPath("git \(arguments.joined(separator: " "))") }
    }

    private func macWrite(_ path: String, _ text: String) throws {
        let url = clone.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func macCommit(_ message: String) throws {
        try Self.run(["add", "-A"], in: clone)
        try Self.run(["commit", "-m", message], in: clone)
    }

    private func macRead(_ path: String) throws -> String {
        try String(contentsOf: clone.appendingPathComponent(path), encoding: .utf8)
    }

    private func phoneRead(_ path: String) throws -> String {
        try String(decoding: mirror.read(path), as: UTF8.self)
    }

    private func phoneWrite(_ path: String, _ text: String) throws {
        try mirror.write(Data(text.utf8), to: path)
    }

    private func sync(hold: @escaping TreeSync.Hold = { _ in [:] }) async throws -> SyncReport {
        try await TreeSync(repo: repo, mirror: mirror, hold: hold).run()
    }

    func testPhoneAndMacMeetOnARealRepository() async throws {
        let journal = "Journal/2026-10-31.md"
        let ideas = "Ideas-ñandú con espacio.md"
        try macWrite(".gitattributes", "Journal/*.md merge=union\n")
        try macWrite(".edgemark/meta.json", "{}\n")
        try macWrite(journal, "# 2026-10-31\n\n## Meals\n\n- 08:00 arepa\n")
        try macWrite(ideas, "# Ideas\n\nuno\ndos\ntres\n")
        let binary = Data((0 ..< 256).map { UInt8($0) })
        try binary.write(to: clone.appendingPathComponent("image.png"))
        try macCommit("seed")
        try Self.run(["push"], in: clone)

        // First sync brings text, a non-ASCII path and binary bytes across intact.
        _ = try await sync()
        XCTAssertEqual(try phoneRead(ideas), "# Ideas\n\nuno\ndos\ntres\n")
        XCTAssertEqual(try mirror.read("image.png"), binary)

        // Phone writes reach the Mac through a plain git pull.
        try phoneWrite(journal, try phoneRead(journal) + "- 12:30 from the phone\n")
        try phoneWrite("Meetings/2026-11-03-Felipe.md", "# 2026-11-03 Felipe\n\n## Ideas\n\n")
        var report = try await sync()
        XCTAssertEqual(report.pushed, 2)
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertTrue(try macRead(journal).contains("- 12:30 from the phone"))
        XCTAssertEqual(try macRead("Meetings/2026-11-03-Felipe.md"), "# 2026-11-03 Felipe\n\n## Ideas\n\n")

        // Edits of different lines on both sides merge.
        try phoneWrite(ideas, "# Ideas\n\nUNO\ndos\ntres\n")
        try macWrite(ideas, "# Ideas\n\nuno\ndos\nTRES\n")
        try macCommit("mac edit")
        try Self.run(["push"], in: clone)
        report = try await sync()
        XCTAssertEqual(report.conflicts, [])
        XCTAssertEqual(try phoneRead(ideas), "# Ideas\n\nUNO\ndos\nTRES\n")
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertEqual(try macRead(ideas), "# Ideas\n\nUNO\ndos\nTRES\n")

        // A Mac that has not pulled yet rebases over the phone's journal line, by merge=union.
        try macWrite(journal, try macRead(journal) + "- 13:00 from the mac\n")
        try macCommit("mac journal")
        try phoneWrite(journal, try phoneRead(journal) + "- 13:05 from the phone\n")
        report = try await sync()
        XCTAssertEqual(report.pushed, 1)
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertTrue(try macRead(journal).contains("- 13:00 from the mac"))
        XCTAssertTrue(try macRead(journal).contains("- 13:05 from the phone"))
        try Self.run(["push"], in: clone)
        _ = try await sync()
        XCTAssertEqual(try phoneRead(journal), try macRead(journal))

        // Overlapping edits keep both texts.
        try phoneWrite(ideas, "# Ideas\n\nUNO\nphone\nTRES\n")
        try macWrite(ideas, "# Ideas\n\nUNO\nmac\nTRES\n")
        try macCommit("mac overlap")
        try Self.run(["push"], in: clone)
        report = try await sync()
        XCTAssertEqual(report.conflicts.count, 1)
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertEqual(try macRead(ideas), "# Ideas\n\nUNO\nmac\nTRES\n")
        XCTAssertTrue(try macRead(report.conflicts[0]).contains("phone"))

        // GitHub itself refuses a stale update when the Mac pushes mid-round, and the round reruns.
        try phoneWrite(journal, try phoneRead(journal) + "- 14:00 racing\n")
        let clone = clone!
        let raced = Raced()
        try macWrite("Raced.md", "# Raced\n")
        report = try await sync(hold: { _ in
            if raced.first() {
                try? Self.run(["add", "-A"], in: clone)
                try? Self.run(["commit", "-m", "mac race"], in: clone)
                try? Self.run(["push"], in: clone)
            }
            return [:]
        })
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(try phoneRead("Raced.md"), "# Raced\n")
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertTrue(try macRead(journal).contains("- 14:00 racing"))

        // A deletion on the phone reaches the Mac, and an old note's history keeps it.
        try mirror.delete("Raced.md")
        report = try await sync()
        XCTAssertEqual(report.deleted, 1)
        try Self.run(["pull", "--rebase", "--autostash"], in: clone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent("Raced.md").path))
        try Self.run(["log", "--format=%h", "--diff-filter=D", "--", "Raced.md"], in: clone)
        _ = try await sync()
        XCTAssertFalse(mirror.exists("Raced.md"))

        // A deletion on the Mac reaches the phone.
        try FileManager.default.removeItem(at: clone.appendingPathComponent("image.png"))
        try macCommit("mac delete")
        try Self.run(["push"], in: clone)
        report = try await sync()
        XCTAssertFalse(mirror.exists("image.png"))
    }
}

private final class Raced: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { fired = true }
        return !fired
    }
}
