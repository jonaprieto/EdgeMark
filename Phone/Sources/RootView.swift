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
    var text = ""
    /// A todo that rings: the Remind buttons.
    var remind = false

    /// `edgemark://capture?kind=meal&voice=1`
    init?(url: URL) {
        guard url.scheme == "edgemark", url.host == "capture" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        kind = items.first { $0.name == "kind" }?.value.flatMap(CaptureKind.init) ?? .idea
        voice = items.contains { $0.name == "voice" }
        remind = items.contains { $0.name == "remind" }
        text = items.first { $0.name == "text" }?.value ?? ""
    }

    init(kind: CaptureKind = .idea, voice: Bool = false, remind: Bool = false) {
        self.kind = kind
        self.voice = voice
        self.remind = remind
    }
}

private enum Tab {
    case today, notes, journal, todos, meetings
}

/// A note opened from a reminder.
private struct OpenedNote: Identifiable {
    let id: String
}

struct RootView: View {
    @State private var capture: CaptureRequest?
    @State private var tab = Tab.today
    @State private var opened: OpenedNote?
    @AppStorage("todos.order") private var order = TodoOrder.note

    var body: some View {
        TabView(selection: $tab) {
            TodayView(capture: $capture).tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
            NotesRoot().tabItem { Label("Notes", systemImage: "note.text") }.tag(Tab.notes)
            JournalView(capture: $capture).tabItem { Label("Journal", systemImage: "book") }.tag(Tab.journal)
            TodosView(capture: $capture).tabItem { Label("Todos", systemImage: "checklist") }.tag(Tab.todos)
            MeetingsView().tabItem { Label("Meetings", systemImage: "calendar") }.tag(Tab.meetings)
        }
        .sheet(item: $capture) { CaptureSheet(request: $0) }
        .sheet(item: $opened) { note in
            NavigationStack { NoteView(path: note.id) }
        }
        .onOpenURL(perform: open)
    }

    /// `edgemark://capture`, `edgemark://reminders` or `edgemark://note?path=Journal/2026-11-01.md`.
    private func open(_ url: URL) {
        if let request = CaptureRequest(url: url) {
            capture = request
        } else if url.host == "reminders" {
            order = .reminders
            tab = .todos
        } else if url.host == "note", let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value {
            opened = OpenedNote(id: path)
        }
    }
}
