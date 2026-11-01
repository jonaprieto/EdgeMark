import EdgeJournalLogic
import SwiftUI

struct CaptureSheet: View {
    let request: CaptureRequest

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind = CaptureKind.idea
    @State private var hasDue = false
    @State private var due = Date()
    @State private var dictation = Dictation()
    @State private var photos: [UIImage] = []
    @State private var isPrivate = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
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
                    if PhoneModel.shared.canEncrypt, kind != .meeting {
                        Toggle("Private", isOn: $isPrivate)
                    }
                    // A photo is a plain file in the repository, so a private capture takes none.
                    if !isPrivate {
                        PhotoButtons { photos.append($0) }
                    }
                    if !photos.isEmpty, !isPrivate {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(photos.indices, id: \.self) { index in
                                    Image(uiImage: photos[index]).resizable().scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                } footer: {
                    if let problem = dictation.problem {
                        Text(problem)
                    } else if isPrivate {
                        Text("Encrypted, with no position. Opens with Face ID.")
                    }
                }
                if kind == .meeting {
                    Text(PhoneModel.shared.meetings.first?.title ?? "No meeting coming up")
                        .foregroundStyle(.secondary)
                }
                if let error = PhoneModel.shared.saveError {
                    Text(error).foregroundStyle(.red)
                }
                if kind == .todo {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
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
            focused = !request.voice
        }
    }

    private var prompt: String {
        switch kind {
        case .meal: "What did you eat?"
        case .idea: "An idea, or something you noticed"
        case .todo: "What needs doing?"
        case .meeting: "What should you bring up?"
        }
    }

    private var cannotSave: Bool {
        (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty) || (kind == .meeting && PhoneModel.shared.meetings.isEmpty)
    }

    private func save() async {
        await dictation.stop()
        let model = PhoneModel.shared
        if isPrivate {
            if model.capturePrivately(text, kind: kind.rawValue) { dismiss() }
            return
        }
        let target = kind.journal != nil ? Journal.path(for: Date()) : model.nextMeetingPath
        let images = target.map { path in photos.compactMap { model.attach($0, to: path) } } ?? []
        let line = ([text] + images).filter { !$0.isEmpty }.joined(separator: " ")
        if let journal = kind.journal {
            model.capture(line, kind: journal, due: kind == .todo && hasDue ? due : nil)
        } else {
            _ = model.addMeetingIdea(line)
        }
        // A failed write keeps the sheet open, with the text still in it.
        if PhoneModel.shared.saveError == nil { dismiss() }
    }
}
