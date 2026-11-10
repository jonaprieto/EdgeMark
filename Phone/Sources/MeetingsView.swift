import EdgeJournalLogic
import EventKit
import SwiftUI

struct MeetingsView: View {
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var adding = false
    @State private var removing: Meeting.Row?
    @State private var failure: String?

    private var model: PhoneModel { .shared }

    private func title(_ bucket: Meeting.Bucket) -> String {
        switch bucket {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This week"
        case .nextWeek: "Next week"
        case .later: "Later"
        }
    }

    /// The one way this screen writes a time, whatever the phone's 24-hour setting.
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        // A fixed locale, since any real one can turn this back into a 24-hour clock.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// `Tuesday, 3 Nov`, with Today or Tomorrow in front.
    private func dayTitle(_ day: String, _ bucket: Meeting.Bucket) -> String {
        let date = Meeting.date(day: day)?.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) ?? day
        switch bucket {
        case .today, .tomorrow: return "\(title(bucket)) · \(date)"
        default: return date
        }
    }

    /// Only accounts iOS holds reach EventKit, so the screen says which those are.
    private var sources: String {
        let names = Set(model.calendars.all.map(\.source.title)).sorted()
        return "Reading calendars from \(names.joined(separator: ", ")). Add Google in iOS Settings > Apps > Calendar > Calendar Accounts."
    }

    private var rows: [Meeting.Row] {
        query.isEmpty ? model.meetings : model.meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                let now = Date()
                let days = Dictionary(grouping: rows, by: \.day)
                let order = days.keys.sorted()
                ForEach(order, id: \.self) { day in
                    let bucket = Meeting.bucket(day: day, now: now)
                    Section {
                        ForEach(days[day] ?? []) { row in
                            Button { open(row) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(name(row))
                                        let detail = [row.start.map(time), row.place].compactMap(\.self).joined(separator: " · ")
                                        if !detail.isEmpty {
                                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if row.path != nil { Image(systemName: "note.text").foregroundStyle(.secondary) }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { removing = row }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            // The first day of a week names the week.
                            if bucket > .tomorrow, order.first(where: { Meeting.bucket(day: $0, now: now) == bucket }) == day {
                                Text(title(bucket)).font(.headline).foregroundStyle(.primary)
                            }
                            Text(dayTitle(day, bucket))
                        }
                        .textCase(nil)
                    }
                }
                if !model.calendars.all.isEmpty {
                    Section {} footer: { Text(sources) }
                }
            }
            .themedBackground()
            .overlay {
                if model.meetings.isEmpty, model.calendars.isDenied {
                    ContentUnavailableView("No meetings", systemImage: "calendar", description: Text("Calendar access is off in Settings."))
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $query)
            .toolbar {
                Button("Add Meeting", systemImage: "plus") { adding = true }
            }
            .sheet(isPresented: $adding) { AddMeetingSheet() }
            .confirmationDialog(
                "Delete \(removing.map(name) ?? "meeting")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing,
            ) { row in
                let note = row.path.flatMap(model.note)
                let event = model.calendars.event(of: row).flatMap { $0.calendar.allowsContentModifications ? $0 : nil }
                if let note {
                    Button("Delete Note", role: .destructive) { model.delete(note.path) }
                }
                if let event {
                    Button("Delete From \(event.calendar.title)", role: .destructive) { delete(event) }
                }
                if let note, let event {
                    Button("Delete Both", role: .destructive) { delete(event, note: note) }
                }
            } message: { row in
                Text(warning(row))
            }
            .alert("Could not delete it", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {} message: {
                Text(failure ?? "")
            }
            .refreshable {
                await model.calendars.refresh()
                await model.sync()
            }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    private func open(_ row: Meeting.Row) {
        if let note = model.notePath(for: row) { path.append(.note(note)) }
    }

    private func name(_ row: Meeting.Row) -> String {
        row.name.isEmpty ? row.title : row.name
    }

    /// Says where each part goes, since an event leaves the calendar it came from.
    private func warning(_ row: Meeting.Row) -> String {
        var parts: [String] = []
        if row.path != nil { parts.append("The note goes from this iPhone and the Mac. Your repository's history keeps a copy.") }
        if let event = model.calendars.event(of: row) {
            let calendar = event.calendar.title
            if !event.calendar.allowsContentModifications {
                parts.append("\(calendar) cannot be changed from here, so delete the event there.")
            } else {
                parts.append("The event goes from \(calendar) on all your devices\(event.hasRecurrenceRules ? ", this date only" : "").")
                if event.hasAttendees { parts.append("Its guests may be told it is cancelled.") }
            }
        }
        return parts.joined(separator: " ")
    }

    /// The note goes only once the event has, so a failure leaves both.
    private func delete(_ event: EKEvent, note: PhoneNote? = nil) {
        Task {
            do {
                try await model.calendars.delete(event)
                if let note { model.delete(note.path) } else { model.refresh() }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
