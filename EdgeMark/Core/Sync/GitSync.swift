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
    /// Runs after every `pullAll`, so the app can re-read notes from disk.
    @ObservationIgnored var onPullFinished: (() -> Void)?
    /// Message from the last Create/Connect attempt in Settings, cleared on success.
    var lastSetupError: String?

    @ObservationIgnored private var debounceTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var pulling = false
    /// Last queued git operation per repo; the next one waits for it.
    @ObservationIgnored private var inFlight: [URL: Task<Void, Never>] = [:]

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

    /// Point the engine at a storage root. Cancels pending work and forgets old state.
    func configure(root: URL?) {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks = [:]
        repoStates = [:]
        self.root = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        SyncLog.log.info("[GitSync] configured root \(self.root?.path ?? "none", privacy: .public), active \(self.isActive)")
    }

    // MARK: - Triggers

    /// A note was written at `url` (nil = something changed somewhere). Restarts the
    /// debounce timer of the affected repo(s); the commit happens when it fires.
    func noteActivity(at url: URL?) {
        guard isActive else { return }
        let targets = url.flatMap(repoContaining).map { [$0] } ?? repos()
        for repo in targets {
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
    /// A pull already in flight runs the callback immediately and again when it completes.
    func pullAll() async {
        guard isActive else { return }
        if pulling { onPullFinished?(); return }
        pulling = true
        defer { pulling = false }
        await refreshGistsIfNeeded()
        for repo in repos() {
            await serialized(repo) { [self] in
                if await isPaused(repo) { return }
                repoStates[repo.url] = .syncing
                // Commit local edits first: a clash then pauses as a real rebase instead
                // of an autostash pop that leaves markers git would happily commit.
                if await repo.stageChanges() {
                    let c = await repo.commit(message: settings.renderCommitMessage())
                    guard c.ok else { return await recordFailure(repo, c, during: "commit") }
                }
                let r = await repo.pull()
                if r.ok {
                    if await isPaused(repo) { return }
                    repoStates[repo.url] = .idle(lastSync: Date())
                } else {
                    await recordFailure(repo, r, during: "pull")
                }
            }
        }
        onPullFinished?()
    }

    func commitAndPush(_ repo: GitRepo) async {
        await serialized(repo) { [self] in
            guard isActive else { return }
            if await isPaused(repo) { return }
            let staged = await repo.stageChanges()
            if !staged, !(await repo.hasUnpushedCommits()) {
                return
            }
            repoStates[repo.url] = .syncing
            if staged {
                let c = await repo.commit(message: settings.renderCommitMessage())
                guard c.ok else { return await recordFailure(repo, c, during: "commit") }
            }
            var p = await repo.push()
            if !p.ok, p.stderr.contains("rejected") || p.stderr.contains("fetch first") {
                let pulled = await repo.pull()
                guard pulled.ok else { return await recordFailure(repo, pulled, during: "pull") }
                p = await repo.push()
            }
            if p.ok {
                repoStates[repo.url] = .idle(lastSync: Date())
                SyncLog.log.info("[GitSync] pushed \(repo.url.lastPathComponent, privacy: .public)")
            } else {
                await recordFailure(repo, p, during: "push")
            }
        }
    }

    /// Settings button: pull, then push whatever is pending in every repo.
    func syncNow() async {
        await pullAll()
        for repo in repos() {
            await commitAndPush(repo)
        }
    }

    /// Best effort on quit: each repo is attempted while a 20 s budget lasts. A single
    /// hung push can still run to its own 120 s timeout.
    func flushOnQuit() async {
        guard isActive, settings.pushOnQuit else { return }
        debounceTasks.values.forEach { $0.cancel() }
        let deadline = Date().addingTimeInterval(20)
        for repo in repos() where Date() < deadline {
            await commitAndPush(repo)
        }
    }

    // MARK: - Private

    /// Runs `work` after any earlier operation on the same repo has finished, so two
    /// git processes never touch one working copy at once.
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
