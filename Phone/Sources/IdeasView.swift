import EdgeJournalLogic
import SwiftUI

/// Ideas and observations across the days, each with its time and place.
struct IdeasView: View {
    @Binding var capture: CaptureRequest?

    @State private var query = ""

    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack {
            let days = groupedByDay
            List {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day) {
                        ForEach(days[day] ?? []) { row in rowView(row) }
                    }
                }
            }
            .overlay {
                if model.ideas.isEmpty, model.privateCaptures.isEmpty {
                    ContentUnavailableView("No ideas yet", systemImage: "lightbulb", description: Text("Ideas and things you notice land here, with when and where."))
                }
            }
            .navigationTitle("Ideas")
            .searchable(text: $query)
            .refreshable { await model.sync() }
            .toolbar {
                Button("Add", systemImage: "plus") { capture = CaptureRequest(kind: .idea) }
            }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    /// A day's line: an idea in the clear, or a private capture that shows only when it was made.
    private enum Row: Identifiable {
        case idea(Journal.Entry, PlaceLine?)
        case sealed(Journal.PrivateEntry)

        var id: String {
            switch self {
            case let .idea(entry, _): entry.id
            case let .sealed(entry): entry.id
            }
        }

        var day: String {
            switch self {
            case let .idea(entry, _): entry.day
            case let .sealed(entry): entry.day
            }
        }

        var time: String {
            switch self {
            case let .idea(entry, _): entry.time
            case let .sealed(entry): entry.time
            }
        }
    }

    /// Each day holds its ideas and private captures together, newest first. A search reaches
    /// ideas and places, and "private" finds the sealed ones, whose text cannot be searched.
    private var groupedByDay: [String: [Row]] {
        let ideas = model.ideas.filter { idea in
            query.isEmpty || idea.entry.words.localizedCaseInsensitiveContains(query)
                || idea.place?.place?.localizedCaseInsensitiveContains(query) == true
        }.map { Row.idea($0.entry, $0.place) }
        let showSealed = query.isEmpty || "private".localizedCaseInsensitiveContains(query)
        let sealed = showSealed ? model.privateCaptures.map(Row.sealed) : []
        return Dictionary(grouping: ideas + sealed, by: \.day).mapValues { rows in rows.sorted { $0.time > $1.time } }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case let .idea(entry, place):
            NavigationLink(value: Route.note(entry.path)) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if !entry.words.isEmpty { Text(entry.words) }
                        Text([entry.time, place?.place].compactMap(\.self).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let image = entry.images.first, let url = model.imageURL(image, in: entry.path) {
                        Thumbnail(url: url)
                    }
                }
            }
        case let .sealed(entry):
            NavigationLink(value: Route.note(entry.path)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Private \(entry.kind)", systemImage: "lock")
                    Text(entry.time).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
