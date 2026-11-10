import Foundation

/// The day files in `Journal/`: one Markdown file per day, one section per kind of entry.
/// Foundation only, so the rules are unit tested by the `EdgeJournalLogic` SPM target.
public nonisolated enum Journal {
    public enum Kind: String, CaseIterable, Sendable {
        case fromYesterday, sleep, meal, idea, done, todo

        var heading: String {
            switch self {
            case .fromYesterday: "## From yesterday"
            case .sleep: "## Sleep"
            case .meal: "## Meals"
            case .idea: "## Ideas"
            case .done: "## Done"
            case .todo: "## Todos"
            }
        }
    }

    /// Which meal an entry is. It leads the line: `- 13:10 Lunch: bandeja paisa`.
    public enum Meal: String, CaseIterable, Sendable {
        case breakfast = "Breakfast", lunch = "Lunch", dinner = "Dinner", other = "Other"

        /// The likely one at this hour.
        public init(at date: Date, calendar: Calendar = .current) {
            switch calendar.component(.hour, from: date) {
            case 5 ..< 11: self = .breakfast
            case 11 ..< 16: self = .lunch
            case 18 ..< 22: self = .dinner
            default: self = .other
            }
        }

        var prefix: String {
            "\(rawValue): "
        }

        /// `text` as the line writes it.
        public func labeled(_ text: String) -> String {
            prefix + text
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

        /// Paths of the photos in this entry, relative to its file.
        public var images: [String] {
            Journal.imagePaths(in: text)
        }

        /// Nil for anything but a meal, and for a meal written before meals had a name.
        public var meal: Meal? {
            kind == .meal ? Meal.allCases.first { text.hasPrefix($0.prefix) } : nil
        }

        public var words: String {
            Journal.withoutImages(meal.map { String(text.dropFirst($0.prefix.count)) } ?? text)
        }

        /// The `#tags` in its words, lowercased. `#4` is a number, not a tag.
        public var tags: [String] {
            words.split(whereSeparator: \.isWhitespace).compactMap(Journal.tag)
        }
    }

    /// A private capture, whose text is sealed: what its file name says about it.
    public struct PrivateEntry: Hashable, Identifiable, Sendable {
        public let path: String
        public let day: String
        public let time: String
        public let kind: String

        public var id: String {
            path
        }
    }

    public static let folder = "Journal"

    /// `2026-10-31`, in the calendar's time zone.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        format("yyyy-MM-dd", date, calendar)
    }

    /// `15:30`, in the calendar's time zone.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        format("HH:mm", date, calendar)
    }

    /// `2026-10-31T15:30`: a due tag's value when the todo is a reminder.
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        format("yyyy-MM-dd'T'HH:mm", date, calendar)
    }

    public static func path(for date: Date, calendar: Calendar = .current) -> String {
        "\(folder)/\(day(date, calendar: calendar)).md"
    }

    /// The note's title is its first line, so the file name and the title agree.
    public static func emptyDay(for date: Date, calendar: Calendar = .current) -> String {
        "# \(day(date, calendar: calendar))\n"
    }

    /// One line of a day file. Dictation can run over lines, an entry cannot.
    public static func entry(_ text: String, kind: Kind, at date: Date, due: String? = nil, calendar: Calendar = .current) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard kind == .todo else { return "- \(time(date, calendar: calendar)) \(flat)" }
        let dueTag = due.map { " due:\($0)" } ?? ""
        return "- [ ] \(flat)\(dueTag)"
    }

    /// `#Casa,` reads as `#casa`. Nil for a word that is no tag: `#4` is a number.
    public static func tag(_ word: some StringProtocol) -> String? {
        guard word.hasPrefix("#") else { return nil }
        let tag = word.dropFirst().trimmingCharacters(in: .punctuationCharacters).lowercased()
        return tag.contains(where: \.isLetter) ? "#\(tag)" : nil
    }

    /// The tags of `entries`, each once, most used first. A tie goes to the one met first, so
    /// newest first when `entries` is: the Done buttons.
    public static func commonTags(_ entries: [Entry]) -> [String] {
        let all = entries.flatMap(\.tags)
        let counts = all.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }.map(\.element)
    }

    /// `text` with `tag` added at the end, or taken out when it is already there: a chip's tap.
    public static func toggling(_ tag: String, in text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = words.filter { Journal.tag($0) != tag }
        return (kept.count < words.count ? kept : words + [tag]).joined(separator: " ")
    }

    /// `text` with `entry` at the end of its section. A missing section is added in its place
    /// in the fixed order: from yesterday, sleep, meals, ideas, done, todos.
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

    /// `text` without `entry`'s line, nil when the line changed since it was read.
    public static func removing(_ entry: Entry, from text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(of: "- \(entry.time) \(entry.text)") else { return nil }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// Reads `Journal/2026-10-31-22-14-idea.md.age`. Nil for any other file.
    public static func privateEntry(path: String) -> PrivateEntry? {
        let name = (path as NSString).lastPathComponent
        guard path.hasPrefix("\(folder)/"), name.hasSuffix(".md.age") else { return nil }
        let parts = name.dropLast(7).split(separator: "-").map(String.init)
        guard parts.count >= 6, parts[0].count == 4, parts.prefix(5).allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return PrivateEntry(
            path: path,
            day: parts[0 ..< 3].joined(separator: "-"),
            time: "\(parts[3]):\(parts[4])",
            kind: parts[5],
        )
    }

    /// Paths of the Markdown images in `text`, in order.
    public static func imagePaths(in text: String) -> [String] {
        let source = text as NSString
        return imagePattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range(at: 1))
        }
    }

    /// `text` with its Markdown images taken out.
    public static func withoutImages(_ text: String) -> String {
        imagePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static var imagePattern: NSRegularExpression {
        // A fixed pattern, so this cannot fail.
        try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#)
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
