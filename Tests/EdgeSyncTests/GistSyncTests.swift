import Foundation
import XCTest
@testable import EdgeSync

/// Gist discovery, editing and publishing end to end. Gists are local bare repos named
/// `<id>.git`; a `url.<dir>.insteadOf` rule passed through the environment maps the real
/// clone URLs (`https://tester@gist.github.com/<id>.git`) onto them, and `listGists` /
/// `createGist` are swapped for fakes, so neither the network nor `gh` is used.
@MainActor
final class GistSyncTests: XCTestCase {
    private var base: URL!
    private var gistRemotes: URL!
    private var listed: [Gist] = []

    override func setUp() async throws {
        TestGit.setUpEnvironment()
        base = TestGit.tempDir()
        gistRemotes = base.appendingPathComponent("gists", isDirectory: true)
        try FileManager.default.createDirectory(at: gistRemotes, withIntermediateDirectories: true)
        setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "url.\(gistRemotes.path)/.insteadOf", 1)
        setenv("GIT_CONFIG_VALUE_0", "https://tester@gist.github.com/", 1)
    }

    override func tearDown() async throws {
        unsetenv("GIT_CONFIG_COUNT")
        unsetenv("GIT_CONFIG_KEY_0")
        unsetenv("GIT_CONFIG_VALUE_0")
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A notes root with an origin, so sync is active.
    private func makeRoot() async throws -> URL {
        let remote = base.appendingPathComponent("notes.git")
        _ = await TestGit.run(["init", "--bare", "-b", "main", remote.path], in: base)
        let root = base.appendingPathComponent("root", isDirectory: true)
        _ = await TestGit.run(["init", "-q", "-b", "main", root.path], in: base)
        TestGit.write("# Note\n", to: root.appendingPathComponent("note.md"))
        _ = await TestGit.run(["add", "-A"], in: root)
        _ = await TestGit.run(["commit", "-q", "-m", "seed"], in: root)
        _ = await TestGit.run(["remote", "add", "origin", remote.path], in: root)
        let pushed = await TestGit.run(["push", "-q", "-u", "origin", "main"], in: root)
        XCTAssertTrue(pushed.ok, pushed.stderr)
        return root
    }

    /// A bare gist remote `<id>.git` holding `files`, as GitHub would serve it.
    @discardableResult
    private func makeGist(id: String, files: [String: String]) async -> URL {
        let remote = gistRemotes.appendingPathComponent("\(id).git")
        let seed = base.appendingPathComponent("seed-\(id)")
        _ = await TestGit.run(["init", "--bare", "-q", "-b", "main", remote.path], in: base)
        _ = await TestGit.run(["init", "-q", "-b", "main", seed.path], in: base)
        for (name, text) in files {
            TestGit.write(text, to: seed.appendingPathComponent(name))
        }
        _ = await TestGit.run(["add", "-A"], in: seed)
        _ = await TestGit.run(["commit", "-q", "-m", "gist"], in: seed)
        _ = await TestGit.run(["remote", "add", "origin", remote.path], in: seed)
        let pushed = await TestGit.run(["push", "-q", "-u", "origin", "main"], in: seed)
        XCTAssertTrue(pushed.ok, pushed.stderr)
        return remote
    }

    private func makeSync(root: URL) -> GitSync {
        let defaults = UserDefaults(suiteName: "edgesync-gists-\(UUID().uuidString)")!
        let settings = SyncSettings(defaults: defaults)
        settings.syncGists = true
        settings.account = "tester"
        settings.debounceSeconds = 0.2
        let sync = GitSync(settings: settings)
        sync.guardTransport = StubTransport()
        sync.listGists = { [unowned self] _ in .success(listed) }
        // Never gh, never the real Trash.
        sync.fetchGistDetails = { _, _ in .failure(GHError(message: "no gh in tests")) }
        sync.deleteGistOnGitHub = { _, _ in .failure(GHError(message: "no gh in tests")) }
        sync.discardClone = { try FileManager.default.removeItem(at: $0) }
        sync.configure(root: root)
        return sync
    }

    private func gist(_ id: String, _ description: String, _ files: [String]) -> Gist {
        Gist(id: id, description: description, htmlURL: "https://gist.github.com/tester/\(id)", files: files)
    }

    private func gistDirs(_ root: URL) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Gists").path)
        return (names ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Discovery

    func testDiscoveryClonesNewGistsIncludingOnesCreatedLater() async throws {
        let root = try await makeRoot()
        await makeGist(id: "a1", files: ["README.md": "# A\n"])
        listed = [gist("a1", "First gist", ["README.md"])]
        let sync = makeSync(root: root)
        var reloads: [Bool] = []
        sync.onPullFinished = { reloads.append($0) }

        await sync.pullAll(force: true)
        XCTAssertEqual(gistDirs(root), ["First-gist"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Gists/First-gist/README.md"), encoding: .utf8), "# A\n")

        // Created later on github.com: picked up by the next discovery, the first is not cloned twice.
        await makeGist(id: "b2", files: ["mod.rs": "fn main() {}\n"])
        listed.append(gist("b2", "", ["mod.rs"]))
        await sync.pullAll(force: true)
        XCTAssertEqual(gistDirs(root), ["First-gist", "b2"])
        XCTAssertEqual(reloads, [true, true])
        XCTAssertEqual(sync.repos().count, 3)
    }

    func testSameDescriptionGetsDistinctFolders() async throws {
        let root = try await makeRoot()
        for id in ["c3c3c3c3c3", "c3c3c3c3d4", "c3c3c3c3e5"] {
            await makeGist(id: id, files: ["n.md": "\(id)\n"])
            listed.append(gist(id, "notes", ["n.md"]))
        }
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        // The second and third share the 7-character prefix, so the third takes the full id.
        XCTAssertEqual(gistDirs(root), ["notes", "notes-c3c3c3c", "notes-c3c3c3c3e5"])
    }

    func testChangedDescriptionKeepsTheFolder() async throws {
        let root = try await makeRoot()
        await makeGist(id: "d4", files: ["a.md": "a\n"])
        listed = [gist("d4", "Old name", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        listed = [gist("d4", "New name", ["a.md"])]
        await sync.pullAll(force: true)
        XCTAssertEqual(gistDirs(root), ["Old-name"])
    }

    // MARK: - Editing

    func testEditAddRenameAndDeleteReachTheGist() async throws {
        let root = try await makeRoot()
        let remote = await makeGist(id: "e5", files: ["README.md": "# E\n", "old.py": "print(1)\n", "gone.txt": "x\n"])
        listed = [gist("e5", "e", ["README.md", "old.py", "gone.txt"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let dir = root.appendingPathComponent("Gists/e")

        TestGit.write("# E\n\nedited\n", to: dir.appendingPathComponent("README.md"))
        TestGit.write("new file\n", to: dir.appendingPathComponent("Untitled.md"))
        try FileManager.default.moveItem(at: dir.appendingPathComponent("old.py"), to: dir.appendingPathComponent("new.py"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        await sync.commitAndPush(GitRepo(url: dir))

        let files = await TestGit.remoteFiles(remote)
        XCTAssertEqual(files.sorted(), ["README.md", "Untitled.md", "new.py"])
        let readme = await Shell.run("git", ["--git-dir", remote.path, "show", "HEAD:README.md"])
        XCTAssertEqual(readme.stdout, "# E\n\nedited\n")
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
    }

    func testNoteActivityInAGistPushesThatGist() async throws {
        let root = try await makeRoot()
        let remote = await makeGist(id: "f6", files: ["a.md": "a\n"])
        listed = [gist("f6", "f", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let file = root.appendingPathComponent("Gists/f/b.md")
        TestGit.write("b\n", to: file)
        sync.noteActivity(at: file)
        for _ in 0 ..< 50 {
            if await TestGit.remoteFiles(remote).contains("b.md") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertTrue(files.contains("b.md"))
    }

    /// Trashing one file of a gist removes it from the clone and reports activity there
    /// (FileStorage.trashNote); the removal is pushed as a deletion.
    func testRemovedGistFileIsDeletedFromTheGist() async throws {
        let root = try await makeRoot()
        let remote = await makeGist(id: "f7", files: ["a.md": "a\n", "b.md": "b\n"])
        listed = [gist("f7", "g", ["a.md", "b.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let file = root.appendingPathComponent("Gists/g/b.md")
        try FileManager.default.removeItem(at: file)
        sync.noteActivity(at: file)
        for _ in 0 ..< 50 {
            if await !TestGit.remoteFiles(remote).contains("b.md") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let files = await TestGit.remoteFiles(remote)
        XCTAssertEqual(files, ["a.md"])
    }

    // MARK: - Gone on GitHub

    func testGistDeletedOnGitHubIsNotSyncedButKept() async throws {
        let root = try await makeRoot()
        let remote = await makeGist(id: "a7", files: ["keep.md": "mine\n"])
        listed = [gist("a7", "doomed", ["keep.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let dir = root.appendingPathComponent("Gists/doomed")

        try FileManager.default.removeItem(at: remote)
        listed = []
        await sync.pullAll(force: true)
        XCTAssertEqual(sync.repos().map(\.url.lastPathComponent), ["root"])
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("keep.md"), encoding: .utf8), "mine\n")

        // An edit there does not turn into a failing push either.
        TestGit.write("still mine\n", to: dir.appendingPathComponent("keep.md"))
        await sync.syncNow()
        guard case .idle = sync.state else { return XCTFail("expected idle, got \(sync.state)") }
        XCTAssertEqual(gistDirs(root), ["doomed"])
    }

    func testFailedListingDetachesNothing() async throws {
        let root = try await makeRoot()
        await makeGist(id: "b8", files: ["a.md": "a\n"])
        listed = [gist("b8", "kept", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        sync.listGists = { _ in .failure(GHError(message: "offline")) }
        await sync.pullAll(force: true)
        XCTAssertEqual(sync.repos().count, 2)
    }

    func testCloneOfAnotherAccountIsNotDetached() async throws {
        let root = try await makeRoot()
        let gists = root.appendingPathComponent("Gists", isDirectory: true)
        try FileManager.default.createDirectory(at: gists, withIntermediateDirectories: true)
        let remote = await makeGist(id: "c9", files: ["a.md": "a\n"])
        let other = gists.appendingPathComponent("other")
        _ = await TestGit.run(["clone", "-q", remote.path, other.path], in: gists)
        _ = await TestGit.run(["remote", "set-url", "origin", "https://someone@gist.github.com/c9.git"], in: other)
        listed = []
        let sync = makeSync(root: root)
        _ = await sync.refreshGistsIfNeeded()
        XCTAssertTrue(sync.detachedGists.isEmpty)
    }

    // MARK: - Delete

    func testGistCloneResolvesSyncedClonesOnly() async throws {
        let root = try await makeRoot()
        await makeGist(id: "a2", files: ["a.md": "a\n"])
        listed = [gist("a2", "mine", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let dir = root.appendingPathComponent("Gists/mine")
        let clone = await sync.gistClone(at: dir)
        XCTAssertEqual(clone?.id, "a2")
        XCTAssertEqual(clone?.account, "tester")
        let atRoot = await sync.gistClone(at: root)
        XCTAssertNil(atRoot)
        // Deleted on GitHub (detached): not a gist to ask about.
        listed = []
        await sync.pullAll(force: true)
        let detached = await sync.gistClone(at: dir)
        XCTAssertNil(detached)
    }

    func testDeleteGistRemovesTheCloneOnlyAfterGitHubDeletedIt() async throws {
        let root = try await makeRoot()
        await makeGist(id: "b3", files: ["a.md": "a\n"])
        listed = [gist("b3", "doomed", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let dir = root.appendingPathComponent("Gists/doomed")
        let resolved = await sync.gistClone(at: dir)
        let clone = try XCTUnwrap(resolved)

        // gh fails: the clone stays and keeps syncing.
        guard case .failure = await sync.deleteGist(clone) else { return XCTFail("expected failure") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(sync.repos().count, 2)

        var calls: [String] = []
        sync.deleteGistOnGitHub = { account, id in
            calls.append("\(account) \(id)")
            return .success(())
        }
        guard case .success = await sync.deleteGist(clone) else { return XCTFail("expected success") }
        XCTAssertEqual(calls, ["tester b3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(sync.repos().map(\.url.lastPathComponent), ["root"])
    }

    // MARK: - Publish

    func testPublishThenMoveNeedsNoExtraCommit() async throws {
        let root = try await makeRoot()
        let note = root.appendingPathComponent("Plan.md")
        TestGit.write("# Plan\n\nsteps\n", to: note)
        let sync = makeSync(root: root)
        var remote: URL?
        sync.createGist = { [unowned self] _, file, description, _ in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            remote = await makeGist(id: "1234abcd", files: [file.lastPathComponent: text])
            listed.append(gist("1234abcd", description, [file.lastPathComponent]))
            return .success("1234abcd")
        }

        guard case let .success(result) = await sync.publishAsGist(file: note, description: "Plan") else {
            return XCTFail("publish failed")
        }
        XCTAssertEqual(result.gistDir.lastPathComponent, "Plan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.gistDir.appendingPathComponent("Plan.md").path))
        try FileManager.default.moveItem(at: note, to: result.gistDir.appendingPathComponent("Plan.md"))
        let before = await GitRepo(url: result.gistDir).head()
        await sync.commitAndPush(GitRepo(url: result.gistDir))
        let after = await GitRepo(url: result.gistDir).head()
        XCTAssertEqual(before, after)
        // The root still has the note's removal to push; the gist itself is settled.
        guard case .idle = sync.repoStates[GitRepo(url: result.gistDir).url] else {
            return XCTFail("expected idle gist, got \(String(describing: sync.repoStates[GitRepo(url: result.gistDir).url]))")
        }

        // Discovery afterwards knows the gist and does not clone it a second time.
        await sync.pullAll(force: true)
        XCTAssertEqual(gistDirs(root), ["Plan"])
        XCTAssertNotNil(remote)
    }

    // MARK: - Pure helpers

    func testLoginFromOrigin() {
        XCTAssertEqual(GistCatalog.login(fromOrigin: "https://tester@gist.github.com/abc.git"), "tester")
        XCTAssertNil(GistCatalog.login(fromOrigin: "https://gist.github.com/abc.git"))
        XCTAssertNil(GistCatalog.login(fromOrigin: "git@gist.github.com:abc.git"))
        XCTAssertNil(GistCatalog.login(fromOrigin: "https://tester@github.com/abc.git"))
    }

    func testOriginURLIsNotRewrittenByInsteadOf() async throws {
        let root = try await makeRoot()
        await makeGist(id: "d0", files: ["a.md": "a\n"])
        listed = [gist("d0", "raw", ["a.md"])]
        let sync = makeSync(root: root)
        await sync.pullAll(force: true)
        let origin = await GitRepo(url: root.appendingPathComponent("Gists/raw")).originURL()
        XCTAssertEqual(origin, "https://tester@gist.github.com/d0.git")
    }
}
