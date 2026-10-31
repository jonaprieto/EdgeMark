import EdgeJournalLogic
import MarkdownUI
import SwiftUI

struct TodayView: View {
    @Binding var capture: CaptureRequest?

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
                    let text = model.text(of: path)
                    if text.isEmpty {
                        Text("Nothing yet today.").foregroundStyle(.secondary)
                    } else {
                        Markdown(text)
                    }
                    ForEach(todayPlaces) { place in
                        Label(placeLabel(place), systemImage: "mappin.and.ellipse")
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
            }
            .navigationDestination(for: String.self) { _ in PlacesView() }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    private var todayPlaces: [PlaceLine] {
        model.places.filter { $0.at.hasPrefix(Journal.day(Date())) }
    }

    private func placeLabel(_ place: PlaceLine) -> String {
        "\(place.at.dropFirst(11).prefix(5)) \(place.place ?? "\(place.lat), \(place.lon)")"
    }

    private func addButton(_ title: String, _ icon: String, _ kind: Journal.Kind) -> some View {
        Button(title, systemImage: icon) { capture = CaptureRequest(kind: kind) }
            .buttonStyle(.bordered)
    }
}
