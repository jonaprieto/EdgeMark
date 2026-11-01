import Foundation

/// A night's sleep, read from one sentence in Spanish or English ("dormí de 11 a 7, regular",
/// "slept 8 hours") and kept as a line under `## Sleep` in the day file.
public nonisolated struct Sleep: Equatable, Sendable {
    public var bed: String?
    public var wake: String?
    public var minutes: Int
    public var note: String

    public init(bed: String?, wake: String?, minutes: Int, note: String) {
        self.bed = bed
        self.wake = wake
        self.minutes = minutes
        self.note = note
    }

    /// `8h` or `7h30`.
    public static func duration(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    /// The line in the day file: `- 23:00-07:00 8h regular`.
    public var line: String {
        var parts = ["-"]
        if let bed, let wake { parts.append("\(bed)-\(wake)") }
        parts.append(Self.duration(minutes))
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " ")
    }

    private static let filler: Set<String> = [
        "dormi", "dormí", "dormir", "dormido", "duermo", "me", "acoste", "acosté", "levante", "levanté", "desperte", "desperté",
        "de", "desde", "a", "al", "hasta", "las", "la", "y", "i", "slept", "sleep", "went", "to", "bed", "from", "until", "woke", "up", "at", "and",
    ]

    private static let duration = #"(?<![\d.,:])(\d{1,2})(?:[.,](\d))?\s*(?:h|hrs?|horas?|hours?)(?![a-zñ])(?:\s*(\d{2})(?!\d)|\s+y\s+(media|cuarto))?"#
    private static let clock = #"(?<![\d.\:])(\d{1,2})(?:[.\:](\d{2}))?\s*(am|pm|a\.\s?m\.?|p\.\s?m\.?)?(?![\w\:]|\s*(?:horas?|hours?|hrs?)\b)"#

    /// Nil when the sentence gives neither two times nor a length of sleep.
    public static func parse(_ sentence: String) -> Sleep? {
        byClock(sentence) ?? byLength(sentence)
    }

    private static func byClock(_ sentence: String) -> Sleep? {
        guard let regex = try? NSRegularExpression(pattern: clock, options: .caseInsensitive) else { return nil }
        let source = sentence as NSString
        let found = regex.matches(in: sentence, range: NSRange(location: 0, length: source.length))
        guard found.count >= 2 else { return nil }
        func field(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range).lowercased()
        }
        func time(_ match: NSTextCheckingResult, night: Bool) -> (hour: Int, minute: Int)? {
            guard let hour = field(match, 1).flatMap({ Int($0) }), hour < 24 else { return nil }
            let minute = field(match, 2).flatMap { Int($0) } ?? 0
            guard minute < 60 else { return nil }
            return (clockHour(hour, marker: field(match, 3), night: night), minute)
        }
        guard let start = time(found[0], night: true), let end = time(found[1], night: false) else { return nil }
        let asleep = (end.hour * 60 + end.minute - start.hour * 60 - start.minute + 1440) % 1440
        guard asleep > 0 else { return nil }
        let before = source.substring(to: found[0].range.location)
        let after = source.substring(from: found[1].range.location + found[1].range.length)
        return Sleep(bed: stamp(start), wake: stamp(end), minutes: asleep, note: note(before, after))
    }

    /// Without am or pm, a bedtime from 7 to 11 is the evening and 12 is midnight.
    private static func clockHour(_ hour: Int, marker: String?, night: Bool) -> Int {
        if let marker {
            if marker.hasPrefix("p") { return hour < 12 ? hour + 12 : hour }
            return hour == 12 ? 0 : hour
        }
        guard night else { return hour }
        if hour == 12 { return 0 }
        return (7 ... 11).contains(hour) ? hour + 12 : hour
    }

    private static func stamp(_ time: (hour: Int, minute: Int)) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    private static func byLength(_ sentence: String) -> Sleep? {
        guard let regex = try? NSRegularExpression(pattern: duration, options: .caseInsensitive) else { return nil }
        let source = sentence as NSString
        guard let match = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: source.length)) else { return nil }
        func field(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range).lowercased()
        }
        guard let hours = field(1).flatMap({ Int($0) }) else { return nil }
        var minutes = hours * 60 + (field(2).flatMap { Int($0) } ?? 0) * 6 + (field(3).flatMap { Int($0) } ?? 0)
        minutes += field(4) == "media" ? 30 : field(4) == "cuarto" ? 15 : 0
        guard (1 ... 1440).contains(minutes) else { return nil }
        let before = source.substring(to: match.range.location)
        let after = source.substring(from: match.range.location + match.range.length)
        return Sleep(bed: nil, wake: nil, minutes: minutes, note: note(before, after))
    }

    /// What surrounds the times, without the words that only introduce them.
    private static func note(_ before: String, _ after: String) -> String {
        func trimmed(_ text: String) -> [String] {
            var words = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            while let first = words.first, filler.contains(first.lowercased()) {
                words.removeFirst()
            }
            while let last = words.last, filler.contains(last.lowercased()) {
                words.removeLast()
            }
            return words
        }
        return (trimmed(before) + trimmed(after)).joined(separator: " ")
    }

    /// The nights recorded under `## Sleep` in a day file.
    public static func entries(in text: String) -> [Sleep] {
        var inSection = false
        var out: [Sleep] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                inSection = line == Journal.Kind.sleep.heading
                continue
            }
            guard inSection, line.hasPrefix("- ") else { continue }
            var words = line.dropFirst(2).split(separator: " ").map(String.init)
            var bed: String?
            var wake: String?
            if let first = words.first, first.count == 11, first.contains("-") {
                let parts = first.split(separator: "-").map(String.init)
                (bed, wake) = (parts.first, parts.last)
                words.removeFirst()
            }
            guard let length = words.first, let minutes = minutes(in: length) else { continue }
            out.append(Sleep(bed: bed, wake: wake, minutes: minutes, note: words.dropFirst().joined(separator: " ")))
        }
        return out
    }

    private static func minutes(in length: String) -> Int? {
        let parts = length.split(separator: "h", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let hours = Int(parts[0]) else { return nil }
        return hours * 60 + (Int(parts[1]) ?? 0)
    }

    /// Average length of `nights`, nil when there are none.
    public static func average(_ nights: [Sleep]) -> Int? {
        nights.isEmpty ? nil : nights.map(\.minutes).reduce(0, +) / nights.count
    }
}
