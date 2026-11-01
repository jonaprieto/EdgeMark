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

    /// The hour alone when the section already says the day, the weekday when it does not.
    private func detail(_ row: Meeting.Row, in bucket: Meeting.Bucket) -> String {
        guard let start = row.start else { return row.day }
        switch bucket {
        case .today, .tomorrow: return start.formatted(date: .omitted, time: .shortened)
        case .thisWeek, .nextWeek: return start.formatted(.dateTime.weekday(.wide).hour().minute())
        case .later: return start.formatted(date: .abbreviated, time: .shortened)
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
                let groups = Dictionary(grouping: rows) { Meeting.bucket(day: $0.day, now: now) }
                ForEach(Meeting.Bucket.allCases.filter { groups[$0] != nil }, id: \.self) { bucket in
                    Section(title(bucket)) {
                        ForEach(groups[bucket] ?? []) { row in
                            Button { open(row) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.name.isEmpty ? row.title : row.name)
                                        Text([detail(row, in: bucket), row.place].compactMap(\.self).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
