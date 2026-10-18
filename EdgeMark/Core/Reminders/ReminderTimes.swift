import Foundation

/// When a note reminder fires. Code owns every date; Jev only suggests one of these.
enum ReminderOption: String, CaseIterable {
    case in1h, in3h, tonight, tomorrowMorning, everyWeekday

    static let tonightHour = 20
    static let morningHour = 9

    /// The options offered at `now`: "tonight" only until an hour before it.
    static func available(now: Date, calendar: Calendar = .current) -> [ReminderOption] {
        allCases.filter { $0 != .tonight || calendar.component(.hour, from: now) < tonightHour - 1 }
    }

    var repeats: Bool {
        self == .everyWeekday
    }

    /// Triggers for `UNCalendarNotificationTrigger`: one fire date, or one weekly trigger
    /// per weekday (weekday 2...6 is Monday...Friday in Calendar).
    func triggers(now: Date, calendar: Calendar = .current) -> [DateComponents] {
        func at(_ hour: Int, daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        let fire: Date
        switch self {
        case .in1h: fire = now.addingTimeInterval(3600)
        case .in3h: fire = now.addingTimeInterval(3 * 3600)
        case .tonight: fire = at(Self.tonightHour, daysAhead: 0)
        case .tomorrowMorning: fire = at(Self.morningHour, daysAhead: 1)
        case .everyWeekday: return (2 ... 6).map { DateComponents(hour: Self.morningHour, minute: 0, weekday: $0) }
        }
        return [Self.trigger(at: fire, calendar: calendar)]
    }

    /// A one-time trigger at `date`, in local time: also the custom date and time.
    static func trigger(at date: Date, calendar: Calendar = .current) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}
