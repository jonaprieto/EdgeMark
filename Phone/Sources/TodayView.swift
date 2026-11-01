import EdgeJournalLogic
import SwiftUI

struct TodayView: View {
    @Binding var capture: CaptureRequest?

    @State private var brainstorming = false
    @State private var editing = false

    private var model: PhoneModel { .shared }
    private var path: String { Journal.path(for: Date()) }

    var body: some View {
        let _ = model.revision
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        addButton("Meal", "fork.knife", .meal)
                        addButton("Idea", "lightbulb", .idea)
                        addButton("Todo", "checkmark.square", .todo)
                    }
                    if let error = model.saveError {
                        Text(error).foregroundStyle(.red)
                    }
                    let text = model.text(of: path)
                    if text.isEmpty {
                        Text("Nothing yet today.").foregroundStyle(.secondary)
                    } else {
                        NoteBody(text: text, path: path, imageBase: model.folderURL(of: path))
                    }
                    if !todayPlaces.isEmpty {
                        Label(todayPlaces.joined(separator: " · "), systemImage: "mappin.and.ellipse")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Today")
            .refreshable { await model.sync() }
            .toolbar {
                NavigationLink(value: "places") { Label("Places", systemImage: "map") }
                Button("Brainstorm", systemImage: "sparkles") { brainstorming = true }
                Button("Edit", systemImage: "square.and.pencil") {
                    model.startToday()
                    editing = true
                }
            }
            .navigationDestination(isPresented: $editing) { NoteView(path: path, startsEditing: true) }
            .sheet(isPresented: $brainstorming) { BrainstormView(source: nil) }
            .navigationDestination(for: String.self) { _ in PlacesView() }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    /// Where the day went, each place once, in order. Ideas shows the place of each entry.
    private var todayPlaces: [String] {
        var seen = Set<String>()
        return model.places.filter { $0.at.hasPrefix(Journal.day(Date())) }.compactMap(\.place).filter { seen.insert($0).inserted }
    }

    private func addButton(_ title: String, _ icon: String, _ kind: CaptureKind) -> some View {
        Button(title, systemImage: icon) { capture = CaptureRequest(kind: kind) }
            .buttonStyle(.bordered)
    }
}
