import EdgeJournalLogic
import EdgePhoneSupport
import SwiftUI

struct TodayView: View {
    @Binding var capture: CaptureRequest?

    @State private var brainstorming = false
    @State private var editing = false
    @AppStorage(SleepTracker.bedKey) private var bedAt = 0.0
    @State private var showSettings = false
    @State private var leaving = false
    /// Days back from today: 0 is today, so midnight needs no handling.
    @State private var offset = 0

    private var model: PhoneModel { .shared }
    private var day: Date { Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date() }
    private var isToday: Bool { offset == 0 }
    private var path: String { Journal.path(for: day) }

    var body: some View {
        let _ = model.revision
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Captures go to today only, so none lands in a past day by mistake.
                    if isToday { capturePanel }
                    if let error = model.saveError {
                        Text(error).foregroundStyle(.red)
                    }
                    let text = model.text(of: path)
                    if text.isEmpty {
                        Text(isToday ? "Nothing yet today." : "Nothing on this day.").foregroundStyle(.secondary)
                    } else {
                        NoteBody(text: text, path: path, imageBase: model.folderURL(of: path))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .themedBackground()
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
                let x = drag.translation.width
                guard abs(x) > 60, abs(x) > 2 * abs(drag.translation.height) else { return }
                step(x > 0 ? -1 : 1)
            })
            .accessibilityAction(named: "Previous day") { step(-1) }
            .accessibilityAction(named: "Next day") { step(1) }
            .navigationTitle(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            // The title shares its row with the buttons, so the day starts higher up.
            .toolbarTitleDisplayMode(.inlineLarge)
            .refreshable { await model.sync() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isToday {
                        Button("Today") { withAnimation { offset = 0 } }
                    }
                    NavigationLink(value: "places") { Label("Places", systemImage: "map") }
                    Button("Brainstorm", systemImage: "sparkles") { brainstorming = true }
                    if isToday || !model.text(of: path).isEmpty {
                        Button("Edit", systemImage: "square.and.pencil") {
                            if isToday { model.startToday() }
                            editing = true
                        }
                    }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .imageScale(.small)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $editing) { NoteView(path: path, startsEditing: true) }
            .sheet(isPresented: $brainstorming) { BrainstormView(source: nil) }
            .sheet(isPresented: $leaving) { TomorrowSheet() }
            .navigationDestination(for: String.self) { _ in PlacesView() }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
        }
    }

    /// A swipe moves a day, never past today.
    private func step(_ days: Int) {
        withAnimation { offset = min(0, offset + days) }
    }

    /// Tiles, reminders and sleep: what only today shows.
    @ViewBuilder private var capturePanel: some View {
        HStack(spacing: 8) {
            let inBed = SleepTracker.inBed(since: bedAt) != nil
            tile(inBed ? "Awake" : "Sleep", inBed ? "sunrise" : "moon.zzz") { capture = SleepTracker.capture }
            addButton("Meal", "fork.knife", .meal)
            addButton("Idea", "lightbulb", .idea)
            addButton("Todo", "checkmark.square", .todo)
            tile("Remind", "bell") { capture = CaptureRequest(kind: .todo, remind: true) }
            PhotoMenu(onPhotos: addPhotos) { tileLabel("Photo", "camera") }
        }
        // Not a seventh tile: the row would no longer fit its labels on the smallest iPhone.
        HStack(spacing: 8) {
            bar("Done", "checkmark.circle") { capture = CaptureRequest(kind: .done) }
            bar("For tomorrow", "sunrise") { leaving = true }
        }
        ForEach(model.leftForTomorrow) { entry in
            NavigationLink(value: Route.note(entry.path)) {
                Label(entry.words, systemImage: "sunrise").font(.subheadline).lineLimit(2)
            }
            .buttonStyle(.plain)
        }
        if model.notificationsOff {
            Label("Notifications are off, so reminders will not ring.", systemImage: "bell.slash").font(.subheadline).foregroundStyle(.red)
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

    /// A half-width button under the tiles.
    private func bar(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(.tint)
                .background(Surface(), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .background(Surface(), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

/// A few words to find at the top of Today tomorrow.
private struct TomorrowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("What should you read tomorrow?", text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .focused($focused)
                MicButton(dictation: dictation, text: $text)
            }
            .themedBackground()
            .navigationTitle("For Tomorrow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func save() async {
        await dictation.stop()
        PhoneModel.shared.leaveForTomorrow(text)
        dismiss()
    }
}
