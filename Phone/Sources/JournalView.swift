import EdgeJournalLogic
import SwiftUI

/// Ideas or meals across the days, each with its time and place.
struct JournalView: View {
    @Binding var capture: CaptureRequest?

    @AppStorage("journal.kind") private var kind = "idea"
    @State private var query = ""
    @State private var removing: Row?

    private var model: PhoneModel { .shared }
    private var showsMeals: Bool { kind == "meal" }
    private var listed: [(entry: Journal.Entry, place: PlaceLine?)] { model.entries(showsMeals ? .meal : .idea) }
    /// A private meal goes with the meals, every other private capture with the ideas.
    private var sealed: [Journal.PrivateEntry] { model.privateCaptures.filter { ($0.kind == "meal") == showsMeals } }

    var body: some View {
        NavigationStack {
            let days = groupedByDay
            List {
                Picker("Show", selection: $kind) {
                    Text("Ideas").tag("idea")
                    Text("Meals").tag("meal")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day) {
                        ForEach(days[day] ?? []) { row in
                            rowView(row).swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { removing = row }
                            }
                        }
                    }
                }
            }
            .overlay {
                if listed.isEmpty, sealed.isEmpty {
                    if showsMeals {
                        ContentUnavailableView("No meals yet", systemImage: "fork.knife", description: Text("What you eat lands here, with when and where."))
                    } else {
                        ContentUnavailableView("No ideas yet", systemImage: "lightbulb", description: Text("Ideas and things you notice land here, with when and where."))
                    }
                }
            }
            .navigationTitle(showsMeals ? "Meals" : "Ideas")
            .searchable(text: $query)
            .searchSuggestions {
                ForEach(tags, id: \.self) { Text($0).searchCompletion($0) }
            }
            .refreshable { await model.sync() }
            .toolbar {
                Button("Add", systemImage: "plus") { capture = CaptureRequest(kind: showsMeals ? .meal : .idea) }
            }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
            .confirmationDialog(
                showsMeals ? "Delete this meal?" : "Delete this idea?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing,
            ) { row in
                Button("Delete", role: .destructive) {
                    switch row {
                    case let .entry(entry, _): model.remove(entry)
                    case let .sealed(entry): model.delete(entry.path)
                    }
                }
            } message: { _ in
                Text("It goes from this iPhone and the Mac. Your repository's history keeps a copy.")
            }
        }
    }

    /// A day's line: an entry in the clear, or a private capture that shows only when it was made.
    private enum Row: Identifiable {
        case entry(Journal.Entry, PlaceLine?)
        case sealed(Journal.PrivateEntry)

        var id: String {
            switch self {
            case let .entry(entry, _): entry.id
            case let .sealed(entry): entry.id
            }
        }

        var day: String {
            switch self {
            case let .entry(entry, _): entry.day
            case let .sealed(entry): entry.day
            }
        }

        var time: String {
            switch self {
            case let .entry(entry, _): entry.time
            case let .sealed(entry): entry.time
            }
        }
    }

    /// The search when it is a whole tag, which then finds only that tag: not `#casamiento` for `#casa`.
    private var pickedTag: String? {
        let typed = query.lowercased()
        return listed.contains { $0.entry.tags.contains(typed) } ? typed : nil
    }

    /// The tags that finish what is typed: all of them on an empty search, none for plain words,
    /// and none once one is picked, so the list shows.
    private var tags: [String] {
        guard pickedTag == nil else { return [] }
        return Set(listed.flatMap { $0.entry.tags }).filter { $0.hasPrefix(query.lowercased()) }.sorted()
    }

    /// Each day holds its entries and private captures together, newest first. A search reaches
    /// words, tags among them, and places, and "private" finds the sealed ones, whose text cannot
    /// be searched.
    private var groupedByDay: [String: [Row]] {
        let tag = pickedTag
        let found = listed.filter { item in
            if let tag { return item.entry.tags.contains(tag) }
            return query.isEmpty || item.entry.words.localizedCaseInsensitiveContains(query)
                || item.place?.place?.localizedCaseInsensitiveContains(query) == true
                || item.entry.meal?.rawValue.localizedCaseInsensitiveContains(query) == true
        }.map { Row.entry($0.entry, $0.place) }
        let showSealed = query.isEmpty || "private".localizedCaseInsensitiveContains(query)
        let locked = showSealed ? sealed.map(Row.sealed) : []
        return Dictionary(grouping: found + locked, by: \.day).mapValues { rows in rows.sorted { $0.time > $1.time } }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case let .entry(entry, place):
            NavigationLink(value: Route.note(entry.path)) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if !entry.words.isEmpty { Text(entry.words) }
                        Text([entry.meal?.rawValue, entry.time, place?.place].compactMap(\.self).joined(separator: " · "))
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
