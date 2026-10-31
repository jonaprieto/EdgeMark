import EdgeJournalLogic
import SwiftUI

/// A capture on its way: from a button, or from a widget through `edgemark://capture`.
struct CaptureRequest: Identifiable {
    let id = UUID()
    var kind = Journal.Kind.idea
    var voice = false

    /// `edgemark://capture?kind=meal&voice=1`
    init?(url: URL) {
        guard url.scheme == "edgemark", url.host == "capture" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        kind = items.first { $0.name == "kind" }?.value.flatMap(Journal.Kind.init) ?? .idea
        voice = items.contains { $0.name == "voice" }
    }

    init(kind: Journal.Kind = .idea, voice: Bool = false) {
        self.kind = kind
        self.voice = voice
    }
}

struct RootView: View {
    @State private var capture: CaptureRequest?

    var body: some View {
        TabView {
            NotesRoot().tabItem { Label("Notes", systemImage: "note.text") }
            TodayView(capture: $capture).tabItem { Label("Today", systemImage: "sun.max") }
        }
        .sheet(item: $capture) { CaptureSheet(request: $0) }
        .onOpenURL { url in
            if let request = CaptureRequest(url: url) { capture = request }
        }
    }
}
