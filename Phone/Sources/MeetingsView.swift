import EdgeJournalLogic
import SwiftUI

struct MeetingsView: View {
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var adding = false

    private var model: PhoneModel { .shared }

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
                ForEach(rows) { row in
                    Button { open(row) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.name.isEmpty ? row.title : row.name)
                                Text(row.start?.formatted(date: .abbreviated, time: .shortened) ?? row.day)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.path != nil { Image(systemName: "note.text").foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
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
