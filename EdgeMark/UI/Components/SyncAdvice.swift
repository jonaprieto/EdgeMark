import Foundation

/// What went wrong and what to do about it, for a paused rebase or held files.
/// Shown in the footer menu and tooltip and in Settings > Sync.
struct SyncAdvice {
    /// Working copy the advice is about (notes root or a gist clone).
    let repo: URL
    let problem: String
    let fix: String

    /// Problem and fix on one line, for tooltips and Settings.
    var text: String {
        "\(problem) \(fix)"
    }

    /// Longest file name the advice shows, in characters.
    private static let maxNameLength = 60

    /// Advice for the current state of `sync`, or nil when nothing needs the user.
    @MainActor
    static func current(_ sync: GitSync, l10n: L10n) -> SyncAdvice? {
        switch sync.state {
        case .conflict:
            let conflicted = sync.repos().lazy.compactMap { repo -> (URL, [String])? in
                if case let .conflict(files) = sync.repoStates[repo.url] { return (repo.url, files) }
                return nil
            }.first
            guard let (repo, files) = conflicted else { return nil }
            let name = repo.lastPathComponent
            guard let first = files.first else {
                return SyncAdvice(repo: repo, problem: l10n.t("sync.advice.rebase", name), fix: l10n["sync.advice.rebaseFix"])
            }
            let shown = files.count > 1
                ? l10n.t("sync.advice.more", bounded(first), "\(files.count - 1)")
                : bounded(first)
            return SyncAdvice(repo: repo, problem: l10n.t("sync.advice.conflict", name, shown), fix: l10n["sync.advice.conflictFix"])
        case .held:
            let held = sync.heldFiles.sorted { $0.key.path < $1.key.path }
            guard let repo = held.first?.key else { return nil }
            let count = held.reduce(0) { $0 + $1.value.count }
            return SyncAdvice(repo: repo, problem: l10n.t("sync.advice.held", "\(count)"), fix: l10n["sync.advice.heldFix"])
        default:
            return nil
        }
    }

    /// Shell command that opens a terminal session's view of the repo: `cd` into it and
    /// show `git status`. The path is single-quoted for the shell.
    var fixCommands: String {
        let quoted = repo.path.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(quoted)' && git status"
    }

    private static func bounded(_ name: String) -> String {
        let flat = name.components(separatedBy: .newlines).joined(separator: " ")
        return flat.count > maxNameLength ? String(flat.prefix(maxNameLength - 3)) + "..." : flat
    }
}
