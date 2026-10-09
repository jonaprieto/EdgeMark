import XCTest
@testable import EdgeSync

final class GitRepoTests: XCTestCase {
    func testRepoDetection() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let repo = GitRepo(url: work)
        XCTAssertTrue(repo.isRepo)
        XCTAssertTrue(repo.hasOrigin)
        XCTAssertFalse(repo.rebaseInProgress)
        XCTAssertFalse(GitRepo(url: TestGit.tempDir()).isRepo)
        XCTAssertFalse(GitRepo(url: TestGit.tempDir()).hasOrigin)
    }

    func testStageCommitPush() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let repo = GitRepo(url: work)
        let before = await repo.stageChanges()
        XCTAssertFalse(before, "clean clone has nothing to stage")
        TestGit.write("new\n", to: work.appendingPathComponent("second.md"))
        let staged = await repo.stageChanges()
        XCTAssertTrue(staged)
        let c = await repo.commit(message: "notes: test")
        XCTAssertTrue(c.ok, c.stderr)
        let unpushed = await repo.hasUnpushedCommits()
        XCTAssertTrue(unpushed)
        let p = await repo.push()
        XCTAssertTrue(p.ok, p.stderr)
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("second.md"))
        let stillUnpushed = await repo.hasUnpushedCommits()
        XCTAssertFalse(stillUnpushed)
    }

    func testPullBringsRemoteChange() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        let r = await GitRepo(url: work).pull()
        XCTAssertTrue(r.ok, r.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("other.md").path))
    }

    func testConflictIsDetected() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("# Note\n\ntheirs\n", to: other.appendingPathComponent("note.md"))
        _ = await TestGit.run(["commit", "-q", "-am", "theirs"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        let repo = GitRepo(url: work)
        TestGit.write("# Note\n\nmine\n", to: work.appendingPathComponent("note.md"))
        _ = await repo.stageChanges()
        _ = await repo.commit(message: "mine")
        let r = await repo.pull()
        XCTAssertFalse(r.ok)
        let files = await repo.conflictedFiles()
        XCTAssertEqual(files, ["note.md"])
        XCTAssertTrue(repo.rebaseInProgress)
    }

    func testPushSetsUpstreamWhenMissing() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        _ = await TestGit.run(["branch", "--unset-upstream"], in: work)
        TestGit.write("x\n", to: work.appendingPathComponent("x.md"))
        let repo = GitRepo(url: work)
        _ = await repo.stageChanges()
        _ = await repo.commit(message: "x")
        let p = await repo.push()
        XCTAssertTrue(p.ok, p.stderr)
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("x.md"))
    }

    func testAgeFilesGetNoConflictMarkers() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        GitRepo(url: work).ensureLocalAttributes()
        let attributes = work.appendingPathComponent(".git/info/attributes")
        XCTAssertEqual(try String(contentsOf: attributes, encoding: .utf8), "*.age binary\n")
        GitRepo(url: work).ensureLocalAttributes()
        XCTAssertEqual(try String(contentsOf: attributes, encoding: .utf8), "*.age binary\n", "the line is added once")

        let file = "n.md.age"
        TestGit.write("base\n", to: work.appendingPathComponent(file))
        _ = await TestGit.run(["add", "-A"], in: work)
        _ = await TestGit.run(["commit", "-q", "-m", "base"], in: work)
        _ = await TestGit.run(["push", "-q"], in: work)
        _ = await TestGit.run(["pull", "-q", "--rebase"], in: other)
        TestGit.write("from other\n", to: other.appendingPathComponent(file))
        _ = await TestGit.run(["commit", "-q", "-am", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        TestGit.write("from work\n", to: work.appendingPathComponent(file))
        _ = await TestGit.run(["commit", "-q", "-am", "work"], in: work)

        _ = await GitRepo(url: work).pull()
        let conflicted = await GitRepo(url: work).conflictedFiles()
        XCTAssertEqual(conflicted, [file], "the conflict is still reported")
        let text = try String(contentsOf: work.appendingPathComponent(file), encoding: .utf8)
        XCTAssertEqual(text, "from other\n", "one side, whole, with no conflict markers")
    }

    func testNoUnpushedCommitsWithoutHead() async throws {
        TestGit.setUpEnvironment()
        let dir = TestGit.tempDir()
        _ = await TestGit.run(["init", "-q", "-b", "main"], in: dir)
        let unpushed = await GitRepo(url: dir).hasUnpushedCommits()
        XCTAssertFalse(unpushed)
    }
}
