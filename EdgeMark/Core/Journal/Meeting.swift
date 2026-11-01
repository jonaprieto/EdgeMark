import Foundation

/// Meeting notes in `Meetings/`: the title is the day and the name, `2026-11-03 Felipe`.
public nonisolated enum Meeting {
    public static let folder = "Meetings"
    /// Body of a new meeting note, after its title.
    public static let template = "## Ideas\n\n"

    public struct Event: Hashable, Sendable {
        public let name: String
        public let start: Date
        public let place: String?

        public init(name: String, start: Date, place: String? = nil) {
            self.name = name
            self.start = start
            self.place = place
        }
    }

    /// One line of the Meetings list: an event, a note, or both when their titles agree.
    public struct Row: Hashable, Identifiable, Sendable {
        public let day: String
        public let name: String
        public let start: Date?
        public let path: String?
        public var place: String?

        public var id: String {
            title
        }

        public var title: String {
            Meeting.title(day: day, name: name)
        }
    }

    /// Body of a meeting note added by hand: its hour and place on lines of their own, a short
    /// note, then room for ideas.
    public static func body(time: String?, place: String? = nil, note: String = "") -> String {
        var head = ""
        if let time { head += "Time: \(time)\n" }
        if let place, !place.isEmpty { head += "Place: \(place)\n" }
        if !head.isEmpty { head += "\n" }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return head + (text.isEmpty ? "" : "\(text)\n\n") + template
    }

    private static func field(_ name: String, inNote text: String) -> String? {
        text.split(separator: "\n").prefix(4).first { $0.hasPrefix("\(name): ") }.map { String($0.dropFirst(name.count + 2)) }
    }

    /// The `HH:mm` a meeting note keeps on its own line, if any.
    public static func time(inNote text: String) -> String? {
        guard let value = field("Time", inNote: text) else { return nil }
        let parts = value.split(separator: ":")
        return parts.count == 2 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) } ? value : nil
    }

    /// Where a meeting note says it happens, if it does.
    public static func place(inNote text: String) -> String? {
        field("Place", inNote: text)
    }

    /// A place that is a link or a video call, which no map can show.
    public static func isOnline(_ place: String) -> Bool {
        let text = place.lowercased()
        return ["://", "zoom", "google meet", "microsoft teams", "webex"].contains { text.contains($0) }
    }

    /// Whether what a map search found is `place` and not just a word of it: most of the found
    /// name must be in `place`, so `Parque 93` is `Parque de la 93, Bogotá` and `Calle 93` is not.
    public static func isSamePlace(_ found: String, as place: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { !["de", "del", "la", "las", "el", "los", "the", "of"].contains($0) }
        }
        let name = words(found)
        let asked = Set(words(place))
        return name.filter(asked.contains).count * 2 > name.count
    }

    /// When a meeting falls, for the agenda's sections.
    public enum Bucket: Int, CaseIterable, Comparable, Sendable {
        case today, tomorrow, thisWeek, nextWeek, later

        public static func < (a: Bucket, b: Bucket) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// Tomorrow beats the week it falls in, and a past day counts as today so nothing goes missing.
    public static func bucket(day: String, now: Date, calendar: Calendar = .current) -> Bucket {
        let today = Journal.day(now, calendar: calendar)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let nextWeekEnd = calendar.date(byAdding: .day, value: 7, to: week.end) else { return .later }
        // The interval's end is the first day after the week, so both compare as "before".
        let weekEnd = Journal.day(week.end, calendar: calendar)
        let nextEnd = Journal.day(nextWeekEnd, calendar: calendar)
        if day <= today { return .today }
        if day == Journal.day(tomorrow, calendar: calendar) { return .tomorrow }
        if day < weekEnd { return .thisWeek }
        return day < nextEnd ? .nextWeek : .later
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

    /// The day of a `yyyy-MM-dd` string, for showing it.
    public static func date(day: String, calendar: Calendar = .current) -> Date? {
        start(day: day, time: "12:00", calendar: calendar)
    }

    private static func start(day: String, time: String?, calendar: Calendar) -> Date? {
        guard let time else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(time)")
    }

    /// Events, plus notes for days from `today` on that match no event, soonest first.
    public static func rows(events: [Event], notes: [(path: String, title: String, time: String?, place: String?)], today: String, calendar: Calendar = .current) -> [Row] {
        let paths = Dictionary(notes.map { ($0.title, $0.path) }) { first, _ in first }
        var rows = events.map { event -> Row in
            let day = Journal.day(event.start, calendar: calendar)
            return Row(day: day, name: event.name, start: event.start, path: paths[title(day: day, name: event.name)], place: event.place)
        }
        let taken = Set(rows.map(\.title))
        for note in notes where !taken.contains(note.title) {
            guard let (day, name) = parse(title: note.title), day >= today else { continue }
            rows.append(Row(day: day, name: name, start: start(day: day, time: note.time, calendar: calendar), path: note.path, place: note.place))
        }
        return rows.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
        }
    }
}
