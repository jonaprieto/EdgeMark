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

    /// Every readable line, oldest first. A line the union merge mangled is skipped.
    public static func all(in log: String) -> [PlaceLine] {
        log.split(separator: "\n").compactMap { try? JSONDecoder().decode(PlaceLine.self, from: Data($0.utf8)) }
    }
}
