import EdgeJournalLogic
import EdgePhoneSupport
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
                    HStack(spacing: 8) {
                        let inBed = SleepTracker.inBed(since: bedAt) != nil
                        tile(inBed ? "Awake" : "Sleep", inBed ? "sunrise" : "moon.zzz") { capture = SleepTracker.capture }
                        addButton("Meal", "fork.knife", .meal)
                        addButton("Idea", "lightbulb", .idea)
                        addButton("Todo", "checkmark.square", .todo)
                        tile("Remind", "bell") { capture = CaptureRequest(kind: .todo, remind: true) }
                        PhotoMenu(onPhotos: addPhotos) { tileLabel("Photo", "camera") }
                    }
                    if model.notificationsOff {
                        Label("Notifications are off, so reminders will not ring.", systemImage: "bell.slash").font(.subheadline).foregroundStyle(.red)
                    }
                    if let error = model.saveError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let bed = SleepTracker.inBed(since: bedAt) {
                        Label("In bed since \(Journal.time(bed))", systemImage: "bed.double").font(.subheadline).foregroundStyle(.secondary)
                    } else if let summary = model.sleepSummary {
                        Label(summary, systemImage: "moon.zzz").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(soon) { reminder in
                        NavigationLink(value: Route.note(reminder.path)) {
                            Label("\(WidgetSnapshot.when(reminder.date))  \(reminder.title)", systemImage: "bell")
                                .font(.subheadline).lineLimit(1)
                        }
                        .buttonStyle(.plain)
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

    /// What rings by the end of tomorrow. Today's own todos already show in the note below.
    private var soon: [Reminder] {
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return Array(model.reminders.filter { $0.date < end && !($0.path == path && $0.raw != nil) }.prefix(4))
    }

    private func addButton(_ title: String, _ icon: String, _ kind: CaptureKind) -> some View {
        tile(title, icon) { capture = CaptureRequest(kind: kind) }
    }

    /// A quick shot goes in with the ideas, with its time and place. Meal takes one too.
    private func addPhotos(_ photos: [UIImage]) {
        let images = photos.compactMap { model.attach($0, to: path) }
        if !images.isEmpty { model.capture(images.joined(separator: " "), kind: .idea, due: nil) }
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.buttonStyle(.plain)
    }

    /// One of six equal tiles, so the row fits the smallest iPhone with labels on one line.
    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(.tint)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
