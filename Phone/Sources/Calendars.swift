import EdgeJournalLogic
import EventKit
import Foundation

/// Upcoming events from every account iOS holds: Google added in Settings, Proton through a
/// subscribed share link. Read-only: the app never writes an event.
@MainActor @Observable
final class Calendars {
    static let days = 14

    private let store = EKEventStore()
    private(set) var events: [Meeting.Event] = []
    private(set) var ends: [Meeting.Event: Date] = [:]
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
            return
        }
        let now = Date()
        let window = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(Double(Self.days) * 86400), calendars: shown)
        let found = store.events(matching: window).filter { !$0.isAllDay && $0.title != nil }
        events = found.map { Meeting.Event(name: $0.title, start: $0.startDate) }
        ends = Dictionary(found.map { (Meeting.Event(name: $0.title, start: $0.startDate), $0.endDate) }) { first, _ in first }
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
