import EdgeJournalLogic
import EdgePhoneSync
import SwiftUI

/// A chat with OpenAI about one note, or about nothing yet. Only that note and the chat are sent.
struct BrainstormView: View {
    /// The note it started from.
    let source: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("brainstorm.model") private var modelName = "gpt-6.1-sol"
    @State private var messages: [OpenAIChat.Message] = []
    @State private var draft = ""
    @State private var waiting = false
    @State private var failure: String?
    @State private var dictation = Dictation()

    private var model: PhoneModel { .shared }

    private var system: String {
        let intro = "You are a thinking partner for brainstorming. Be brief and concrete, and ask a question when it helps."
        guard let source else { return intro }
        return intro + "\n\nThe user's note:\n\n" + model.text(of: source)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages.indices, id: \.self) { index in
                            let message = messages[index]
                            NoteMarkdown(message.content)
                                .textSelection(.enabled)
                                .opacity(message.role == .user ? 0.6 : 1)
                        }
                        if waiting { ProgressView() }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .themedBackground()
                Divider()
                VStack {
                    TextField("Ask", text: $draft, axis: .vertical).lineLimit(1 ... 5)
                    HStack {
                        MicButton(dictation: dictation, text: $draft)
                        Spacer()
                        Button("Send", systemImage: "paperplane") { Task { await send() } }
                            .disabled(draft.isEmpty || waiting)
                    }
                }
                .padding()
            }
            .navigationTitle("Brainstorm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(messages.isEmpty)
                }
            }
        }
    }

    private func send() async {
        await dictation.stop()
        guard let key = model.openAIKey else {
            failure = "No OpenAI key on this phone"
            return
        }
        messages.append(.init(role: .user, content: draft))
        draft = ""
        failure = nil
        waiting = true
        defer { waiting = false }
        do {
            let reply = try await OpenAIChat.reply(key: key, model: modelName, system: system, messages: messages)
            messages.append(.init(role: .assistant, content: reply))
        } catch {
            failure = "\(error)"
        }
    }

    /// The conversation becomes a note of its own, and the source note stays as it was.
    private func save() {
        let note = source.flatMap { model.note($0) }
        let topic = note?.title ?? messages.first.map { String($0.content.prefix(40)) } ?? "Brainstorm"
        let body = OpenAIChat.transcript(messages, source: note.map { ($0.title, $0.path) })
        _ = model.create(title: "\(Journal.day(Date())) \(topic)", folder: "Brainstorms", body: body)
        Task { await model.sync() }
        dismiss()
    }
}
