import Foundation

/// One line of `.edgemark/places.jsonl`: where a note was finished. The log stays out of the
/// note text because notes can become public gists, exports or OpenAI input.
public nonisolated struct PlaceLine: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let logPath = ".edgemark/places.jsonl"

    public var at: String
    public var path: String
    public var lat: Double
    public var lon: Double
    public var place: String?

    public var id: String {
        at + path
    }

    /// Rounds to 3 decimals, about 110 m: the log stays in git history for good.
    public init(date: Date, path: String, latitude: Double, longitude: Double, place: String?, timeZone: TimeZone = .current) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        at = formatter.string(from: date)
        self.path = path
        lat = (latitude * 1000).rounded() / 1000
        lon = (longitude * 1000).rounded() / 1000
        self.place = place
    }

    /// One JSON object, no line break.
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Where `entry` was written: the line for its file from the same minute or the next few,
    /// since the position comes in a moment after the entry is saved.
    public static func place(of entry: Journal.Entry, in lines: [PlaceLine]) -> PlaceLine? {
        guard let minute = minutes(entry.time) else { return nil }
        return lines.first { line in
            guard line.path == entry.path, line.at.hasPrefix(entry.day), let logged = minutes(String(line.at.dropFirst(11).prefix(5))) else { return false }
            return (0 ... 2).contains(logged - minute)
        }
    }

    /// `text` for reading, with each timed entry's place after it. The note itself stays free of
    /// places, for the reason above.
    public static func annotated(_ text: String, path: String, lines places: [PlaceLine]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for entry in Journal.entries(in: text, path: path) {
            guard let place = place(of: entry, in: places)?.place,
                  let index = lines.firstIndex(of: "- \(entry.time) \(entry.text)") else { continue }
            lines[index] += " · \(place)"
        }
        return lines.joined(separator: "\n")
    }

    private static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// Every readable line, oldest first. A line the union merge mangled is skipped.
    public static func all(in log: String) -> [PlaceLine] {
        log.split(separator: "\n").compactMap { try? JSONDecoder().decode(PlaceLine.self, from: Data($0.utf8)) }
    }
}
