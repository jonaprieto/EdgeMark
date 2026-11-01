import EdgeJournalLogic
import SwiftUI

struct TodayView: View {
    @Binding var capture: CaptureRequest?

    @State private var brainstorming = false
    @State private var editing = false
    @AppStorage(SleepTracker.bedKey) private var bedAt = 0.0
    @State private var showSettings = false

    private var model: PhoneModel { .shared }
    private var path: String { Journal.path(for: Date()) }

    var body: some View {
        let _ = model.revision
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        let inBed = SleepTracker.inBed(since: bedAt) != nil
                        tile(inBed ? "Awake" : "Sleep", inBed ? "sunrise" : "moon.zzz") { capture = SleepTracker.capture }
                        addButton("Meal", "fork.knife", .meal)
                        addButton("Idea", "lightbulb", .idea)
                        addButton("Todo", "checkmark.square", .todo)
                    }
                    if let error = model.saveError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let bed = SleepTracker.inBed(since: bedAt) {
                        Label("In bed since \(Journal.time(bed))", systemImage: "bed.double").font(.subheadline).foregroundStyle(.secondary)
                    } else if let summary = model.sleepSummary {
                        Label(summary, systemImage: "moon.zzz").font(.subheadline).foregroundStyle(.secondary)
                    }
                    let text = model.text(of: path)
                    if text.isEmpty {
                        Text("Nothing yet today.").foregroundStyle(.secondary)
                    } else {
                        NoteBody(text: text, path: path, imageBase: model.folderURL(of: path))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Today")
            .refreshable { await model.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink(value: "places") { Label("Places", systemImage: "map") }
                    Button("Brainstorm", systemImage: "sparkles") { brainstorming = true }
                    Button("Edit", systemImage: "square.and.pencil") {
                        model.startToday()
                        editing = true
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $editing) { NoteView(path: path, startsEditing: true) }
            .sheet(isPresented: $brainstorming) { BrainstormView(source: nil) }
            .navigationDestination(for: String.self) { _ in PlacesView() }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    private func addButton(_ title: String, _ icon: String, _ kind: CaptureKind) -> some View {
        tile(title, icon) { capture = CaptureRequest(kind: kind) }
    }

    /// One of four equal tiles, so the row fits the smallest iPhone with labels on one line.
    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.footnote.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
