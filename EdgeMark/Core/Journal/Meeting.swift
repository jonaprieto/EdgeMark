import Foundation

/// Meeting notes in `Meetings/`: the title is the day and the name, `2026-11-03 Felipe`.
public nonisolated enum Meeting {
    public static let folder = "Meetings"
    /// Body of a new meeting note, after its title.
    public static let template = "## Ideas\n\n"

    public struct Event: Hashable, Sendable {
        public let name: String
        public let start: Date

        public init(name: String, start: Date) {
            self.name = name
            self.start = start
        }
    }

    /// One line of the Meetings list: an event, a note, or both when their titles agree.
    public struct Row: Hashable, Identifiable, Sendable {
        public let day: String
        public let name: String
        public let start: Date?
        public let path: String?

        public var id: String {
            title
        }

        public var title: String {
            Meeting.title(day: day, name: name)
        }
    }

    public static func title(day: String, name: String) -> String {
        "\(day) \(name)"
    }

    /// The day and name of a meeting note's title, nil when it does not start with a date.
    public static func parse(title: String) -> (day: String, name: String)? {
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        guard let day = parts.first, day.split(separator: "-").map(\.count) == [4, 2, 2], day.allSatisfy({ $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return (day, parts.count > 1 ? parts[1] : "")
    }

    /// Events, plus notes for days from `today` on that match no event, soonest first.
    public static func rows(events: [Event], notes: [(path: String, title: String)], today: String, calendar: Calendar = .current) -> [Row] {
        let paths = Dictionary(notes.map { ($0.title, $0.path) }) { first, _ in first }
        var rows = events.map { event -> Row in
            let day = Journal.day(event.start, calendar: calendar)
            return Row(day: day, name: event.name, start: event.start, path: paths[title(day: day, name: event.name)])
        }
        let taken = Set(rows.map(\.title))
        for note in notes where !taken.contains(note.title) {
            guard let (day, name) = parse(title: note.title), day >= today else { continue }
            rows.append(Row(day: day, name: name, start: nil, path: note.path))
        }
        return rows.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
        }
    }
}
