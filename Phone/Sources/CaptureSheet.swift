import EdgeJournalLogic
import SwiftUI

struct CaptureSheet: View {
    let request: CaptureRequest

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind = CaptureKind.idea
    @State private var hasDue = false
    @State private var due = Date()
    @State private var remind = false
    @State private var dictation = Dictation()
    @State private var photos: [UIImage] = []
    @State private var isPrivate = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    Text("Sleep").tag(CaptureKind.sleep)
                    Text("Meal").tag(CaptureKind.meal)
                    Text("Idea").tag(CaptureKind.idea)
                    Text("Todo").tag(CaptureKind.todo)
                    Text("Meeting").tag(CaptureKind.meeting)
                }
                .pickerStyle(.segmented)
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .focused($focused)
                Section {
                    MicButton(dictation: dictation, text: $text, startsListening: request.voice)
                    if PhoneModel.shared.canEncrypt, kind != .meeting, kind != .sleep, !rings {
                        Toggle("Private", isOn: $isPrivate)
                    }
                    // A photo is a plain file in the repository, so a private capture takes none.
                    if !isPrivate, kind != .sleep {
                        PhotoMenu(onPhotos: { photos += $0 }) { Label("Add Photo", systemImage: "camera") }
                    }
                    if !photos.isEmpty, !isPrivate {
                        PhotoStrip(photos: photos)
                    }
                } footer: {
                    if let problem = dictation.problem {
                        Text(problem)
                    } else if isPrivate {
                        Text("Encrypted, with no position. Opens with Face ID.")
                    }
                }
                if kind == .sleep {
                    Text(Sleep.parse(text).map { "Reads as \($0.line.dropFirst(2))" } ?? "Say when you slept, or for how long.")
                        .foregroundStyle(.secondary)
                    if request.text.isEmpty {
                        Button("Going to bed now", systemImage: "moon.zzz") {
                            SleepTracker.goingToBed()
                            dismiss()
                        }
                    }
                }
                if kind == .meeting {
                    Text(PhoneModel.shared.meetings.first?.title ?? "No meeting coming up")
                        .foregroundStyle(.secondary)
                }
                if let error = PhoneModel.shared.saveError {
                    Text(error).foregroundStyle(.red)
                }
                // A private todo is sealed, so nothing could read its date or ring it.
                if kind == .todo, !isPrivate {
                    Toggle("Remind me", isOn: $remind)
                    if !remind {
                        Toggle("Due date", isOn: $hasDue)
                    }
                    if remind {
                        DatePicker("When", selection: $due, in: Date()...)
                    } else if hasDue {
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(cannotSave)
                }
            }
        }
        .onAppear {
            kind = request.kind
            text = request.text
            remind = request.remind
            focused = !request.voice
        }
        .onChange(of: text) { readWhen() }
        .onChange(of: remind) {
            if remind { due = Date().addingTimeInterval(3600) }
            readWhen()
        }
    }

    private var rings: Bool {
        kind == .todo && remind
    }

    /// "Llamar a mamá mañana a las 3" sets the picker, which still has the last word.
    private func readWhen() {
        if rings, let found = MeetingText.reminder(text, now: Date()) { due = found.date }
    }

    private var prompt: String {
        switch kind {
        case .sleep: "23:00 07:00 regular"
        case .meal: "What did you eat?"
        case .idea: "An idea, or something you noticed"
        case .todo: remind ? "Call mom tomorrow at 3" : "What needs doing?"
        case .meeting: "What should you bring up?"
        }
    }

    private var cannotSave: Bool {
        if kind == .sleep { return Sleep.parse(text) == nil }
        if rings, due <= Date() { return true }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty) || (kind == .meeting && PhoneModel.shared.meetings.isEmpty)
    }

    private func save() async {
        await dictation.stop()
        let model = PhoneModel.shared
        if kind == .sleep {
            if let sleep = Sleep.parse(text) {
                model.capture(sleep)
                SleepTracker.clear()
            }
            dismiss()
            return
        }
        if isPrivate {
            if model.capturePrivately(text, kind: kind.rawValue) { dismiss() }
            return
        }
        let target = kind.journal != nil ? Journal.path(for: Date()) : model.nextMeetingPath
        let images = target.map { path in photos.compactMap { model.attach($0, to: path) } } ?? []
        let words = rings ? MeetingText.reminder(text, now: Date())?.text ?? text : text
        let line = ([words] + images).filter { !$0.isEmpty }.joined(separator: " ")
        if let journal = kind.journal {
            model.capture(line, kind: journal, due: rings ? Journal.stamp(due) : kind == .todo && hasDue ? Journal.day(due) : nil)
        } else {
            _ = model.addMeetingIdea(line)
        }
        // A failed write keeps the sheet open, with the text still in it.
        if PhoneModel.shared.saveError == nil { dismiss() }
    }
}
