import Foundation

/// The day files in `Journal/`: one Markdown file per day, one section per kind of entry.
/// Foundation only, so the rules are unit tested by the `EdgeJournalLogic` SPM target.
public nonisolated enum Journal {
    public enum Kind: String, CaseIterable, Sendable {
        case meal, idea, todo

        var heading: String {
            switch self {
            case .meal: "## Meals"
            case .idea: "## Ideas"
            case .todo: "## Todos"
            }
        }
    }

    /// One timed line of a day file.
    public struct Entry: Hashable, Identifiable, Sendable {
        public let path: String
        public let day: String
        public let time: String
        public let kind: Kind
        public let text: String

        public var id: String {
            "\(path) \(time) \(text)"
        }
    }

    public static let folder = "Journal"

    /// `2026-10-31`, in the calendar's time zone.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        format("yyyy-MM-dd", date, calendar)
    }

    public static func path(for date: Date, calendar: Calendar = .current) -> String {
        "\(folder)/\(day(date, calendar: calendar)).md"
    }

    /// The note's title is its first line, so the file name and the title agree.
    public static func emptyDay(for date: Date, calendar: Calendar = .current) -> String {
        "# \(day(date, calendar: calendar))\n"
    }

    /// One line of a day file. Dictation can run over lines, an entry cannot.
    public static func entry(_ text: String, kind: Kind, at date: Date, due: Date? = nil, calendar: Calendar = .current) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard kind == .todo else { return "- \(format("HH:mm", date, calendar)) \(flat)" }
        let dueTag = due.map { " due:\(day($0, calendar: calendar))" } ?? ""
        return "- [ ] \(flat)\(dueTag)"
    }

    /// `text` with `entry` at the end of its section. A missing section is added in its place
    /// in the fixed order: meals, ideas, todos.
    public static func appending(_ entry: String, under kind: Kind, to text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" {
            lines.removeLast()
        }
        if let start = lines.firstIndex(of: kind.heading) {
            var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            while end > start + 1, lines[end - 1].isEmpty {
                end -= 1
            }
            if end == start + 1 {
                lines.insert("", at: end)
                end += 1
            }
            lines.insert(entry, at: end)
        } else {
            let later = Kind.allCases.drop { $0 != kind }.dropFirst().map(\.heading)
            if let next = lines.firstIndex(where: later.contains) {
                lines.insert(contentsOf: [kind.heading, "", entry, ""], at: next)
            } else {
                lines += ["", kind.heading, "", entry]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The timed lines of a day file, in file order. Tasks are todos, not entries.
    public static func entries(in text: String, path: String) -> [Entry] {
        let day = String((path as NSString).lastPathComponent.prefix(10))
        var kind: Kind?
        var out: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                kind = Kind.allCases.first { $0.heading == line }
                continue
            }
            guard let kind, kind != .todo, line.hasPrefix("- ") else { continue }
            let words = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, isTime(words[0]) else { continue }
            out.append(Entry(path: path, day: day, time: words[0], kind: kind, text: words[1]))
        }
        return out
    }

    private static func isTime(_ word: String) -> Bool {
        let parts = word.split(separator: ":")
        return parts.count == 2 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) }
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
