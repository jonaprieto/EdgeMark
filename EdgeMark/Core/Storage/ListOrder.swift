import Foundation

/// Foundation-only order of the note list's rows, shared by the app and the SPM test
/// target. A folder and a note both sort by a name or a date, so one list can mix them,
/// as Gists does.
nonisolated enum ListOrder {
    /// Whether row `a` comes before row `b`: by name when `byName`, otherwise by date,
    /// with a missing date (an empty folder) last in either direction.
    static func precedes(
        _ a: (name: String, date: Date?),
        _ b: (name: String, date: Date?),
        byName: Bool,
        ascending: Bool,
    ) -> Bool {
        if byName {
            return a.name.localizedCaseInsensitiveCompare(b.name) == (ascending ? .orderedAscending : .orderedDescending)
        }
        switch (a.date, b.date) {
        case let (aDate?, bDate?): return ascending ? aDate < bDate : aDate > bDate
        case (nil, _): return false
        case (_, nil): return true
        }
    }
}
