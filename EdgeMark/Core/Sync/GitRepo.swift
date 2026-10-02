import Foundation

/// One git working copy. Every method is a thin `git` invocation; nothing is cached.
struct GitRepo: Equatable, Hashable {
    let url: URL

    private var gitDir: URL { url.appendingPathComponent(".git", isDirectory: true) }

    var isRepo: Bool {
        FileManager.default.fileExists(atPath: gitDir.path)
    }

    /// Reads .git/config directly so the check is synchronous and cheap.
    var hasOrigin: Bool {
        guard let config = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8) else {
            return false
        }
        return config.contains("[remote \"origin\"]")
    }

    /// True while a rebase is waiting for the user to resolve conflicts.
    var rebaseInProgress: Bool {
        ["rebase-merge", "rebase-apply"].contains {
            FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path)
        }
    }

    func git(_ args: String..., timeout: TimeInterval = 60) async -> Shell.Result {
        await Shell.run("git", args, cwd: url, timeout: timeout)
    }

    func originURL() async -> String? {
        let r = await git("remote", "get-url", "origin")
        return r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func pull() async -> Shell.Result {
        await git("pull", "--rebase", "--autostash", timeout: 120)
    }

    /// Paths with unresolved merge conflicts (empty when there is no conflict).
    func conflictedFiles() async -> [String] {
        let r = await git("diff", "--name-only", "--diff-filter=U")
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Stages everything (adds, edits, deletes, renames). True when something is staged.
    func stageChanges() async -> Bool {
        _ = await git("add", "-A")
        let status = await git("status", "--porcelain")
        return !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when local commits are not on the upstream yet, or no upstream is set.
    func hasUnpushedCommits() async -> Bool {
        let r = await git("rev-list", "--count", "@{u}..HEAD")
        guard r.ok else { return true }
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// Signing and identity come from the user's git config, as for any other commit.
    func commit(message: String) async -> Shell.Result {
        await git("commit", "-q", "-m", message)
    }

    func push() async -> Shell.Result {
        let r = await git("push", "-q", timeout: 120)
        if !r.ok, r.stderr.contains("no upstream branch") {
            return await git("push", "-q", "-u", "origin", "HEAD", timeout: 120)
        }
        return r
    }
}
