import XCTest
@testable import EdgeSync

@MainActor
final class GitSyncTests: XCTestCase {
    private func makeSync(root: URL, transport: JevTransport = StubTransport()) -> GitSync {
        let name = "edgesync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = SyncSettings(defaults: defaults)
        settings.syncGists = false
        settings.debounceSeconds = 0.2
        let sync = GitSync(settings: settings)
        sync.guardTransport = transport
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

    // MARK: - connect

    /// A notes folder that is not a git repo yet, next to the fixture remote.
    private func makeNotes(_ files: [String: String], near remote: URL) -> URL {
        let notes = remote.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true)
        try! FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for (name, text) in files {
            TestGit.write(text, to: notes.appendingPathComponent(name))
        }
        return notes
    }

    func testConnectMergesUnrelatedHistory() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        TestGit.write("*.tmp\n", to: work.appendingPathComponent(".gitignore"))
        _ = await TestGit.run(["add", "-A"], in: work)
        _ = await TestGit.run(["commit", "-q", "-m", "remote ignore"], in: work)
        _ = await TestGit.run(["push", "-q"], in: work)
        let notes = makeNotes(["local.md": "# Local\n"], near: remote)
        let sync = makeSync(root: notes)

        let error = await sync.connect(remoteURL: remote.path, branch: "main")
        XCTAssertNil(error)
        XCTAssertNotNil(sync.rootRepo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent("note.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent("local.md").path))
        let ignore = try String(contentsOf: notes.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(ignore, "*.tmp\n.trash/\n.DS_Store\nGists/\n")
        let upstream = await TestGit.run(["rev-parse", "--abbrev-ref", "@{u}"], in: notes)
        XCTAssertEqual(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")
        let dirty = await GitRepo(url: notes).hasChanges()
        XCTAssertFalse(dirty)
    }

    func testFailedConnectRollsBack() async throws {
        let (remote, _) = try await TestGit.makeRemoteAndClone()
        let notes = makeNotes(["note.md": "# Note\n\nmine\n"], near: remote)
        _ = await TestGit.run(["init", "-q", "-b", "local"], in: notes)
        _ = await TestGit.run(["add", "-A"], in: notes)
        _ = await TestGit.run(["commit", "-q", "-m", "mine"], in: notes)
        let sync = makeSync(root: notes)

        let error = await sync.connect(remoteURL: remote.path, branch: "main")
        XCTAssertEqual(error, "Conflict: note.md")
        let repo = GitRepo(url: notes)
        XCTAssertFalse(repo.hasOrigin)
        XCTAssertFalse(repo.rebaseInProgress)
        let branch = await TestGit.run(["rev-parse", "--abbrev-ref", "HEAD"], in: notes)
        XCTAssertEqual(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "local")
        XCTAssertNil(sync.rootRepo)
    }

    func testConnectToEmptyRemote() async throws {
        TestGit.setUpEnvironment()
        let base = TestGit.tempDir()
        let remote = base.appendingPathComponent("empty.git")
        _ = await TestGit.run(["init", "-q", "--bare", "-b", "main", remote.path], in: base)
        let notes = makeNotes(["a.md": "# A\n"], near: remote)
        let sync = makeSync(root: notes)

        let error = await sync.connect(remoteURL: remote.path, branch: nil)
        XCTAssertNil(error)
        XCTAssertNotNil(sync.rootRepo)
        await sync.commitAndPush(GitRepo(url: notes))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertEqual(Set(files), [".gitignore", "a.md"])
    }

    func testPullWithoutUpstreamIsNotAnError() async throws {
        let (remote, _) = try await TestGit.makeRemoteAndClone()
        let notes = makeNotes(["a.md": "# A\n"], near: remote)
        _ = await TestGit.run(["init", "-q", "-b", "main"], in: notes)
        _ = await TestGit.run(["add", "-A"], in: notes)
        _ = await TestGit.run(["commit", "-q", "-m", "local"], in: notes)
        _ = await TestGit.run(["remote", "add", "origin", remote.path], in: notes)
        let sync = makeSync(root: notes)
        XCTAssertTrue(sync.isActive)
        await sync.pullAll(force: true)
        if case .error(let message) = sync.state { XCTFail("unexpected error: \(message)") }
    }

    func testDisabledIsOff() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work)
        sync.settings.enabled = false
        XCTAssertFalse(sync.isActive)
        XCTAssertEqual(sync.state, .off)
    }

    // MARK: - Secrets guard

    private static let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n"

    /// Commits and pushes `name` with harmless content, so a later edit is a tracked
    /// modification.
    private func addTrackedFile(_ name: String, in work: URL) async {
        TestGit.write("# Harmless\n", to: work.appendingPathComponent(name))
        _ = await TestGit.run(["add", "-A"], in: work)
        _ = await TestGit.run(["commit", "-q", "-m", "add \(name)"], in: work)
        let pushed = await TestGit.run(["push", "-q"], in: work)
        XCTAssertTrue(pushed.ok, pushed.stderr)
    }

    private func remoteText(_ remote: URL, _ path: String) async -> String {
        await Shell.run("git", ["--git-dir", remote.path, "show", "HEAD:\(path)"]).stdout
    }

    func testGuardHoldsSecretAndPushesTheRest() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        await addTrackedFile("secret.md", in: work)
        let stub = StubTransport()
        let sync = makeSync(root: work, transport: stub)
        TestGit.write("# Keys\n\n" + Self.pem, to: work.appendingPathComponent("secret.md"))
        TestGit.write("# Benign\n", to: work.appendingPathComponent("ok.md"))
        await sync.commitAndPush(GitRepo(url: work))

        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("ok.md"))
        let remoteSecret = await remoteText(remote, "secret.md")
        XCTAssertEqual(remoteSecret, "# Harmless\n")
        let staged = await TestGit.run(["diff", "--cached", "--name-only"], in: work)
        XCTAssertEqual(staged.stdout, "")
        let status = await TestGit.run(["status", "--porcelain"], in: work)
        XCTAssertEqual(status.stdout, " M secret.md\n")
        XCTAssertEqual(sync.state, .held(["secret.md"]))
        XCTAssertEqual(sync.heldFiles[GitRepo(url: work).url]?.first?.viaRegex, true)
        let calls = await stub.texts
        XCTAssertEqual(calls, ["# Benign"], "only the benign file goes to Jev")

