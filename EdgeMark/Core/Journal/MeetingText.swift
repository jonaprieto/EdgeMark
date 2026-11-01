import Foundation

/// Reads a meeting typed or dictated in one sentence, in Spanish or English: "Felipe martes 3pm",
/// "mañana a las 10 dentista", "call with Ana next monday at 2pm". Rules, not a model, so it works
/// offline and always gives the same answer. The sheet shows the fields, so a wrong guess is fixed
/// by hand.
public nonisolated enum MeetingText {
    public struct Parsed: Equatable, Sendable {
        public var name: String
        /// The day, at its hour when `hasTime`. Nil when the sentence names no day or time.
        public var date: Date?
        public var hasTime: Bool
    }

    private static let meridiem = #"(am|pm|a\.\s?m\.?|p\.\s?m\.?)"#
    private static let part = #"(?:\s+(?:de|en|por)\s+la\s+(ma[nñ]ana|tarde|noche))?"#
    private static let lead = #"(?:(?:a\s+las?|at)\s+)?"#
    private static let weekdays = [
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "miércoles": 4, "jueves": 5, "viernes": 6, "sabado": 7, "sábado": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
    private static let months = [
        "enero": 1, "ene": 1, "january": 1, "jan": 1, "febrero": 2, "feb": 2, "february": 2, "marzo": 3, "mar": 3, "march": 3,
        "abril": 4, "abr": 4, "april": 4, "apr": 4, "mayo": 5, "may": 5, "junio": 6, "jun": 6, "june": 6, "julio": 7, "jul": 7, "july": 7,
        "agosto": 8, "ago": 8, "august": 8, "aug": 8, "septiembre": 9, "sep": 9, "sept": 9, "september": 9,
        "octubre": 10, "oct": 10, "october": 10, "noviembre": 11, "nov": 11, "november": 11, "diciembre": 12, "dic": 12, "december": 12, "dec": 12,
    ]
    private static let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    private static let dayNames = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    public static func parse(_ sentence: String, now: Date, calendar: Calendar = .current) -> Parsed {
        var rest = " \(sentence) "
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var time: (hour: Int, minute: Int)?

        func take(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let source = rest as NSString
            guard let match = regex.firstMatch(in: rest, range: NSRange(location: 0, length: source.length)) else { return nil }
            let groups = (1 ..< match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range).lowercased()
            }
            rest = source.replacingCharacters(in: match.range, with: " ")
            return groups
        }

        func dated(year: Int?, month: Int, day dayOfMonth: Int) -> Date? {
            var parts = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: dayOfMonth)
            guard var date = calendar.date(from: parts) else { return nil }
            if year == nil, date < today {
                parts.year = (parts.year ?? 0) + 1
                date = calendar.date(from: parts) ?? date
            }
            return date
        }

        if let g = take(#"\b(\d{4})-(\d{2})-(\d{2})\b"#), let y = Int(g[0] ?? ""), let m = Int(g[1] ?? ""), let d = Int(g[2] ?? "") {
            day = dated(year: y, month: m, day: d)
        } else if let g = take(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\b"#), let d = Int(g[0] ?? ""), let m = Int(g[1] ?? "") {
            day = dated(year: g[2].flatMap { Int($0) }, month: m, day: d)
        }

        if let g = take(#"\b\#(lead)(\d{1,2})[:.h](\d{2})\s*\#(meridiem)?\#(part)(?!\w)"#), let h = Int(g[0] ?? ""), let m = Int(g[1] ?? "") {
            time = (hour(h, marker: g[2] ?? g[3]), m)
        } else if let g = take(#"\b\#(lead)(\d{1,2})\s*\#(meridiem)\#(part)(?!\w)"#), let h = Int(g[0] ?? "") {
            time = (hour(h, marker: g[1]), 0)
        } else if let g = take(#"\b\#(lead)(\d{1,2})\s*h\b"#), let h = Int(g[0] ?? "") {
            time = (hour(h, marker: nil), 0)
        } else if let g = take(#"\b(?:a\s+las?|at)\s+(\d{1,2})(?:\s+y\s+(media|cuarto))?\#(part)(?!\w)"#), let h = Int(g[0] ?? "") {
            time = (hour(h, marker: g[2]), g[1] == "media" ? 30 : g[1] == "cuarto" ? 15 : 0)
        }
        _ = take(#"\b(?:por|en)\s+la\s+(?:ma[nñ]ana|tarde|noche)\b"#)

        if day == nil {
            if take(#"\bpasado\s+ma[nñ]ana(?!\w)"#) != nil {
                day = calendar.date(byAdding: .day, value: 2, to: today)
            } else if take(#"\b(?:ma[nñ]ana(?!\w)|tomorrow\b)"#) != nil {
                day = calendar.date(byAdding: .day, value: 1, to: today)
            } else if take(#"\b(?:hoy|today)\b"#) != nil {
                day = today
            } else if let g = take(#"\b(?:(?:el|este|pr[oó]ximo|next|this|on)\s+)*(\#(dayNames))(?!\w)(?:\s+que\s+viene|\s+pr[oó]ximo)?"#),
                      let weekday = weekdays[g[0] ?? ""] {
                let distance = (weekday - calendar.component(.weekday, from: today) + 7) % 7
                day = calendar.date(byAdding: .day, value: distance == 0 ? 7 : distance, to: today)
            } else if let g = take(#"\b(?:el\s+)?(\d{1,2})\s+(?:de\s+)?(\#(monthNames))\b"#), let d = Int(g[0] ?? ""), let m = months[g[1] ?? ""] {
                day = dated(year: nil, month: m, day: d)
            } else if let g = take(#"\b(\#(monthNames))\s+(\d{1,2})\b"#), let m = months[g[0] ?? ""], let d = Int(g[1] ?? "") {
                day = dated(year: nil, month: m, day: d)
            } else if let g = take(#"\b(?:el|the)\s+(\d{1,2})\b"#), let d = Int(g[0] ?? "") {
                let month = calendar.component(.month, from: today)
                let thisMonth = dated(year: calendar.component(.year, from: today), month: month, day: d)
                day = thisMonth.flatMap { $0 >= today ? $0 : calendar.date(byAdding: .month, value: 1, to: $0) }
            }
        }

        var date = day
        if let time {
            let base = day ?? today
            let start = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: base)
            // A time with no day is the next time that hour comes round.
            date = day == nil && start.map { $0 <= now } == true ? start.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } : start
        }
        return Parsed(name: cleaned(rest), date: date, hasTime: time != nil)
    }

    /// 24-hour clock. Without am or pm, 1 to 7 means the afternoon: few meetings are at 3 in the night.
    private static func hour(_ hour: Int, marker: String?) -> Int {
        let afternoon = marker.map { $0.hasPrefix("p") || $0 == "tarde" || $0 == "noche" }
        let morning = marker.map { $0.hasPrefix("a") || $0.hasPrefix("ma") } ?? false
        if afternoon == true, hour < 12 { return hour + 12 }
        if morning, hour == 12 { return 0 }
        if marker == nil, (1 ... 7).contains(hour) { return hour + 12 }
        return hour
    }

    /// What is left is the name, without connectors stranded at its ends.
    private static func cleaned(_ rest: String) -> String {
        let stranded: Set<String> = ["el", "la", "a", "de", "del", "para", "on", "at", "the", "y", "-", ","]
        var words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        while let last = words.last, stranded.contains(last.lowercased()) {
            words.removeLast()
        }
        while let first = words.first, stranded.contains(first.lowercased()) {
            words.removeFirst()
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.-: "))
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
