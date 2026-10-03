import Foundation
import XCTest
@testable import EdgeSync

/// Hostile and unusual inputs for the sync engine. Each test asserts the desired behaviour.
/// Everything runs against local bare repos; nothing touches the network or `gh`.
@MainActor
final class AdversarialTests: XCTestCase {
    private var cleanup: [URL] = []
    private var restoreModes: [(path: String, mode: mode_t)] = []

    override func tearDown() async throws {
        for (path, mode) in restoreModes.reversed() {
            chmod(path, mode)
        }
        restoreModes = []
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
        cleanup = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func fixture() async throws -> (remote: URL, work: URL) {
        let (remote, work) = try await TestGit.makeRemoteAndClone()
        cleanup.append(remote.deletingLastPathComponent())
        return (remote, work)
    }

    private func tempDir() -> URL {
        let url = TestGit.tempDir()
        cleanup.append(url)
        return url
    }

    private func chmodTracked(_ url: URL, _ mode: mode_t) {
        var info = stat()
        if stat(url.path, &info) == 0 {
            restoreModes.append((url.path, info.st_mode & 0o7777))
        }
        chmod(url.path, mode)
    }

    private func makeSync(root: URL, debounce: Double = 0.2) -> GitSync {
        let defaults = UserDefaults(suiteName: "edgesync-adv-\(UUID().uuidString)")!
        let settings = SyncSettings(defaults: defaults)
        settings.syncGists = false
        settings.debounceSeconds = debounce
        let sync = GitSync(settings: settings)
        sync.configure(root: root)
        return sync
    }

    /// Runs `op` and fails the test (instead of blocking) when it takes longer than
    /// `seconds`. Returns the elapsed time, or nil on timeout.
    @discardableResult
    private func bounded(
        _ seconds: TimeInterval, _ label: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ op: @escaping @MainActor () async -> Void,
    ) async -> TimeInterval? {
        let start = Date()
        var finished = false
        var resumed = false
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finish = { @MainActor in
                guard !resumed else { return }
                resumed = true
                done.resume()
            }
            timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish()
            }
            Task { @MainActor in
                await op()
                finished = true
                finish()
            }
        }
        timer?.cancel()
        guard finished else {
            XCTFail("\(label) did not finish within \(seconds)s", file: file, line: line)
            return nil
        }
        return Date().timeIntervalSince(start)
    }

    /// Exact path names in the remote HEAD tree (NUL separated, no quoting).
    private func remoteNames(_ remote: URL) async -> [String] {
        let r = await Shell.run("git", ["--git-dir", remote.path, "ls-tree", "-r", "-z", "--name-only", "HEAD"])
        return r.stdout.split(separator: "\0").map(String.init)
    }

    private func containsBytes(_ names: [String], _ name: String) -> Bool {
        names.contains { Array($0.utf8) == Array(name.utf8) }
    }

    private func assertConsistent(_ sync: GitSync, file: StaticString = #filePath, line: UInt = #line) {
        if sync.isActive {
            XCTAssertNotEqual(sync.state, .off, "active but state is off", file: file, line: line)
        } else {
            XCTAssertEqual(sync.state, .off, "inactive but state is \(sync.state)", file: file, line: line)
        }
    }

    private func count(_ remote: URL) async -> Int {
        let r = await Shell.run("git", ["--git-dir", remote.path, "rev-list", "--count", "HEAD"])
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private func isError(_ state: SyncState) -> String? {
        if case let .error(message) = state { return message }
        return nil
    }

    // MARK: - 1. Note filenames

    func testHostileNoteFilenamesArePushedVerbatimAndNeverExecuted() async throws {
        let (remote, work) = try await fixture()
        let sentinel = "pwned-sentinel"
        let names = [
            "\"quotes\".md",
            "semi;colon.md",
            "$(whoami).md",
            "$(touch \(sentinel)).md",
            "`touch \(sentinel)`.md",
            "--leading-dash.md",
            "-rf.md",
            "tab\there.md",
        ]
        for name in names {
            TestGit.write("# x\n", to: work.appendingPathComponent(name))
        }
        let sync = makeSync(root: work)
        await bounded(60, "commitAndPush") { await sync.commitAndPush(GitRepo(url: work)) }
        let pushed = await remoteNames(remote)
        for name in names {
            XCTAssertTrue(containsBytes(pushed, name), "remote lacks exact bytes of \(name.debugDescription); got \(pushed)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent(sentinel).path))
        XCTAssertFalse(pushed.contains(sentinel))
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    func testLongCombiningMarkFilenameIsPushedWithExactBytes() async throws {
        let (remote, work) = try await fixture()
        // 1 + 76 * 3 (e + U+0301) + 8 (flag) + 3 (.md) = 240 bytes.
        let name = "x" + String(repeating: "e\u{0301}", count: 76) + "\u{1F1E8}\u{1F1F4}" + ".md"
        XCTAssertEqual(name.utf8.count, 240)
        TestGit.write("# long\n", to: work.appendingPathComponent(name))
        let sync = makeSync(root: work)
        await bounded(60, "commitAndPush") { await sync.commitAndPush(GitRepo(url: work)) }
        let pushed = await remoteNames(remote)
        let long = pushed.filter { $0.utf8.count > 200 }
        XCTAssertEqual(long.count, 1, "long name missing from remote: \(pushed)")
        XCTAssertTrue(containsBytes(pushed, name), "remote byte name differs: \(long.map { Array($0.utf8).count })")
        let dirty = await GitRepo(url: work).hasChanges()
        XCTAssertFalse(dirty, "working tree should be clean after push")
    }

    // MARK: - 2. Commit template injection

    func testCommitTemplatesAreLiteralMessages() async throws {
        let (remote, work) = try await fixture()
        let base = remote.deletingLastPathComponent()
        let sentinel = base.appendingPathComponent("pwned")
        let templates = [
            "notes: {date} --amend",
            "-m evil",
            "{date}\n\nBody: $(touch \(sentinel.path))",
            String(repeating: "A", count: 4994) + "{date}",
        ]
        let sync = makeSync(root: work)
        for (i, template) in templates.enumerated() {
            sync.settings.commitTemplate = template
            let before = await count(remote)
            TestGit.write("# \(i)\n", to: work.appendingPathComponent("t\(i).md"))
            let early = sync.settings.renderCommitMessage()
            await bounded(60, "commitAndPush \(i)") { await sync.commitAndPush(GitRepo(url: work)) }
            let late = sync.settings.renderCommitMessage()
            let after = await count(remote)
            XCTAssertEqual(after, before + 1, "template \(i) did not add exactly one commit")
            let log = await Shell.run("git", ["--git-dir", remote.path, "log", "-1", "--format=%B"])
            var message = log.stdout
            while message.hasSuffix("\n") { message.removeLast() }
            XCTAssertTrue(message == early || message == late, "template \(i) message differs: \(message.prefix(80).debugDescription)")
        }
        XCTAssertEqual(templates[3].count, 5000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "command substitution ran")
    }

    // MARK: - 3. Gist directory naming

    private func assertSafeDirName(_ name: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(name.isEmpty, "\(label): empty", file: file, line: line)
        XCTAssertFalse(name.contains("/"), "\(label): contains / -> \(name)", file: file, line: line)
        XCTAssertFalse(name.contains("\0"), "\(label): contains NUL", file: file, line: line)
        XCTAssertFalse(name == "." || name == "..", "\(label): is \(name)", file: file, line: line)
        XCTAssertFalse(name.hasPrefix("."), "\(label): hidden -> \(name)", file: file, line: line)
        XCTAssertLessThanOrEqual(name.utf8.count, 100, "\(label): \(name.utf8.count) bytes", file: file, line: line)
        let gists = URL(fileURLWithPath: "/root/Gists", isDirectory: true)
        let target = gists.appendingPathComponent(name).standardizedFileURL.path
        XCTAssertTrue(target.hasPrefix(gists.path + "/"), "\(label): escapes Gists/ -> \(target)", file: file, line: line)
    }

    func testGistDirectoryNamesStayInsideGists() {
        let id = "0123456789abcdef0123456789abcdef"
        let descriptions = [
            "../../etc", ".hidden", "/abs/path", "..", ".", String(repeating: "a", count: 500), "",
            "   ", "\u{1F1E8}\u{1F1F4}\u{1F600}", "Gists", "CON", "con.txt", "NUL", "AUX:", "-rf", "a/../../b",
            "\u{202E}gnp.exe", "e\u{0301}\u{0301}\u{0301}", String(repeating: "\u{00E9}", count: 200),
        ]
        for d in descriptions {
            assertSafeDirName(GistCatalog.directoryName(description: d, id: id), d.debugDescription)
        }
    }

    /// clone() appends `-<7 hex>` on a name clash; the result must still fit in 100 bytes.
    func testGistClashSuffixKeepsNamesDistinctAndBounded() {
        let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
        let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2"
        for d in ["same title", String(repeating: "a", count: 500)] {
            let first = GistCatalog.directoryName(description: d, id: a)
            let second = GistCatalog.directoryName(description: d, id: b)
            XCTAssertEqual(first, second)
            // Mirrors GitSync.clone(_:into:), which is private.
            let suffixed = second + "-" + String(b.prefix(7))
            XCTAssertNotEqual(first, suffixed)
            assertSafeDirName(suffixed, "clash suffix for \(d.prefix(20))")
        }
    }

    /// The id fallback is network input, so it must be sanitized too.
    func testGistDirectoryNameFallbackIdIsSanitized() {
        for id in ["../../evil", ".hidden", "a/b", ""] {
            assertSafeDirName(GistCatalog.directoryName(description: "", id: id), "fallback id \(id.debugDescription)")
        }
    }

    // MARK: - 4. gistID(fromOrigin:)

    func testGistIDAcceptsWellFormedOrigins() {
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "https://gist.github.com/abc123.git"), "abc123")
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "https://me@gist.github.com/abc123.git"), "abc123")
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "git@gist.github.com:abc123.git"), "abc123")
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "https://gist.github.com/abc123"), "abc123")
    }

    /// Only the real host and well-formed ids (lowercase hex, at most 64 digits) are accepted.
    func testGistIDRejectsHostileOrigins() {
        let hostile = [
            "https://evil.com/gist.github.com/abc.git",
            "https://gist.github.com.evil.com/abc.git",
            "https://gist.github.com/../abc.git",
            "git@gist.github.com:abc.git/../..",
            "https://gist.github.com/ABCDEF.git",
            "https://gist.github.com/" + String(repeating: "a", count: 200) + ".git",
        ]
        for origin in hostile {
            XCTAssertNil(GistCatalog.gistID(fromOrigin: origin), "accepted \(origin.prefix(60))")
        }
        let max = String(repeating: "f", count: 64)
        XCTAssertEqual(GistCatalog.gistID(fromOrigin: "https://gist.github.com/\(max).git"), max)
    }

    // MARK: - 5. accounts(fromAuthStatus:)

    func testAccountsFromNotLoggedIn() {
        let text = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), [])
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: ""), [])
    }

    /// Escape sequences must not become part of the login.
    func testAccountsStripAnsiColour() {
        let text = "github.com\n  \u{1B}[32m\u{2713}\u{1B}[0m Logged in to github.com account \u{1B}[1malice\u{1B}[0m (keyring)\n"
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), ["alice"])
    }

    /// "\r\n" is one Character in Swift, so splitting on "\n" alone would not split CRLF text.
    func testAccountsWithCRLFLineEndings() {
        let text = "github.com\r\n  \u{2713} Logged in to github.com account alice (keyring)\r\n  - Active account: true\r\n\r\n  \u{2713} Logged in to github.com account bob (keyring)\r\n"
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), ["alice", "bob"])
    }

    /// Lone "\r" separators split lines too.
    func testAccountsWithBareCRLineEndings() {
        let text = "  \u{2713} Logged in to github.com account alice (keyring)\r  \u{2713} Logged in to github.com account bob (keyring)\r"
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), ["alice", "bob"])
    }

    /// Logins that are not valid GitHub logins are dropped (they are embedded in remote URLs).
    func testAccountsRejectInvalidLogins() {
        let text = """
          \u{2713} Logged in to github.com account foo(bar) (keyring)
          \u{2713} Logged in to github.com account x@evil.com# (keyring)
          \u{2713} Logged in to github.com account good-login (keyring)
        """
        XCTAssertEqual(GistCatalog.accounts(fromAuthStatus: text), ["good-login"])
    }

    // MARK: - 6. Offline / broken remote

    func testMissingOriginKeepsCommitAndRecoversLater() async throws {
        let (remote, work) = try await fixture()
        _ = await TestGit.run(["remote", "set-url", "origin", "/nonexistent/edgesync-adv.git"], in: work)
        let sync = makeSync(root: work)
        TestGit.write("# offline\n", to: work.appendingPathComponent("offline.md"))
        await bounded(30, "offline push") { await sync.commitAndPush(GitRepo(url: work)) }
        XCTAssertNotNil(isError(sync.state), "expected error, got \(sync.state)")
        let unpushed = await GitRepo(url: work).hasUnpushedCommits()
        XCTAssertTrue(unpushed, "the commit must stay local")
        assertConsistent(sync)

        TestGit.write("# offline 2\n", to: work.appendingPathComponent("offline2.md"))
        await bounded(30, "second offline push") { await sync.commitAndPush(GitRepo(url: work)) }

        _ = await TestGit.run(["remote", "set-url", "origin", remote.path], in: work)
        await bounded(30, "repaired push") { await sync.commitAndPush(GitRepo(url: work)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("offline.md"))
        XCTAssertTrue(files.contains("offline2.md"))
        guard case .idle = sync.state else { return XCTFail("expected idle after repair, got \(sync.state)") }
    }

    func testUnreadableOriginKeepsCommitAndRecoversLater() async throws {
        let (remote, work) = try await fixture()
        chmodTracked(remote, 0o000)
        let sync = makeSync(root: work)
        TestGit.write("# locked\n", to: work.appendingPathComponent("locked.md"))
        await bounded(30, "push to unreadable remote") { await sync.commitAndPush(GitRepo(url: work)) }
        print("[adversarial] unreadable origin state \(sync.state)")
        XCTAssertNotNil(isError(sync.state), "expected error, got \(sync.state)")
        let unpushed = await GitRepo(url: work).hasUnpushedCommits()
        XCTAssertTrue(unpushed)

        chmod(remote.path, 0o755)
        await bounded(30, "repaired push") { await sync.commitAndPush(GitRepo(url: work)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("locked.md"))
        guard case .idle = sync.state else { return XCTFail("expected idle after repair, got \(sync.state)") }
    }

    func testPullAllWithBrokenRemotesIsBounded() async throws {
        let (remote, work) = try await fixture()
        let sync = makeSync(root: work)
        _ = await TestGit.run(["remote", "set-url", "origin", "/nonexistent/edgesync-adv.git"], in: work)
        let t1 = await bounded(125, "pullAll missing origin") { await sync.pullAll(force: true) }
        XCTAssertNotNil(isError(sync.state), "expected error, got \(sync.state)")
        _ = await TestGit.run(["remote", "set-url", "origin", remote.path], in: work)
        chmodTracked(remote, 0o000)
        let t2 = await bounded(125, "pullAll unreadable origin") { await sync.pullAll(force: true) }
        XCTAssertNotNil(isError(sync.state), "expected error, got \(sync.state)")
        print("[adversarial] pullAll missing origin \(t1 ?? -1)s, unreadable origin \(t2 ?? -1)s")
        assertConsistent(sync)
    }

    // MARK: - 7. Repo states

    func testDetachedHeadGivesErrorWithoutLosingCommit() async throws {
        let (_, work) = try await fixture()
        _ = await TestGit.run(["checkout", "-q", "--detach"], in: work)
        let sync = makeSync(root: work)
        TestGit.write("# detached\n", to: work.appendingPathComponent("detached.md"))
        await bounded(30, "commitAndPush detached") { await sync.commitAndPush(GitRepo(url: work)) }
        let message = isError(sync.state)
        print("[adversarial] detached HEAD state \(sync.state)")
        XCTAssertNotNil(message, "expected a clear error on detached HEAD, got \(sync.state)")
        XCTAssertFalse(message?.hasPrefix("exit status") ?? false, "error has no detail: \(message ?? "")")
        let log = await TestGit.run(["log", "-1", "--name-only", "--format="], in: work)
        XCTAssertTrue(log.stdout.contains("detached.md"), "commit lost")
        assertConsistent(sync)
    }

    /// A rebase paused without unmerged files must still give a summary with detail.
    func testRebaseInProgressAtConfigureIsPausedWithClearSummary() async throws {
        let (remote, work) = try await fixture()
        TestGit.write("# local\n", to: work.appendingPathComponent("local.md"))
        _ = await TestGit.run(["add", "-A"], in: work)
        _ = await TestGit.run(["commit", "-q", "-m", "local"], in: work)
        let rebase = await Shell.run(
            "git", ["rebase", "-i", "HEAD~1"], cwd: work,
            env: ["GIT_SEQUENCE_EDITOR": "sed -i.bak s/^pick/edit/"],
        )
        XCTAssertTrue(rebase.ok, rebase.stderr)
        XCTAssertTrue(GitRepo(url: work).rebaseInProgress)
        let before = await count(remote)

        let sync = makeSync(root: work)
        await bounded(30, "refreshStates") { await sync.refreshStates() }
        guard case let .conflict(files) = sync.state else { return XCTFail("expected conflict, got \(sync.state)") }
        XCTAssertEqual(files, [])
        TestGit.write("# more\n", to: work.appendingPathComponent("more.md"))
        await bounded(30, "commitAndPush during rebase") { await sync.commitAndPush(GitRepo(url: work)) }
        let after = await count(remote)
        XCTAssertEqual(after, before, "nothing may be pushed mid-rebase")
        XCTAssertFalse(sync.state.summary.hasSuffix(": "), "summary has no detail: \(sync.state.summary.debugDescription)")
        assertConsistent(sync)
    }

    func testGitdirPointerFileToNowhereIsOff() async throws {
        let root = tempDir()
        TestGit.setUpEnvironment()
        TestGit.write("gitdir: /nonexistent/edgesync-adv/.git/worktrees/x\n", to: root.appendingPathComponent(".git"))
        TestGit.write("# n\n", to: root.appendingPathComponent("n.md"))
        let sync = makeSync(root: root)
        XCTAssertFalse(sync.isActive)
        assertConsistent(sync)
        await bounded(30, "pullAll") { await sync.pullAll(force: true) }
        sync.noteActivity(at: root.appendingPathComponent("n.md"))
        assertConsistent(sync)
    }

    /// A valid repo whose `.git` is a gitdir file (worktree, separate git dir) must sync,
    /// not be silently treated as "not a synced repo".
    func testGitdirPointerToValidRepoWorksOrErrors() async throws {
        let (remote, _) = try await fixture()
        let base = remote.deletingLastPathComponent()
        let root = base.appendingPathComponent("sep-root")
        let gitDir = base.appendingPathComponent("sep-gitdir")
        let r = await Shell.run("git", ["clone", "-q", "--separate-git-dir", gitDir.path, remote.path, root.path], cwd: base)
        XCTAssertTrue(r.ok, r.stderr)
        let sync = makeSync(root: root)
        TestGit.write("# sep\n", to: root.appendingPathComponent("sep.md"))
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: root)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(sync.isActive || isError(sync.state) != nil, "silently off for a valid repo with origin")
        XCTAssertTrue(files.contains("sep.md"), "valid separate-git-dir repo was not synced")
    }

    func testRootInsideParentRepoIsOffAndParentUntouched() async throws {
        let (remote, _) = try await fixture()
        let parent = remote.deletingLastPathComponent().appendingPathComponent("parent")
        _ = await Shell.run("git", ["clone", "-q", remote.path, parent.path])
        let root = parent.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TestGit.write("# n\n", to: root.appendingPathComponent("n.md"))
        let headBefore = await GitRepo(url: parent).head()
        let sync = makeSync(root: root)
        XCTAssertFalse(sync.isActive)
        await bounded(30, "pullAll") { await sync.pullAll(force: true) }
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: root)) }
        let headAfter = await GitRepo(url: parent).head()
        XCTAssertEqual(headBefore, headAfter, "parent repo was committed to")
        assertConsistent(sync)
    }

    func testNestedRepoInsideParentRepoSyncsOnlyItself() async throws {
        let (remote, _) = try await fixture()
        let base = remote.deletingLastPathComponent()
        let parent = base.appendingPathComponent("parent")
        _ = await Shell.run("git", ["init", "-q", "-b", "main", parent.path])
        TestGit.write("p\n", to: parent.appendingPathComponent("p.txt"))
        _ = await TestGit.run(["add", "-A"], in: parent)
        _ = await TestGit.run(["commit", "-q", "-m", "p"], in: parent)
        let root = parent.appendingPathComponent("notes")
        _ = await Shell.run("git", ["clone", "-q", remote.path, root.path])
        let headBefore = await GitRepo(url: parent).head()
        let sync = makeSync(root: root)
        TestGit.write("# nested\n", to: root.appendingPathComponent("nested.md"))
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: root)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("nested.md"))
        let headAfter = await GitRepo(url: parent).head()
        XCTAssertEqual(headBefore, headAfter)
        assertConsistent(sync)
    }

    func testRootPathWithSpacesAndQuote() async throws {
        let (remote, _) = try await fixture()
        let root = try await TestGit.clone(remote, name: "my notes 'q' $HOME")
        let sync = makeSync(root: root)
        XCTAssertTrue(sync.isActive)
        TestGit.write("# s\n", to: root.appendingPathComponent("s.md"))
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: root)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("s.md"))
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    /// A note addressed through the resolved path must map to the symlinked root's repo.
    func testSymlinkRoot() async throws {
        let (remote, work) = try await fixture()
        let link = remote.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: work)
        let sync = makeSync(root: link)
        XCTAssertTrue(sync.isActive)
        TestGit.write("# l\n", to: link.appendingPathComponent("l.md"))
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: link)) }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("l.md"))
        let real = work.resolvingSymlinksInPath().appendingPathComponent("l.md")
        XCTAssertNotNil(sync.repoContaining(real), "resolved note path \(real.path) not matched to root \(link.path)")
        assertConsistent(sync)
    }

    func testReadOnlyRootDirectoryStillSyncs() async throws {
        let (remote, work) = try await fixture()
        TestGit.write("# ro\n", to: work.appendingPathComponent("ro.md"))
        chmodTracked(work, 0o555)
        let sync = makeSync(root: work)
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: work)) }
        let files = await TestGit.remoteFiles(remote)
        print("[adversarial] read-only root state \(sync.state)")
        XCTAssertTrue(files.contains("ro.md") || isError(sync.state) != nil, "neither pushed nor errored: \(sync.state)")
        assertConsistent(sync)
    }

    func testReadOnlyGitDirGivesClearError() async throws {
        let (_, work) = try await fixture()
        TestGit.write("# ro\n", to: work.appendingPathComponent("ro.md"))
        chmodTracked(work, 0o555)
        chmodTracked(work.appendingPathComponent(".git"), 0o555)
        let sync = makeSync(root: work)
        await bounded(30, "commitAndPush") { await sync.commitAndPush(GitRepo(url: work)) }
        let message = isError(sync.state)
        print("[adversarial] read-only .git state \(sync.state)")
        XCTAssertNotNil(message, "expected error, got \(sync.state)")
        XCTAssertFalse(message?.hasPrefix("exit status") ?? true, "error has no detail: \(message ?? "nil")")
        assertConsistent(sync)
    }

    // MARK: - 8. Huge inputs

    func testFiftyMegabyteNote() async throws {
        let (remote, work) = try await fixture()
        var bytes = [UInt8](repeating: 0, count: 37_500_000)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
        let text = Data(bytes).base64EncodedString(options: .lineLength76Characters)
        XCTAssertGreaterThanOrEqual(text.utf8.count, 50_000_000)
        TestGit.write(text, to: work.appendingPathComponent("huge.md"))
        let sync = makeSync(root: work)
        let elapsed = await bounded(125, "50 MB push") { await sync.commitAndPush(GitRepo(url: work)) }
        print("[adversarial] 50 MB note commit+push took \(elapsed ?? -1)s")
        let files = await TestGit.remoteFiles(remote)
        if let elapsed, elapsed > 120, !files.contains("huge.md") {
            throw XCTSkip("machine too slow: \(elapsed)s")
        }
        XCTAssertTrue(files.contains("huge.md"))
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    func testTwoThousandSmallNotes() async throws {
        let (remote, work) = try await fixture()
        for i in 0 ..< 2000 {
            TestGit.write("# note \(i)\n", to: work.appendingPathComponent("n\(i).md"))
        }
        let sync = makeSync(root: work)
        let elapsed = await bounded(125, "2000 notes push") { await sync.commitAndPush(GitRepo(url: work)) }
        print("[adversarial] 2000 notes commit+push took \(elapsed ?? -1)s")
        let files = await TestGit.remoteFiles(remote)
        if let elapsed, elapsed > 120, files.count < 2001 {
            throw XCTSkip("machine too slow: \(elapsed)s")
        }
        XCTAssertEqual(files.count, 2001)
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    // MARK: - 9. Concurrency

    func testConcurrentActivityPullAndSyncNow() async throws {
        let (remote, work) = try await fixture()
        let sync = makeSync(root: work, debounce: 0.05)
        var expected: [String] = ["note.md"]
        await bounded(90, "concurrent burst") {
            async let pull: Void = sync.pullAll(force: true)
            async let now: Void = sync.syncNow()
            for i in 0 ..< 50 {
                let name = "c\(i).md"
                expected.append(name)
                let url = work.appendingPathComponent(name)
                TestGit.write("# \(i)\n", to: url)
                sync.noteActivity(at: url)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0 ... 40)))
            }
            _ = await (pull, now)
        }
        // Let the last debounce fire and finish.
        try await Task.sleep(for: .seconds(1))
        await bounded(60, "final syncNow") { await sync.syncNow() }
        let files = Set(await TestGit.remoteFiles(remote))
        let missing = expected.filter { !files.contains($0) }
        XCTAssertEqual(missing, [], "missing on remote")
        let dirty = await GitRepo(url: work).hasChanges()
        XCTAssertFalse(dirty, "working tree not clean")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent(".git/index.lock").path))
        if case .conflict = sync.state { XCTFail("unexpected conflict \(sync.state)") }
        if let message = isError(sync.state) { XCTFail("unexpected error \(message)") }
    }

    // MARK: - 10. Shell

    func testShellPassesEmptyStringArgument() async {
        let r = await Shell.run("/bin/sh", ["-c", "echo $#; printf '[%s]' \"$1\"", "sh", "", "x"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.stdout, "2\n[]")
    }

    func testShellPassesTwoHundredKilobyteArgument() async {
        let big = String(repeating: "z", count: 200_000)
        let r = await Shell.run("/bin/sh", ["-c", "printf %s \"$1\" | wc -c", "sh", big])
        XCTAssertTrue(r.ok, r.stderr)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "200000")
    }

    /// Foundation raises NSInvalidArgumentException ("too many arguments (10003) -- limit
    /// is 4096") from `Process.run()`, which `do/catch` cannot catch, so Shell must refuse
    /// such a call itself. The call runs in a child xctest process so a regression cannot
    /// take this suite down; the child must exit cleanly.
    func testShellPassesTenThousandArguments() async throws {
        let bundle = Bundle(for: Self.self).bundlePath
        let r = await Shell.run(
            "/usr/bin/xcrun",
            ["xctest", "-XCTest", "EdgeSyncTests.AdversarialTests/testShellTenThousandArgumentsProbe", bundle],
            env: ["EDGESYNC_ADV_PROBE": "1"], timeout: 120,
        )
        print("[adversarial] 10k-argument probe exit \(r.status)")
        XCTAssertEqual(r.status, 0, "probe crashed or failed: \(r.stderr.split(separator: "\n").filter { $0.contains("argument") }.prefix(2))")
    }

    /// Runs only inside the child process started by `testShellPassesTenThousandArguments`.
    func testShellTenThousandArgumentsProbe() async throws {
        guard ProcessInfo.processInfo.environment["EDGESYNC_ADV_PROBE"] == "1" else {
            throw XCTSkip("probe runs only in a child process")
        }
        let args = (0 ..< 10_000).map { "a\($0)" }
        let r = await Shell.run("/bin/sh", ["-c", "echo $#", "sh"] + args)
        XCTAssertTrue(r.ok || !r.errorLine.isEmpty)
        if r.ok { XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "10000") }
    }

    func testShellWithVanishedCwdReturnsError() async {
        let dir = tempDir().appendingPathComponent("gone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dir)
        let r = await Shell.run("git", ["status"], cwd: dir)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.errorLine.isEmpty)
    }

    /// A key containing `=` must be skipped; otherwise the child sees a different
    /// variable (`K` with value `inj=v`).
    func testShellEnvKeyWithEqualsIsNotInjected() async {
        let r = await Shell.run("/usr/bin/printenv", ["EDGESYNC_ADV_K"], env: ["EDGESYNC_ADV_K=inj": "v"])
        XCTAssertFalse(r.ok, "child saw EDGESYNC_ADV_K=\(r.stdout.trimmingCharacters(in: .newlines))")
    }

    // MARK: - 11. renderCommitMessage

    func testRenderManyDatePlaceholders() {
        let settings = SyncSettings(defaults: UserDefaults(suiteName: "edgesync-adv-\(UUID().uuidString)")!)
        settings.commitTemplate = String(repeating: "{date}", count: 10_000)
        let start = Date()
        let message = settings.renderCommitMessage(date: Date(timeIntervalSince1970: 0), host: "h")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(message.contains("{date}"))
        XCTAssertEqual(message.utf8.count, 16 * 10_000)
    }

    func testRenderHostWithFormatAndPlaceholderIsNotRecursive() {
        let settings = SyncSettings(defaults: UserDefaults(suiteName: "edgesync-adv-\(UUID().uuidString)")!)
        let date = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let d = formatter.string(from: date)
        settings.commitTemplate = "h={host}"
        XCTAssertEqual(settings.renderCommitMessage(date: date, host: "%s%@{date}{host}"), "h=%s%@{date}{host}")
        settings.commitTemplate = "{{date}}"
        XCTAssertEqual(settings.renderCommitMessage(date: date, host: "h"), "{\(d)}")
    }

    // MARK: - 12. SyncState.summary

    /// The summary names a bounded number of files.
    func testSummaryWithManyConflictsIsBounded() {
        let files = (0 ..< 10_000).map { "folder/conflicted-note-\($0).md" }
        let summary = SyncState.conflict(files).summary
        XCTAssertTrue(summary.hasPrefix("Conflict"))
        XCTAssertLessThanOrEqual(summary.count, 500, "summary is \(summary.count) characters")
    }

    /// The "one line" summary drops embedded newlines.
    func testSummaryOfMultilineErrorIsOneLine() {
        let summary = SyncState.error("fatal: first\nhint: second\r\nthird").summary
        XCTAssertTrue(summary.hasPrefix("Error: "))
        XCTAssertFalse(summary.contains(where: \.isNewline), "summary spans lines: \(summary.debugDescription)")
    }
}
