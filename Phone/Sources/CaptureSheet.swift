import EdgeJournalLogic
import SwiftUI

struct CaptureSheet: View {
    let request: CaptureRequest

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind = Journal.Kind.idea
    @State private var hasDue = false
    @State private var due = Date()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    Text("Meal").tag(Journal.Kind.meal)
                    Text("Idea").tag(Journal.Kind.idea)
                    Text("Todo").tag(Journal.Kind.todo)
                }
                .pickerStyle(.segmented)
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .focused($focused)
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
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            kind = request.kind
            focused = true
        }
    }

    private var prompt: String {
        switch kind {
        case .meal: "What did you eat?"
        case .idea: "What is the idea?"
        case .todo: "What needs doing?"
        }
    }

    private func save() {
        PhoneModel.shared.capture(text, kind: kind, due: kind == .todo && hasDue ? due : nil)
        dismiss()
    }
}
