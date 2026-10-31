import EdgeJournalLogic
import SwiftUI

struct MeetingsView: View {
    @State private var path: [Route] = []

    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack(path: $path) {
            List(model.meetings) { row in
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
            }
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings",
                        systemImage: "calendar",
                        description: Text(model.calendars.isDenied ? "Calendar access is off in Settings." : "Nothing in the next two weeks."),
                    )
                }
            }
            .navigationTitle("Meetings")
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
