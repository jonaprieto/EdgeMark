import Foundation
import XCTest
@testable import EdgeSync

/// Git fixtures: a bare "remote" plus clones in a temp directory. The user's
/// global git config (signing, hooks) is switched off through the environment.
enum TestGit {
    static func setUpEnvironment() {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        setenv("GIT_AUTHOR_NAME", "EdgeSync Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@example.invalid", 1)
        setenv("GIT_COMMITTER_NAME", "EdgeSync Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@example.invalid", 1)
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgesync-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run(_ args: [String], in dir: URL) async -> Shell.Result {
        await Shell.run("git", args, cwd: dir)
    }

    static func write(_ text: String, to url: URL) {
        try! Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Bare remote on branch main with one commit (note.md), plus a clone "work".
    static func makeRemoteAndClone() async throws -> (remote: URL, work: URL) {
        setUpEnvironment()
        let base = tempDir()
        let remote = base.appendingPathComponent("remote.git")
        let seed = base.appendingPathComponent("seed")
        _ = await run(["init", "--bare", "-b", "main", remote.path], in: base)
        _ = await run(["init", "-b", "main", seed.path], in: base)
        write("# Note\n\nhello\n", to: seed.appendingPathComponent("note.md"))
        _ = await run(["add", "-A"], in: seed)
        _ = await run(["commit", "-q", "-m", "seed"], in: seed)
        _ = await run(["remote", "add", "origin", remote.path], in: seed)
        let pushed = await run(["push", "-q", "-u", "origin", "main"], in: seed)
        XCTAssertTrue(pushed.ok, pushed.stderr)
        let work = try await clone(remote, name: "work")
        return (remote, work)
    }

    static func clone(_ remote: URL, name: String) async throws -> URL {
        let target = remote.deletingLastPathComponent().appendingPathComponent(name)
        let r = await run(["clone", "-q", remote.path, target.path], in: remote.deletingLastPathComponent())
        XCTAssertTrue(r.ok, r.stderr)
        return target
    }

    /// Files in the remote's HEAD tree.
    static func remoteFiles(_ remote: URL) async -> [String] {
        let r = await Shell.run("git", ["--git-dir", remote.path, "ls-tree", "--name-only", "-r", "HEAD"])
        return r.stdout.split(separator: "\n").map(String.init)
    }
}
