import Foundation
import Observation
import OSLog

enum SyncLog {
    static let log = Logger(subsystem: "io.github.ender-wang.EdgeMark", category: "sync")
}

/// Keeps the notes root and the gist clones under `Gists/` in sync with GitHub.
///
/// Triggers: `noteActivity` (debounced commit+push), `pullAll` (on panel show),
/// `syncNow` (settings button), `flushOnQuit`. A repo is "synced" when it has
/// `.git` with an `origin`; nothing else is stored.
@MainActor
@Observable
final class GitSync {
    static let shared = GitSync()

    let settings: SyncSettings

    private(set) var root: URL?
    /// Per-repo status, keyed by working-copy URL.
    /// Writable from `GitSync+GitHub.swift`, which records gist clone failures.
    var repoStates: [URL: SyncState] = [:]
    /// Runs after every `pullAll`, so the app can re-read notes from disk. The flag is
    /// true when a pull moved some repo's HEAD or a gist was newly cloned, including a
    /// pull that `commitAndPush` ran after a rejected push since the last callback.
    @ObservationIgnored var onPullFinished: ((Bool) -> Void)?
    /// Message from the last Create/Connect attempt in Settings, cleared on success.
    var lastSetupError: String?

    @ObservationIgnored private var debounceTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var pulling = false
    /// Set when `commitAndPush` pulled new commits; reported by the next `pullAll`.
    @ObservationIgnored private var pendingReload = false
    /// Last queued git operation per repo; the next one waits for it.
    @ObservationIgnored private var inFlight: [URL: Task<Void, Never>] = [:]
    /// Time of the last successful pull or push per repo, kept while the repo is pending.
    @ObservationIgnored private var lastSync: [URL: Date] = [:]
    /// End of the last `pullAll` that ran git, whatever each repo's outcome; throttles
    /// unforced pulls so a paused or failing repo does not run git on every panel show.
    @ObservationIgnored private var lastPullAll: Date?
    /// Start of the last gist discovery; it runs at most hourly unless forced.
    @ObservationIgnored private var lastGistDiscovery: Date?

