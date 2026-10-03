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
            GitRepo(url: target).ensureLocalExcludes(Self.gistExcludes)
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

    /// `git init` plus an initial local commit, when the root is not a repo yet. With
    /// `writeIgnore`, a missing `.gitignore` is created first; connecting to an existing
    /// remote skips it so it cannot clash with the remote's own `.gitignore`.
    private func ensureRootRepo(writeIgnore: Bool) async -> String? {
        guard let root else { return "No storage root" }
        let repo = GitRepo(url: root)
        if !repo.isRepo {
            let r = await repo.git("init", "-q", "-b", "main")
            guard r.ok else { return r.errorLine }
        }
        repo.ensureLocalExcludes(Self.rootExcludes)
        let ignore = root.appendingPathComponent(".gitignore")
        if writeIgnore, !FileManager.default.fileExists(atPath: ignore.path) {
            _ = try? GitRepo.appendMissingLines(Self.rootExcludes, to: ignore)
        }
        let head = await repo.git("rev-parse", "--verify", "HEAD")
        if !head.ok {
            // The first sync pushes this commit, so it goes through the guard too. When
            // every file is held the commit is skipped and the repo stays without HEAD.
            var staged = await repo.stageChanges()
            if staged { staged = await guardStaged(repo) }
            if staged {
                let c = await repo.commit(message: "notes: initial import")
                guard c.ok else { return c.errorLine }
            }
        }
        return nil
    }

    /// Appends the missing local-folder lines to the root's `.gitignore` and commits it.
    private func ensureIgnoreCommitted(_ repo: GitRepo) async -> String? {
        do {
            let ignore = repo.url.appendingPathComponent(".gitignore")
            guard try GitRepo.appendMissingLines(Self.rootExcludes, to: ignore) else { return nil }
        } catch {
            return error.localizedDescription
        }
        _ = await repo.git("add", ".gitignore")
        let c = await repo.commit(message: "notes: ignore local folders")
        return c.ok ? nil : c.errorLine
    }

    /// Creates `<account>/<name>` as a private repo and makes it `origin`. Nothing is pushed.
    func createPrivateRepo(named name: String) async -> String? {
        guard !settings.account.isEmpty else { return "Choose a GitHub account first" }
        guard let root else { return "No storage root" }
        if let error = await ensureRootRepo(writeIgnore: true) { return error }
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
        guard root != nil else { return "No storage root" }
        guard let token = await GistCatalog.token(account: settings.account) else { return "gh has no token for \(settings.account)" }
        let view = await Shell.run(
            "gh", ["repo", "view", ownerRepo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
            env: ["GH_TOKEN": token],
        )
        guard view.ok else { return view.errorLine }
        let name = view.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = name.isEmpty || name == "null" ? nil : name
        return await connect(remoteURL: "https://\(settings.account)@github.com/\(ownerRepo).git", branch: branch)
    }

    /// Makes `remoteURL` the root's origin and rebases the local notes onto `branch`.
    /// A nil `branch` means the remote is empty: nothing is pulled and the first push
    /// sets the upstream. On failure the origin and branch name are put back as they
    /// were and no rebase is left in progress. Returns an error message, or nil.
    func connect(remoteURL: String, branch: String?) async -> String? {
        guard let root else { return "No storage root" }
        if let error = await ensureRootRepo(writeIgnore: false) { return error }
        let repo = GitRepo(url: root)
        let oldBranch = (await repo.git("rev-parse", "--abbrev-ref", "HEAD")).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oldOrigin = await repo.originURL()

        func rollback() async {
            if repo.rebaseInProgress { _ = await repo.git("rebase", "--abort") }
            if let oldOrigin {
                _ = await repo.git("remote", "set-url", "origin", oldOrigin)
            } else {
                _ = await repo.git("remote", "remove", "origin")
            }
            if !oldBranch.isEmpty { _ = await repo.git("branch", "-M", oldBranch) }
        }

        let set = oldOrigin == nil
            ? await repo.git("remote", "add", "origin", remoteURL)
            : await repo.git("remote", "set-url", "origin", remoteURL)
        guard set.ok else {
            await rollback()
            return set.errorLine
        }
        if let branch {
            let rename = await repo.git("branch", "-M", branch)
            guard rename.ok else {
                await rollback()
                return rename.errorLine
            }
            let pull = await repo.git("pull", "-q", "--rebase", "--allow-unrelated-histories", "origin", branch, timeout: 120)
            guard pull.ok else {
                let files = await repo.conflictedFiles()
                await rollback()
                return files.isEmpty ? pull.errorLine : "Conflict: \(files.joined(separator: ", "))"
            }
            _ = await repo.git("branch", "--set-upstream-to=origin/\(branch)", branch)
        }
        if let error = await ensureIgnoreCommitted(repo) {
            await rollback()
            return error
        }
        configure(root: root)
        return nil
    }
}
