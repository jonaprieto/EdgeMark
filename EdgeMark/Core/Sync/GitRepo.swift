import Foundation

/// One git working copy. Every method is a thin `git` invocation; nothing is cached.
struct GitRepo: Equatable, Hashable {
    let url: URL

    /// The URL is normalized (standardized, no trailing slash) so it works as a dictionary key.
    init(url: URL) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

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

    /// `--no-autostash` overrides a user's `rebase.autoStash`: local edits are committed
    /// before pulling, so a clash pauses as a rebase rather than a stash pop.
    func pull(timeout: TimeInterval = 120) async -> Shell.Result {
        await git("pull", "--rebase", "--no-autostash", timeout: timeout)
    }

    /// True when the index has unmerged entries, with or without a rebase in progress.
    func hasConflicts() async -> Bool {
        await !conflictedFiles().isEmpty
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

    /// True when the working tree or index differs from HEAD (untracked files count).
    /// Unlike `stageChanges`, nothing is staged.
    func hasChanges() async -> Bool {
        let status = await git("status", "--porcelain")
        return !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Current commit id, or nil when the repo has no commits.
    func head() async -> String? {
        let r = await git("rev-parse", "--verify", "HEAD")
        return r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Appends the missing `lines` to `.git/info/exclude`, an ignore list that stays on
    /// this machine (unlike `.gitignore`, it is never committed or merged).
    func ensureLocalExcludes(_ lines: [String]) {
        let info = gitDir.appendingPathComponent("info", isDirectory: true)
        try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        _ = try? Self.appendMissingLines(lines, to: info.appendingPathComponent("exclude"))
    }

    /// Appends the `lines` that `file` does not contain yet (creating it if needed).
    /// Returns true when the file changed.
    static func appendMissingLines(_ lines: [String], to file: URL) throws -> Bool {
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let present = Set(current.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = lines.filter { !present.contains($0) }
        guard !missing.isEmpty else { return false }
        var text = current
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += missing.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file, options: .atomic)
        return true
    }

    /// True when the current branch tracks a remote branch.
    func hasUpstream() async -> Bool {
        await git("rev-parse", "--abbrev-ref", "@{u}").ok
    }

    /// True when local commits are not on the upstream yet, or no upstream is set.
    /// False when the repo has no commits at all.
    func hasUnpushedCommits() async -> Bool {
        guard await git("rev-parse", "--verify", "HEAD").ok else { return false }
        let r = await git("rev-list", "--count", "@{u}..HEAD")
        guard r.ok else { return true }
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// Signing and identity come from the user's git config, as for any other commit.
    func commit(message: String) async -> Shell.Result {
        await git("commit", "-q", "-m", message)
    }

    func push(timeout: TimeInterval = 120) async -> Shell.Result {
        let r = await git("push", "-q", timeout: timeout)
        if !r.ok, r.stderr.contains("no upstream branch") {
            return await git("push", "-q", "-u", "origin", "HEAD", timeout: timeout)
        }
        return r
    }
}
