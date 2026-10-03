import Foundation

/// Sync status of one repo, or of all repos combined (see `aggregate`).
enum SyncState: Equatable {
    /// The active root is not a git repo with an `origin`, or sync is disabled.
    case off
    case idle(lastSync: Date?)
    /// Local edits or commits are waiting for the next push.
    case pending
    case syncing
    /// A rebase is paused on these files until the user resolves them in a terminal.
    case conflict([String])
    case error(String)
    /// The secrets guard kept these files (repo-relative paths) out of the last commit.
    case held([String])

    /// Worst state wins: conflict, then error, then held (paths of every held repo),
    /// then syncing, then pending, then idle (latest sync time).
    static func aggregate(_ states: [SyncState]) -> SyncState {
        if let c = states.first(where: { if case .conflict = $0 { return true }; return false }) { return c }
        if let e = states.first(where: { if case .error = $0 { return true }; return false }) { return e }
        let held = states.flatMap { state -> [String] in
            if case let .held(paths) = state { return paths }
            return []
        }
        if states.contains(where: { if case .held = $0 { return true }; return false }) { return .held(held) }
        if states.contains(.syncing) { return .syncing }
        if states.contains(.pending) { return .pending }
        let syncTimes = states.compactMap { state -> Date?? in
            if case let .idle(lastSync) = state { return .some(lastSync) }
            return nil
        }
        guard !syncTimes.isEmpty else { return .off }
        return .idle(lastSync: syncTimes.compactMap { $0 }.max())
    }

    /// One line of bounded length for tooltips and the settings status row: at most
    /// three conflicted files are named, and error text is flattened and capped.
    var summary: String {
        switch self {
        case .off: "Sync off"
        case .syncing: "Syncing"
        case .pending: "Changes not pushed yet"
        case .conflict([]): "Rebase in progress"
        case let .conflict(files): "Conflict: \(Self.fileList(files))"
        case let .error(message): "Error: \(Self.oneLine(message))"
        case let .held(paths): "\(paths.count) file(s) held back: possible secrets"
        case .idle(nil): "Not synced yet"
        case let .idle(date?): "Synced \(Self.relative.localizedString(for: date, relativeTo: Date()))"
        }
    }

    /// Longest error text or file names `summary` shows, in characters.
    static let maxDetailLength = 200

    /// The first three files (flattened and capped like error text), then "and N more".
    private static func fileList(_ files: [String]) -> String {
        let shown = oneLine(files.prefix(3).joined(separator: ", "))
        return files.count > 3 ? "\(shown) and \(files.count - 3) more" : shown
    }

    /// `text` on one line (line breaks become spaces), cut to `maxDetailLength` characters.
    private static func oneLine(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > maxDetailLength ? String(flat.prefix(maxDetailLength - 3)) + "..." : flat
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
