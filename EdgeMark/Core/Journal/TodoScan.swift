import Foundation

/// One task line: `- [ ] text due:2026-11-02`, in any note. A time, as in `due:2026-11-02T15:30`,
/// makes it a reminder.
public nonisolated struct Todo: Hashable, Identifiable, Sendable {
    public let path: String
    /// Zero-based line in the file at scan time.
    public let line: Int
    /// The whole line, which a toggle compares before it writes.
    public let raw: String
    /// The task without its box and due tag.
    public let text: String
    public let done: Bool
    public let due: String?
    public let time: String?

    public var id: String {
        "\(path):\(line)"
    }

    /// `2026-11-02` or `2026-11-02 15:30`, which sort correctly as text.
    public var when: String? {
        due.map { [$0, time].compactMap(\.self).joined(separator: " ") }
    }

    /// When a reminder rings, nil for a todo with no time.
    public func ringsAt(calendar: Calendar = .current) -> Date? {
        guard time != nil, let parts = when?.split(whereSeparator: { "- :".contains($0) }).compactMap({ Int($0) }), parts.count == 5 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))
    }
}

/// Finds and edits task lines. Everything stays plain Markdown, so a todo is any `- [ ]` line in
/// any note and existing notes work unchanged.
public nonisolated enum TodoScan {
    public enum Group: Int, CaseIterable, Comparable, Sendable {
        case overdue, today, dated, undated

        public static func < (a: Group, b: Group) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// A stretch of a note: Markdown to read, or a task to tick.
    public enum Segment: Hashable, Sendable {
        case text(String)
        case task(Todo)
    }

    /// The note cut around its tasks, in order, so a reader can draw each one as a checkbox.
    public static func segments(of text: String, path: String) -> [Segment] {
        let tasks = Dictionary(uniqueKeysWithValues: todos(in: text, path: path).map { ($0.line, $0) })
        var out: [Segment] = []
        var pending: [String] = []

        func flush() {
            let chunk = pending.joined(separator: "\n")
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(chunk)) }
            pending = []
        }

        for (index, line) in lines(text).enumerated() {
            if let task = tasks[index] {
                flush()
                out.append(.task(task))
            } else {
                pending.append(line)
            }
        }
        flush()
        return out
    }

    public static func todos(in text: String, path: String) -> [Todo] {
        var out: [Todo] = []
        var inFence = false
        for (index, line) in lines(text).enumerated() {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, let (done, body) = parse(trimmed) else { continue }
            let (words, due, time) = splitDue(body)
            out.append(Todo(path: path, line: index, raw: line, text: words, done: done, due: due, time: time))
        }
        return out
    }

    /// `today` is `yyyy-MM-dd`, which compares correctly as text.
    public static func group(_ todo: Todo, today: String) -> Group {
        guard let due = todo.due else { return .undated }
        return due < today ? .overdue : due == today ? .today : .dated
    }

    /// Soonest first; undated keep their order.
    public static func sorted(_ todos: [Todo], today: String) -> [Todo] {
        todos.enumerated().sorted {
            let (a, b) = ($0.element, $1.element)
            let (x, y) = (group(a, today: today), group(b, today: today))
            if x != y { return x < y }
            if let p = a.when, let q = b.when, p != q { return p < q }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// `text` with the box flipped, nil when the line changed since the scan.
    public static func toggled(_ todo: Todo, in text: String) -> String? {
        rewriting(todo, in: text) { line in
            let (old, new) = todo.done ? (todo.raw.contains("[X]") ? "[X]" : "[x]", "[ ]") : ("[ ]", "[x]")
            guard let box = line.range(of: old) else { return line }
            return line.replacingCharacters(in: box, with: new)
        }
    }

    /// `text` with the due tag replaced, removed when `due` is nil, nil when the line changed.
    public static func settingDue(_ due: String?, on todo: Todo, in text: String) -> String? {
        rewriting(todo, in: text) { line in
            var kept = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            kept.removeAll(where: isDueTag)
            let bare = kept.joined(separator: " ")
            return due.map { "\(bare) due:\($0)" } ?? bare
        }
    }

    private static func rewriting(_ todo: Todo, in text: String, _ change: (String) -> String) -> String? {
        var all = lines(text)
        guard todo.line < all.count, all[todo.line] == todo.raw else { return nil }
        all[todo.line] = change(all[todo.line])
        return all.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The box state and the text after it, for a line with leading space removed.
    private static func parse(_ line: Substring) -> (done: Bool, body: Substring)? {
        guard let bullet = line.first, "-*+".contains(bullet) else { return nil }
        let rest = line.dropFirst()
        guard rest.hasPrefix(" [") else { return nil }
        let mark = rest.dropFirst(2)
        guard let state = mark.first, " xX".contains(state), mark.dropFirst().hasPrefix("] ") else { return nil }
        return (state != " ", mark.dropFirst(3))
    }

    private static func splitDue(_ body: Substring) -> (text: String, due: String?, time: String?) {
        let words = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let tag = words.last(where: isDueTag)?.dropFirst(4).split(separator: "T").map(String.init)
        return (words.filter { !isDueTag($0) }.joined(separator: " "), tag?.first, tag?.dropFirst().first)
    }

    private static func isDueTag(_ word: String) -> Bool {
        word.range(of: #"^due:\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$"#, options: .regularExpression) != nil
    }
}