        // A pull with the held edit in the tree is skipped instead of failing.
        await sync.pullAll(force: true)
        XCTAssertEqual(sync.state, .held(["secret.md"]))
    }

    func testJevScoreHoldsFileWithoutRegexHit() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work, transport: StubTransport(credentials: 0.9))
        TestGit.write("my bank password is hunter2\n", to: work.appendingPathComponent("pw.md"))
        await sync.commitAndPush(GitRepo(url: work))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertFalse(files.contains("pw.md"))
        XCTAssertEqual(sync.state, .held(["pw.md"]))
        XCTAssertEqual(sync.guardStatus, "Jev ok")
    }

    func testAllowHeldThenNextSyncPushes() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let sync = makeSync(root: work, transport: StubTransport(credentials: 0.9))
        TestGit.write("my bank password is hunter2\n", to: work.appendingPathComponent("pw.md"))
        let repo = GitRepo(url: work)
        await sync.commitAndPush(repo)
        XCTAssertEqual(sync.state, .held(["pw.md"]))

        sync.allowHeld(path: "pw.md", in: repo)
        XCTAssertEqual(sync.settings.allowedHashes.count, 1)
        await sync.commitAndPush(repo)
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("pw.md"))
        XCTAssertNil(sync.heldFiles[repo.url])
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    func testGuardOffPushesEverything() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        let stub = StubTransport(credentials: 0.9)
        let sync = makeSync(root: work, transport: stub)
        sync.settings.guardEnabled = false
        TestGit.write(Self.pem, to: work.appendingPathComponent("secret.md"))
        await sync.commitAndPush(GitRepo(url: work))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("secret.md"))
        XCTAssertEqual(sync.guardStatus, "Guard off")
        let calls = await stub.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnchangedHeldFileIsNotSentAgain() async throws {
        let (_, work) = try await TestGit.makeRemoteAndClone()
        let stub = StubTransport(credentials: 0.9)
        let sync = makeSync(root: work, transport: stub)
        TestGit.write("my bank password is hunter2\n", to: work.appendingPathComponent("pw.md"))
        let repo = GitRepo(url: work)
        await sync.commitAndPush(repo)
        await sync.commitAndPush(repo)
        var calls = await stub.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sync.state, .held(["pw.md"]))

        TestGit.write("my bank password is hunter3\n", to: work.appendingPathComponent("pw.md"))
        await sync.commitAndPush(repo)
        calls = await stub.calls
        XCTAssertEqual(calls, 2, "a changed file is judged again")
    }

    func testInitialImportHoldsSecretBack() async throws {
        TestGit.setUpEnvironment()
        let base = TestGit.tempDir()
        let remote = base.appendingPathComponent("empty.git")
        _ = await TestGit.run(["init", "-q", "--bare", "-b", "main", remote.path], in: base)
        let notes = makeNotes(["secret.md": Self.pem, "ok.md": "# Benign\n"], near: remote)
        let sync = makeSync(root: notes)

        let error = await sync.connect(remoteURL: remote.path, branch: nil)
        XCTAssertNil(error)
        await sync.commitAndPush(GitRepo(url: notes))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("ok.md"))
        XCTAssertFalse(files.contains("secret.md"))
        XCTAssertEqual(sync.heldFiles[GitRepo(url: notes).url]?.map(\.path), ["secret.md"])
        XCTAssertEqual(sync.state, .held(["secret.md"]))
    }

    func testInitialImportWithEverythingHeldSkipsTheCommit() async throws {
        TestGit.setUpEnvironment()
        let base = TestGit.tempDir()
        let remote = base.appendingPathComponent("empty.git")
        _ = await TestGit.run(["init", "-q", "--bare", "-b", "main", remote.path], in: base)
        let notes = makeNotes(["secret.md": Self.pem], near: remote)
        let sync = makeSync(root: notes)

        let error = await sync.connect(remoteURL: remote.path, branch: nil)
        XCTAssertNil(error)
        await sync.commitAndPush(GitRepo(url: notes))
        let files = await TestGit.remoteFiles(remote)
        XCTAssertFalse(files.contains("secret.md"))
        if case .error = sync.state { XCTFail("unexpected error state \(sync.state)") }
    }

    func testPullWorksWhileAFileIsHeld() async throws {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        await addTrackedFile("secret.md", in: work)
        let sync = makeSync(root: work)
        TestGit.write("# Keys\n\n" + Self.pem, to: work.appendingPathComponent("secret.md"))
        let repo = GitRepo(url: work)
        await sync.commitAndPush(repo)
        XCTAssertEqual(sync.state, .held(["secret.md"]))

        let other = try await TestGit.clone(remote, name: "other")
        TestGit.write("from other\n", to: other.appendingPathComponent("other.md"))
        _ = await TestGit.run(["add", "-A"], in: other)
        _ = await TestGit.run(["commit", "-q", "-m", "other"], in: other)
        _ = await TestGit.run(["push", "-q"], in: other)

        await sync.pullAll(force: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("other.md").path))
        let status = await TestGit.run(["status", "--porcelain"], in: work)
        XCTAssertEqual(status.stdout, " M secret.md\n")
        let remoteSecret = await remoteText(remote, "secret.md")
        XCTAssertEqual(remoteSecret, "# Harmless\n")
        XCTAssertEqual(sync.state, .held(["secret.md"]))
    }

    func testAddedLinesSkipsHeaders() {
        let diff = """
        diff --git a/a.md b/a.md
        index 1..2 100644
        --- a/a.md
        +++ b/a.md
        @@ -1 +1,2 @@
        -old
        +new
        +++plus
        diff --git a/b.bin b/b.bin
        Binary files a/b.bin and b/b.bin differ
        """
        XCTAssertEqual(GitSync.addedLines(inDiff: diff), "new\n++plus")
    }
}
