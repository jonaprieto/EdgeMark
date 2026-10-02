import Foundation

/// Sync status of one repo, or of all repos combined (see `aggregate`).
enum SyncState: Equatable {
    /// The active root is not a git repo with an `origin`, or sync is disabled.
    case off
    case idle(lastSync: Date?)
    case syncing
    /// A rebase is paused on these files until the user resolves them in a terminal.
    case conflict([String])
    case error(String)

    /// Worst state wins: conflict, then error, then syncing, then idle (latest sync time).
    static func aggregate(_ states: [SyncState]) -> SyncState {
        if let c = states.first(where: { if case .conflict = $0 { return true }; return false }) { return c }
        if let e = states.first(where: { if case .error = $0 { return true }; return false }) { return e }
        if states.contains(.syncing) { return .syncing }
        let syncTimes = states.compactMap { state -> Date?? in
            if case let .idle(lastSync) = state { return .some(lastSync) }
            return nil
        }
        guard !syncTimes.isEmpty else { return .off }
        return .idle(lastSync: syncTimes.compactMap { $0 }.max())
    }

    /// One line for tooltips and the settings status row.
    var summary: String {
        switch self {
        case .off: "Sync off"
        case .syncing: "Syncing"
        case let .conflict(files): "Conflict: \(files.joined(separator: ", "))"
        case let .error(message): "Error: \(message)"
        case .idle(nil): "Not synced yet"
        case let .idle(date?): "Synced \(Self.relative.localizedString(for: date, relativeTo: Date()))"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
