import EdgeJournalLogic
import SwiftUI

/// Ideas and observations across the days, each with its time and place.
struct IdeasView: View {
    @Binding var capture: CaptureRequest?

    @State private var query = ""

    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack {
            let shown = model.ideas.filter { idea in
                query.isEmpty || idea.entry.words.localizedCaseInsensitiveContains(query)
                    || idea.place?.place?.localizedCaseInsensitiveContains(query) == true
            }
            let days = Dictionary(grouping: shown) { $0.entry.day }
            List {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day) {
                        ForEach(days[day] ?? [], id: \.entry) { idea in
                            NavigationLink(value: Route.note(idea.entry.path)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !idea.entry.words.isEmpty { Text(idea.entry.words) }
                                        Text([idea.entry.time, idea.place?.place].compactMap(\.self).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let image = idea.entry.images.first, let url = model.imageURL(image, in: idea.entry.path) {
                                        Thumbnail(url: url)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.ideas.isEmpty {
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
}
