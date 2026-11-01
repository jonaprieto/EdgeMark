import EdgeJournalLogic
import SwiftUI

struct MeetingsView: View {
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var adding = false
    @State private var deleting: PhoneNote?

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
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
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
                                        Text(row.name.isEmpty ? row.title : row.name)
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
                                if let note = row.path.flatMap(model.note) {
                                    Button("Delete Note", systemImage: "trash", role: .destructive) { deleting = note }
                                }
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
            .deleteDialog(for: $deleting)
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
}
