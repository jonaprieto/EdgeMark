import Foundation
import OSLog

/// Gist discovery, publishing, and first-time repository setup through `gh`.
extension GitSync {
    struct GistInfo {
        let id: String
        let account: String
        let fileCount: Int
        let webURL: URL
    }

    private var gistsDir: URL? {
        root?.appendingPathComponent("Gists", isDirectory: true)
    }

    // MARK: - Discovery

    /// Clones gists of the chosen account that have no directory under `Gists/` yet.
    /// Gists deleted on GitHub are left alone. Returns how many gists were cloned.
    @discardableResult
    func refreshGistsIfNeeded() async -> Int {
        guard settings.syncGists, !settings.account.isEmpty, let gistsDir else { return 0 }
        var known = Set<String>()
        for repo in gistRepos() {
            if let origin = await repo.originURL(), let id = GistCatalog.gistID(fromOrigin: origin) {
                known.insert(id)
            }
        }
        var cloned = 0
        switch await GistCatalog.list(account: settings.account) {
        case let .failure(error):
            SyncLog.log.error("[GitSync] gist list failed: \(error.message, privacy: .public)")
        case let .success(gists):
            for gist in gists where !known.contains(gist.id) {
                if await clone(gist, into: gistsDir) != nil { cloned += 1 }
            }
        }
        return cloned
    }

    /// Clones `gist` under `gistsDir`; returns the clone directory, or nil when git failed.
    @discardableResult
    private func clone(_ gist: Gist, into gistsDir: URL) async -> URL? {
        try? FileManager.default.createDirectory(at: gistsDir, withIntermediateDirectories: true)
        var name = GistCatalog.directoryName(description: gist.description, id: gist.id)
        if FileManager.default.fileExists(atPath: gistsDir.appendingPathComponent(name).path) {
            name += "-" + String(gist.id.prefix(7))
        }
        let target = gistsDir.appendingPathComponent(name, isDirectory: true)
        let r = await Shell.run(
            "git", ["clone", "-q", GistCatalog.cloneURL(account: settings.account, id: gist.id), target.path],
            cwd: gistsDir, timeout: 120,
        )
        if r.ok {
            SyncLog.log.info("[GitSync] cloned gist \(gist.id, privacy: .public) into \(name, privacy: .public)")
            return target
        } else {
            repoStates[GitRepo(url: target).url] = .error(r.errorLine)
            SyncLog.log.error("[GitSync] gist clone failed \(gist.id, privacy: .public): \(r.errorLine, privacy: .public)")
            return nil
        }
    }

    /// Gist metadata for a note that lives inside a gist clone, else nil.
    func gistInfo(for noteURL: URL) async -> GistInfo? {
        guard let gistsDir, noteURL.path.hasPrefix(gistsDir.path + "/"),
              let repo = repoContaining(noteURL), repo.url != root,
              let origin = await repo.originURL(),
              let id = GistCatalog.gistID(fromOrigin: origin) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: repo.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        ))?.count ?? 1
        return GistInfo(
            id: id,
            account: settings.account,
            fileCount: files,
            webURL: GistCatalog.webURL(account: settings.account, id: id, file: files > 1 ? noteURL.lastPathComponent : nil),
        )
    }

    // MARK: - Publish

    /// Creates a gist from `file`, clones it under `Gists/`, and removes the cloned copy of
    /// the file so the caller can move the original note into the clone (same name, same
    /// content, so git sees no change). Returns the clone directory and the web URL.
    func publishAsGist(file: URL, description: String, isPublic: Bool) async -> Result<(gistDir: URL, webURL: URL), GHError> {
        guard !settings.account.isEmpty else { return .failure(GHError(message: "Choose a GitHub account in Settings first")) }
        guard let gistsDir else { return .failure(GHError(message: "No storage root")) }
        let id: String
        switch await GistCatalog.create(account: settings.account, file: file, description: description, isPublic: isPublic) {
        case let .failure(error): return .failure(error)
        case let .success(created): id = created
        }
        let gist = Gist(id: id, description: description, htmlURL: "", files: [file.lastPathComponent])
        guard let dir = await clone(gist, into: gistsDir) else {
            return .failure(GHError(message: "gist created but clone failed; it will appear after the next sync"))
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(file.lastPathComponent))
        return .success((dir, GistCatalog.webURL(account: settings.account, id: id, file: nil)))
    }

    // MARK: - Repository setup

    /// `git init` plus `.gitignore` and an initial local commit, when the root is not a repo yet.
    private func ensureRootRepo() async -> String? {
        guard let root else { return "No storage root" }
        let repo = GitRepo(url: root)
        if !repo.isRepo {
            let r = await repo.git("init", "-q", "-b", "main")
            guard r.ok else { return r.errorLine }
        }
        let ignore = root.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? Data(".trash/\n.DS_Store\nGists/\n".utf8).write(to: ignore, options: .atomic)
        }
        let head = await repo.git("rev-parse", "--verify", "HEAD")
        if !head.ok {
            _ = await repo.stageChanges()
            let c = await repo.commit(message: "notes: initial import")
            guard c.ok else { return c.errorLine }
        }
        return nil
    }

    /// Creates `<account>/<name>` as a private repo and makes it `origin`. Nothing is pushed.
    func createPrivateRepo(named name: String) async -> String? {
        guard !settings.account.isEmpty else { return "Choose a GitHub account first" }
        guard let root else { return "No storage root" }
        if let error = await ensureRootRepo() { return error }
        guard let token = await GistCatalog.token(account: settings.account) else { return "gh has no token for \(settings.account)" }
        let r = await Shell.run(
            "gh", ["repo", "create", name, "--private", "--source", root.path, "--remote", "origin"],
            cwd: root, env: ["GH_TOKEN": token], timeout: 120,
        )
        guard r.ok else { return r.errorLine }
        let repo = GitRepo(url: root)
        _ = await repo.git("remote", "set-url", "origin", "https://\(settings.account)@github.com/\(settings.account)/\(name).git")
        configure(root: root)
        return nil
    }

    /// Uses an existing `owner/repo` as origin and merges its history into the local notes.
    func connectExisting(_ ownerRepo: String) async -> String? {
        guard !settings.account.isEmpty else { return "Choose a GitHub account first" }
        guard let root else { return "No storage root" }
        if let error = await ensureRootRepo() { return error }
        guard let token = await GistCatalog.token(account: settings.account) else { return "gh has no token for \(settings.account)" }
        let view = await Shell.run(
            "gh", ["repo", "view", ownerRepo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
            env: ["GH_TOKEN": token],
        )
        guard view.ok else { return view.errorLine }
        var branch = view.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty || branch == "null" { branch = "main" }
        let repo = GitRepo(url: root)
        let url = "https://\(settings.account)@github.com/\(ownerRepo).git"
        _ = await repo.git("remote", "remove", "origin")
        let add = await repo.git("remote", "add", "origin", url)
        guard add.ok else { return add.errorLine }
        _ = await repo.git("branch", "-M", branch)
        let pull = await repo.git("pull", "-q", "--rebase", "--allow-unrelated-histories", "origin", branch, timeout: 120)
        guard pull.ok else {
            let files = await repo.conflictedFiles()
            _ = await repo.git("rebase", "--abort")
            return files.isEmpty ? pull.errorLine : "Conflict: \(files.joined(separator: ", "))"
        }
        _ = await repo.git("branch", "--set-upstream-to=origin/\(branch)", branch)
        configure(root: root)
        return nil
    }
}
