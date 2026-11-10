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
    @State private var meal = Journal.Meal(at: Date())
    @State private var eaten = Date()
    @State private var place: String?
    @State private var dictation = Dictation(keepsDraft: true)
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
                    Text("Done").tag(CaptureKind.done)
                    Text("Todo").tag(CaptureKind.todo)
                    Text("Meeting").tag(CaptureKind.meeting)
                }
                .pickerStyle(.segmented)
                if kind == .meal {
                    Picker("Meal", selection: $meal) {
                        ForEach(Journal.Meal.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .focused($focused)
                if kind == .done {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(doneTags, id: \.self) { tag in
                                let on = text.split(whereSeparator: \.isWhitespace).contains { Journal.tag($0) == tag }
                                Button(tag) { text = Journal.toggling(tag, in: text) }
                                    .buttonStyle(.bordered)
                                    .tint(on ? .accentColor : .secondary)
                            }
                        }
                    }
                }
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
                // A private capture keeps the time it was made and records no position.
                if kind == .meal, !isPrivate {
                    DatePicker("Time", selection: $eaten, in: ...Date(), displayedComponents: .hourAndMinute)
                    LabeledContent("Place", value: place ?? "From GPS when saved")
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
            .navigationTitle(rings ? "New Reminder" : "Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(cannotSave)
                }
            }
        }
        .onAppear {
            kind = request.kind
            text = request.text.isEmpty ? Dictation.unsaved ?? "" : request.text
            remind = request.remind
            focused = !request.voice
        }
        .task(id: kind) {
            if kind == .meal, place == nil { place = await PhoneModel.shared.currentPlace() }
        }
        .onChange(of: text) { readWhen() }
        // A private capture stays out of a file that is readable while the phone is locked.
        .onChange(of: isPrivate) {
            if isPrivate { dictation.discardDraft() } else { dictation.keepsDraft = true }
        }
        .onChange(of: remind) {
            if remind { due = Date().addingTimeInterval(3600) }
            readWhen()
        }
    }

    /// The tags most used on earlier Done lines, then #trabajo and #personal so there is
    /// something to tap from the first one, then the tags of ideas and meals: projects, often.
    private var doneTags: [String] {
        let model = PhoneModel.shared
        let tags = Journal.commonTags(model.entries(.done).map(\.entry)) + ["#trabajo", "#personal"]
            + Journal.commonTags((model.entries(.idea) + model.entries(.meal)).map(\.entry))
        var seen = Set<String>()
        return Array(tags.filter { seen.insert($0).inserted }.prefix(8))
    }

    private var rings: Bool {
        kind == .todo && remind
    }

    private func finish() {
        dictation.discardDraft()
        dismiss()
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
        case .done: "What did you do? #work #project"
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
            finish()
            return
        }
        if isPrivate {
            if model.capturePrivately(kind == .meal ? meal.labeled(text) : text, kind: kind.rawValue) { finish() }
            return
        }
        let target = kind.journal != nil ? Journal.path(for: Date()) : model.nextMeetingPath
        let images = target.map { path in photos.compactMap { model.attach($0, to: path) } } ?? []
        let words = rings ? MeetingText.reminder(text, now: Date())?.text ?? text : text
        let line = ([words] + images).filter { !$0.isEmpty }.joined(separator: " ")
        if let journal = kind.journal {
            let due = rings ? Journal.stamp(due) : kind == .todo && hasDue ? Journal.day(due) : nil
            if kind == .meal {
                model.capture(meal.labeled(line), kind: journal, due: due, at: eaten)
            } else {
                model.capture(line, kind: journal, due: due)
            }
        } else {
            _ = model.addMeetingIdea(line)
        }
        // A failed write keeps the sheet open, with the text still in it.
        if PhoneModel.shared.saveError == nil { finish() }
    }
}
