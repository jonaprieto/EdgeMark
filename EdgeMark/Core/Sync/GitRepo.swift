import Foundation

/// One git working copy. Every method is a thin `git` invocation; nothing is cached.
struct GitRepo: Equatable, Hashable {
    let url: URL

    /// The URL is normalized to a directory URL with a standardized, symlink-resolved
    /// path, so a directory reached through a symlink and through its real path gives
    /// the same key.
    init(url: URL) {
        self.url = URL(fileURLWithPath: Self.resolvedURL(url).path, isDirectory: true)
    }

    /// `url` standardized with symlinks resolved. Foundation leaves a path whose last
    /// components do not exist untouched, so the deepest existing ancestor is resolved
    /// and the rest appended.
    static func resolvedURL(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while head.path != "/", !FileManager.default.fileExists(atPath: head.path) {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent()
        }
        return tail.reduce(head.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// The repository's own git dir: `.git` itself, or the directory a `.git` file
    /// points at (`gitdir: <path>`, as in a worktree or a `--separate-git-dir` clone).
    /// Nil when there is no `.git` or the pointer is unreadable.
    private var gitDir: URL? {
        let dotGit = url.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: url.appendingPathComponent(".git"), encoding: .utf8),
              let line = text.components(separatedBy: .newlines).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let dir = target.hasPrefix("/") ? URL(fileURLWithPath: target, isDirectory: true) : url.appendingPathComponent(target, isDirectory: true)
        return dir.standardizedFileURL
    }

    /// Where shared files (`config`, `info/exclude`) live: the `commondir` named inside a
    /// worktree's git dir, else the git dir itself.
    private var commonDir: URL? {
        guard let gitDir else { return nil }
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return gitDir }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return gitDir }
        let dir = target.hasPrefix("/") ? URL(fileURLWithPath: target, isDirectory: true) : gitDir.appendingPathComponent(target, isDirectory: true)
        return dir.standardizedFileURL
    }

    /// True when `.git` is a directory, or a `gitdir:` file pointing at an existing directory.
    var isRepo: Bool {
        guard let gitDir else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Reads the git config directly so the check is synchronous and cheap.
    var hasOrigin: Bool {
        guard let commonDir,
              let config = try? String(contentsOf: commonDir.appendingPathComponent("config"), encoding: .utf8) else {
            return false
        }
        return config.contains("[remote \"origin\"]")
    }

    /// True while a rebase is waiting for the user to resolve conflicts.
    var rebaseInProgress: Bool {
        guard let gitDir else { return false }
        return ["rebase-merge", "rebase-apply"].contains {
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
    /// `autostash` is for repos with held files: they stay modified in the tree, which
    /// would make the rebase refuse to run. Held files are never committed, so nothing
    /// else needs stashing; a clash on pop leaves unmerged entries the caller detects.
    func pull(autostash: Bool = false, timeout: TimeInterval = 120) async -> Shell.Result {
        await git("pull", "--rebase", autostash ? "--autostash" : "--no-autostash", timeout: timeout)
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

    /// Appends the missing `lines` to `info/exclude` in the git dir, an ignore list that stays on
    /// this machine (unlike `.gitignore`, it is never committed or merged).
    func ensureLocalExcludes(_ lines: [String]) {
        guard let commonDir else { return }
        let info = commonDir.appendingPathComponent("info", isDirectory: true)
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