    init(settings: SyncSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Repos

    var rootRepo: GitRepo? {
        guard let root else { return nil }
        let repo = GitRepo(url: root)
        return repo.isRepo && repo.hasOrigin ? repo : nil
    }

    var isActive: Bool {
        settings.enabled && rootRepo != nil
    }

    var state: SyncState {
        guard isActive else { return .off }
        return SyncState.aggregate(repos().map { repoStates[$0.url] ?? .idle(lastSync: nil) })
    }

    /// Root first, then gist clones that have an origin.
    func repos() -> [GitRepo] {
        guard let rootRepo else { return [] }
        return [rootRepo] + gistRepos().filter(\.hasOrigin)
    }

    /// Every `Gists/<name>/` directory that is a git repo (origin or not).
    func gistRepos() -> [GitRepo] {
        guard let root else { return [] }
        let gists = root.appendingPathComponent("Gists", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: gists, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { GitRepo(url: $0) }
            .filter(\.isRepo)
            .sorted { $0.url.path < $1.url.path }
    }

    /// Deepest repo whose directory contains `url` (a gist beats the root).
    func repoContaining(_ url: URL) -> GitRepo? {
        let path = url.standardizedFileURL.path
        return repos()
            .filter { path.hasPrefix($0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Local-only ignore lines for the notes root and for gist clones. Gists are flat, so
    /// every directory (image folders and the like) is kept out of them.
    static let rootExcludes = [".trash/", ".DS_Store", "Gists/"]
    static let gistExcludes = ["*/", ".DS_Store"]

    /// Point the engine at a storage root. Cancels pending work and forgets old state.
    func configure(root: URL?) {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks = [:]
        repoStates = [:]
        lastSync = [:]
        lastPullAll = nil
        lastGistDiscovery = nil
        self.root = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        if let root = self.root, GitRepo(url: root).isRepo {
            GitRepo(url: root).ensureLocalExcludes(Self.rootExcludes)
        }
        gistRepos().forEach { $0.ensureLocalExcludes(Self.gistExcludes) }
        SyncLog.log.info("[GitSync] configured root \(self.root?.path ?? "none", privacy: .public), active \(self.isActive)")
        Task { await refreshStates() }
    }

    /// Marks repos with uncommitted edits or unpushed commits as `.pending`, and paused
    /// rebases as `.conflict`. Stages nothing; other states are left alone.
    func refreshStates() async {
        guard isActive else { return }
        for repo in repos() {
            await serialized(repo) { [self] in
                if await isPaused(repo) { return }
                switch repoStates[repo.url] {
                case .error, .syncing: return
                default: break
                }
                let dirty = await repo.hasChanges()
                let unpushed = await repo.hasUnpushedCommits()
                if dirty || unpushed {
                    repoStates[repo.url] = .pending
                }
            }
        }
    }

    // MARK: - Triggers

    /// A note was written at `url` (nil = something changed somewhere). Restarts the
    /// debounce timer of the affected repo(s); the commit happens when it fires.
    func noteActivity(at url: URL?) {
        guard isActive else { return }
        let targets = url.flatMap(repoContaining).map { [$0] } ?? repos()
        for repo in targets {
            switch repoStates[repo.url] {
            case .conflict, .error: break
            default: repoStates[repo.url] = .pending
            }
            debounceTasks[repo.url]?.cancel()
            let delay = settings.debounceSeconds
            debounceTasks[repo.url] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.commitAndPush(repo)
            }
        }
    }

    /// Pull every repo in turn, then let the app re-read files from disk.
    /// The callback runs on every call: with false when sync is inactive, and right away
    /// when a pull is already in flight or (unless `force`) one finished less than
    /// `settings.pullIntervalSeconds` ago; then the flag is true only if an earlier
    /// `commitAndPush` pulled new commits.
    /// Gist discovery runs when forced or when the last one is over an hour old.
    func pullAll(force: Bool = false) async {
        guard isActive else { onPullFinished?(false); return }
        if pulling { finishPull(changed: false); return }
        if !force, let lastPullAll, Date().timeIntervalSince(lastPullAll) < settings.pullIntervalSeconds {
            finishPull(changed: false)
            return
        }
        pulling = true
        defer { pulling = false }
        var changed = false
        if force || lastGistDiscovery.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true {
            lastGistDiscovery = Date()
            changed = await refreshGistsIfNeeded() > 0
        }
        for repo in repos() {
            await serialized(repo) { [self] in
                if await isPaused(repo) { return }
                // A fresh repo (created here, or connected to an empty remote) has no
                // upstream until its first push; there is nothing to pull yet.
                guard await repo.hasUpstream() else {
                    SyncLog.log.debug("[GitSync] no upstream in \(repo.url.lastPathComponent, privacy: .public), skipping pull")
                    return
                }
                repoStates[repo.url] = .syncing
                // Commit local edits first: a clash then pauses as a real rebase instead
                // of an autostash pop that leaves markers git would happily commit.
                if await repo.stageChanges() {
                    let c = await repo.commit(message: settings.renderCommitMessage())
                    guard c.ok else { return await recordFailure(repo, c, during: "commit") }
                }
                let before = await repo.head()
                let r = await repo.pull()
                if r.ok {
                    if await repo.head() != before { changed = true }
                    if await isPaused(repo) { return }
                    let now = Date()
                    lastSync[repo.url] = now
                    repoStates[repo.url] = await repo.hasUnpushedCommits() ? .pending : .idle(lastSync: now)
                } else {
                    await recordFailure(repo, r, during: "pull")
                }
            }
        }
        lastPullAll = Date()
        finishPull(changed: changed)
    }

    /// Reports `changed`, or a reload left over from `commitAndPush`, and clears the latter.
    private func finishPull(changed: Bool) {
        let reload = changed || pendingReload
        pendingReload = false
        onPullFinished?(reload)
    }

    /// `timeout` bounds each network step (push, pull) separately.
    func commitAndPush(_ repo: GitRepo, timeout: TimeInterval = 120) async {
        await serialized(repo) { [self] in
            guard isActive else { return }
            if await isPaused(repo) { return }
            let staged = await repo.stageChanges()
            if !staged, !(await repo.hasUnpushedCommits()) {
                repoStates[repo.url] = .idle(lastSync: lastSync[repo.url])
                return
            }
            repoStates[repo.url] = .syncing
            if staged {
                let c = await repo.commit(message: settings.renderCommitMessage())
                guard c.ok else { return await recordFailure(repo, c, during: "commit") }
            }
            var p = await repo.push(timeout: timeout)
            if !p.ok, p.stderr.contains("rejected") || p.stderr.contains("fetch first") {
                let before = await repo.head()
                let pulled = await repo.pull(timeout: timeout)
                let moved = await repo.head() != before
                let conflicted = await repo.hasConflicts()
                if moved || conflicted { pendingReload = true }
                guard pulled.ok else { return await recordFailure(repo, pulled, during: "pull") }
                p = await repo.push(timeout: timeout)
            }
            if p.ok {
                let now = Date()
                lastSync[repo.url] = now
                repoStates[repo.url] = .idle(lastSync: now)
                SyncLog.log.info("[GitSync] pushed \(repo.url.lastPathComponent, privacy: .public)")
            } else {
                await recordFailure(repo, p, during: "push")
            }
        }
    }

    /// Settings button: pull, then push whatever is pending in every repo.
    func syncNow() async {
        await pullAll(force: true)
        for repo in repos() {
            await commitAndPush(repo)
        }
        await refreshStates()
    }

    /// Best effort on quit: commits and pushes every repo (15 s per git network step)
    /// and returns after at most `budget` seconds even if git is still running.
    func flushOnQuit(budget: TimeInterval = 20) async {
        guard isActive, settings.pushOnQuit else { return }
        debounceTasks.values.forEach { $0.cancel() }
        let targets = repos()
        let work = Task { [self] in
            for repo in targets where !Task.isCancelled {
                await commitAndPush(repo, timeout: 15)
            }
        }
        // A task group would wait for its children, and a running git process does not
        // react to cancellation, so the race resumes a continuation from whichever
        // side finishes first.
        var resumed = false
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finish = { @MainActor in
                guard !resumed else { return }
                resumed = true
                done.resume()
            }
            timer = Task {
                try? await Task.sleep(for: .seconds(budget))
                finish()
            }
            Task {
                await work.value
                finish()
            }
        }
        timer?.cancel()
        work.cancel()
    }

    // MARK: - Private

    /// Runs `work` after any earlier operation on the same repo has finished, so two
    /// git processes never touch one working copy at once. Must not be called
    /// re-entrantly for the same repo from inside `work`: it would wait on itself.
    private func serialized(_ repo: GitRepo, _ work: @escaping @MainActor () async -> Void) async {
        let previous = inFlight[repo.url]
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        inFlight[repo.url] = task
        await task.value
        if inFlight[repo.url] == task { inFlight[repo.url] = nil }
    }

    /// Records `.conflict` and returns true while a rebase is paused or the index has
    /// unmerged entries; the repo must not be touched until the user resolves it.
    private func isPaused(_ repo: GitRepo) async -> Bool {
        let unmerged = await repo.hasConflicts()
        guard repo.rebaseInProgress || unmerged else { return false }
        repoStates[repo.url] = .conflict(await repo.conflictedFiles())
        return true
    }

    private func recordFailure(_ repo: GitRepo, _ r: Shell.Result, during step: String) async {
        let files = await repo.conflictedFiles()
        if !files.isEmpty {
            repoStates[repo.url] = .conflict(files)
            SyncLog.log.error("[GitSync] conflict in \(repo.url.lastPathComponent, privacy: .public): \(files.joined(separator: ", "), privacy: .public)")
        } else {
            repoStates[repo.url] = .error(r.errorLine)
            SyncLog.log.error("[GitSync] \(step, privacy: .public) failed in \(repo.url.lastPathComponent, privacy: .public): \(r.errorLine, privacy: .public)")
        }
    }
}
