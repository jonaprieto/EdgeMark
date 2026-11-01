import EdgeJournalLogic
import SwiftUI

/// What a capture adds to: today's file, or the next meeting's note.
enum CaptureKind: String, CaseIterable {
    case sleep, meal, idea, todo, meeting

    var journal: Journal.Kind? {
        Journal.Kind(rawValue: rawValue)
    }
}

/// A capture on its way: from a button, or from a widget through `edgemark://capture`.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var kind = CaptureKind.idea
    var voice = false

    /// `edgemark://capture?kind=meal&voice=1`
    init?(url: URL) {
        guard url.scheme == "edgemark", url.host == "capture" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        kind = items.first { $0.name == "kind" }?.value.flatMap(CaptureKind.init) ?? .idea
        voice = items.contains { $0.name == "voice" }
    }

    init(kind: CaptureKind = .idea, voice: Bool = false) {
        self.kind = kind
        self.voice = voice
    }
}

struct RootView: View {
    @State private var capture: CaptureRequest?

    var body: some View {
        TabView {
            TodayView(capture: $capture).tabItem { Label("Today", systemImage: "sun.max") }
            NotesRoot().tabItem { Label("Notes", systemImage: "note.text") }
            IdeasView(capture: $capture).tabItem { Label("Ideas", systemImage: "lightbulb") }
            TodosView().tabItem { Label("Todos", systemImage: "checklist") }
            MeetingsView().tabItem { Label("Meetings", systemImage: "calendar") }
        }
        .sheet(item: $capture) { CaptureSheet(request: $0) }
        .onOpenURL { url in
            if let request = CaptureRequest(url: url) { capture = request }
        }
    }
}
