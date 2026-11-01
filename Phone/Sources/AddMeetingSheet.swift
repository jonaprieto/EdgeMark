import EdgeJournalLogic
import SwiftUI

/// One sentence, typed or spoken, read into the fields below it. A meeting added here is a note:
/// the app does not write to calendars.
struct AddMeetingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sentence = ""
    @State private var name = ""
    @State private var date = Date()
    @State private var hasTime = false
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Felipe martes 3pm", text: $sentence, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .focused($focused)
                    MicButton(dictation: dictation, text: $sentence)
                } footer: {
                    Text(dictation.problem ?? "Say who and when, in Spanish or English.")
                }
                Section("Meeting") {
                    TextField("Name", text: $name)
                    DatePicker("Day", selection: $date, displayedComponents: .date)
                    Toggle("Time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Starts", selection: $date, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .navigationTitle("New Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: sentence) { _, text in
            let parsed = MeetingText.parse(text, now: Date())
            name = parsed.name
            hasTime = parsed.hasTime
            if let parsedDate = parsed.date { date = parsedDate }
        }
    }

    private func add() async {
        await dictation.stop()
        PhoneModel.shared.addMeeting(name: name, on: date, hasTime: hasTime)
        if PhoneModel.shared.saveError == nil { dismiss() }
    }
}
