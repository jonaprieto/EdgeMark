import XCTest
@testable import EdgeSync

@MainActor
final class GitSyncTests: XCTestCase {
    private func makeSync(root: URL) -> GitSync {
        let name = "edgesync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = SyncSettings(defaults: defaults)
        settings.syncGists = false
        settings.debounceSeconds = 0.2
        let sync = GitSync(settings: settings)
        sync.configure(root: root)
        return sync
    }

    func testOffWhenRootIsNotARepo() {
        let sync = makeSync(root: TestGit.tempDir())
        XCTAssertFalse(sync.isActive)
        XCTAssertEqual(sync.state, .off)
    }

    func testCommitAndPushLandsOnRemote() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        XCTAssertTrue(sync.isActive)
        TestGit.write("# Two\n", to: work.appendingPathComponent("two.md"))
        await sync.commitAndPush(GitRepo(url: work))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("two.md"))
        guard case .idle(let last) = sync.state, last != nil else {
            return XCTFail("expected idle with a sync date, got \(sync.state)")
        }
    }

    func testPullAllBringsRemoteChangeAndCallsBack() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)

        let sync = makeSync(root: work)
        var callbacks = 0
        sync.onPullFinished = { _ in callbacks += 1 }
        await sync.pullAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("other.md").path))
        XCTAssertEqual(callbacks, 1)
    }

    func testConflictPausesRepo() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("# Note\n\ntheirs\n", to: other.appendingPathComponent("note.md"))
        _ = await TestGit.run(["commit", "-q", "-am", "theirs"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)

        let sync = makeSync(root: work)
        TestGit.write("# Note\n\nmine\n", to: work.appendingPathComponent("note.md"))
        await sync.commitAndPush(GitRepo(url: work)) // push rejected, pull conflicts
        XCTAssertEqual(sync.state, .conflict(["note.md"]))
        XCTAssertTrue(GitRepo(url: work).rebaseInProgress)

        // While paused, further activity must not touch the repo.
        TestGit.write("# Other\n", to: work.appendingPathComponent("later.md"))
        await sync.commitAndPush(GitRepo(url: work))
        XCTAssertEqual(sync.state, .conflict(["note.md"]))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertFalse(files.contains("later.md"))
    }

    func testUncommittedLocalEditPlusRemoteEditPauses() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("# Note\n\nmine\n", to: work.appendingPathComponent("note.md"))
        TestGit.write("# Note\n\ntheirs\n", to: other.appendingPathComponent("note.md"))
        _ = await TestGit.run(["commit", "-q", "-am", "theirs"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        let remoteHead = await Shell.run("git", ["--git-dir", remote.path, "rev-parse", "HEAD^{tree}"])

        let sync = makeSync(root: work)
        await sync.pullAll()
        XCTAssertEqual(sync.state, .conflict(["note.md"]))
        XCTAssertTrue(GitRepo(url: work).rebaseInProgress)

        await sync.commitAndPush(GitRepo(url: work))
        XCTAssertEqual(sync.state, .conflict(["note.md"]))
        let after = await Shell.run("git", ["--git-dir", remote.path, "rev-parse", "HEAD^{tree}"])
        XCTAssertEqual(after.stdout, remoteHead.stdout)
    }

    func testPullReportsWhetherAnythingChanged() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        var flags: [Bool] = []
        sync.onPullFinished = { flags.append($0) }
        await sync.pullAll()

        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        await sync.pullAll(force: true)
        XCTAssertEqual(flags, [false, true])
    }

    func testPullsAreThrottledUnlessForced() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        var flags: [Bool] = []
        sync.onPullFinished = { flags.append($0) }
        await sync.pullAll()

        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        let otherNote = work.appendingPathComponent("other.md").path

        await sync.pullAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherNote), "second pull should be skipped")
        await sync.pullAll(force: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherNote))
        XCTAssertEqual(flags, [false, false, true])
    }

    func testFailedPullStillArmsThrottle() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        _ = await TestGit.run(["remote", "set-url", "origin", "/nonexistent/edgesync-remote.git"], in: work)
        let sync = makeSync(root: work)
        await sync.pullAll()
        guard case .error = sync.state else { return XCTFail("expected error, got \(sync.state)") }

        _ = await TestGit.run(["remote", "set-url", "origin", remote.path], in: work)
        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        await sync.pullAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("other.md").path))
    }

    func testRejectedPushPullMarksReload() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        var flags: [Bool] = []
        sync.onPullFinished = { flags.append($0) }
        await sync.pullAll()

        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)
        TestGit.write("# Mine\n", to: work.appendingPathComponent("mine.md"))
        await sync.commitAndPush(GitRepo(url: work)) // push rejected, pull, push
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("other.md").path))

        await sync.pullAll() // reports the pull done by commitAndPush
        await sync.pullAll()
        XCTAssertEqual(flags, [false, true, false])
    }

    func testPullAllCallsBackWhenInactive() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        sync.settings.enabled = false
        var flags: [Bool] = []
        sync.onPullFinished = { flags.append($0) }
        await sync.pullAll()
        XCTAssertEqual(flags, [false])
    }

    func testNoteActivityIsPendingUntilPushed() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        let note = work.appendingPathComponent("p.md")
        TestGit.write("# P\n", to: note)
        sync.noteActivity(at: note)
        XCTAssertEqual(sync.state, .pending)
        try await Task.sleep(for: .seconds(2))
        guard case .idle(let last) = sync.state, last != nil else {
            return XCTFail("expected idle with a sync date, got \(sync.state)")
        }
    }

    func testRefreshStatesFindsLocalWork() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        await sync.refreshStates()
        XCTAssertEqual(sync.state, .idle(lastSync: nil))

        TestGit.write("# Dirty\n", to: work.appendingPathComponent("dirty.md"))
        await sync.refreshStates()
        XCTAssertEqual(sync.state, .pending)
        let staged = await TestGit.run(["diff", "--cached", "--name-only"], in: work)
        XCTAssertEqual(staged.stdout, "", "refresh must not stage")

        _ = await TestGit.run(["add", "-A"], in: work)
        _ = await TestGit.run(["commit", "-q", "-m", "local"], in: work)
        sync.configure(root: work)
        await sync.refreshStates()
        XCTAssertEqual(sync.state, .pending, "unpushed commit is pending")

        await sync.commitAndPush(GitRepo(url: work))
        guard case .idle(let last) = sync.state, last != nil else {
            return XCTFail("expected idle with a sync date, got \(sync.state)")
        }
    }

    func testDebouncedActivityPushes() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        let note = work.appendingPathComponent("debounced.md")
        TestGit.write("# D\n", to: note)
        sync.noteActivity(at: note)
        sync.noteActivity(at: note) // restarts the timer, still one push
        try await Task.sleep(for: .seconds(3))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("debounced.md"))
        let count = await Shell.run("git", ["--git-dir", remote.path, "rev-list", "--count", "HEAD"])
        XCTAssertEqual(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testRepoContainingPrefersDeepestRepo() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let gist = work.appendingPathComponent("Gists/my-gist", isDirectory: true)
        try FileManager.default.createDirectory(at: gist, withIntermediateDirectories: true)
        _ = await TestGit.run(["init", "-q", "-b", "main"], in: gist)
        _ = await TestGit.run(["remote", "add", "origin", remote.path], in: gist)
        let bare = work.appendingPathComponent("Gists/no-origin", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        _ = await TestGit.run(["init", "-q", "-b", "main"], in: bare)
        let sync = makeSync(root: work)
        XCTAssertEqual(sync.gistRepos(), [GitRepo(url: bare), GitRepo(url: gist)].sorted { $0.url.path < $1.url.path })
        XCTAssertTrue(sync.gistRepos().contains(GitRepo(url: bare)))
        XCTAssertFalse(sync.repos().contains(GitRepo(url: bare)))
        XCTAssertEqual(sync.repoContaining(gist.appendingPathComponent("a.md"))?.url, GitRepo(url: gist).url)
        XCTAssertEqual(sync.repoContaining(work.appendingPathComponent("a.md"))?.url, GitRepo(url: work).url)
    }

    func testFlushOnQuitWithMissingRemoteReturns() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        _ = await TestGit.run(["remote", "set-url", "origin", "/nonexistent/edgesync-remote.git"], in: work)
        let sync = makeSync(root: work)
        TestGit.write("# Q\n", to: work.appendingPathComponent("q.md"))
        let start = Date()
        await sync.flushOnQuit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 25)
        guard case .error = sync.state else { return XCTFail("expected error, got \(sync.state)") }
    }

    func testFlushOnQuitStopsAtBudgetWhileGitHangs() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        _ = await TestGit.run(["remote", "set-url", "origin", "ssh://example.invalid/notes.git"], in: work)
        _ = await TestGit.run(["config", "core.sshCommand", "sleep 20; :"], in: work)
        let sync = makeSync(root: work)
        TestGit.write("# Q\n", to: work.appendingPathComponent("q.md"))
        let start = Date()
        await sync.flushOnQuit(budget: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testLocalExcludesKeepFoldersOutOfGistsAndRoot() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let gists = work.appendingPathComponent("Gists", isDirectory: true)
        try FileManager.default.createDirectory(at: gists, withIntermediateDirectories: true)
        let gist = gists.appendingPathComponent("g", isDirectory: true)
        _ = await TestGit.run(["clone", "-q", remote.path, gist.path], in: gists)
        _ = makeSync(root: work)

        try FileManager.default.createDirectory(at: gist.appendingPathComponent(".img"), withIntermediateDirectories: true)
        TestGit.write("png", to: gist.appendingPathComponent(".img/a.png"))
        TestGit.write("ds", to: gist.appendingPathComponent(".DS_Store"))
        let gistStaged = await GitRepo(url: gist).stageChanges()
        XCTAssertFalse(gistStaged)

        try FileManager.default.createDirectory(at: work.appendingPathComponent(".trash"), withIntermediateDirectories: true)
        TestGit.write("old\n", to: work.appendingPathComponent(".trash/old.md"))
        TestGit.write("ds", to: work.appendingPathComponent(".DS_Store"))
        let rootStaged = await GitRepo(url: work).stageChanges()
        XCTAssertFalse(rootStaged)
    }

    func testDisabledIsOff() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        sync.settings.enabled = false
        XCTAssertFalse(sync.isActive)
        XCTAssertEqual(sync.state, .off)
    }
}
