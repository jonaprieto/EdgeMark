import EdgeJournalLogic
import EventKit
import Foundation

/// Upcoming events from every account iOS holds: Google added in Settings, Proton through a
/// subscribed share link. The app adds nothing to them, and removes an event only when asked.
@MainActor @Observable
final class Calendars {
    /// Far enough that Next week is always whole.
    static let days = 28

    private let store = EKEventStore()
    private(set) var events: [Meeting.Event] = []
    /// The calendar's own event behind each one.
    private var found: [Meeting.Event: EKEvent] = [:]
    private(set) var all: [EKCalendar] = []
    private(set) var isDenied = false
    /// Calendar identifiers switched off in Settings.
    private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey: "calendars.hidden") ?? [])

    func refresh() async {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            isDenied = true
            return
        }
        isDenied = false
        all = store.calendars(for: .event)
        let shown = all.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else {
            events = []
            found = [:]
            return
        }
        let now = Date()
        let window = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(Double(Self.days) * 86400), calendars: shown)
        let timed = store.events(matching: window).filter { !$0.isAllDay && $0.title != nil }
        events = timed.map(Self.event)
        found = Dictionary(timed.map { (Self.event($0), $0) }) { first, _ in first }
    }

    private static func event(_ event: EKEvent) -> Meeting.Event {
        Meeting.Event(name: event.title, start: event.startDate, place: event.location)
    }

    var ends: [Meeting.Event: Date] {
        found.mapValues(\.endDate)
    }

    /// The calendar's event behind a meeting, nil for a meeting that is only a note.
    func event(of row: Meeting.Row) -> EKEvent? {
        row.start.flatMap { found[Meeting.Event(name: row.name, start: $0, place: row.place)] }
    }

    /// Takes the event out of its calendar on every device. A repeating event loses this date only.
    func delete(_ event: EKEvent) async throws {
        try store.remove(event, span: .thisEvent, commit: true)
        await refresh()
    }

    func setShown(_ on: Bool, _ calendar: EKCalendar) async {
        if on {
            hidden.remove(calendar.calendarIdentifier)
        } else {
            hidden.insert(calendar.calendarIdentifier)
        }
        UserDefaults.standard.set(Array(hidden), forKey: "calendars.hidden")
        await refresh()
    }
}
