import EdgeCrypto
import EdgeStorageLogic
import SwiftUI

/// An age note. The text lives in this view alone and goes when the view or the app does:
/// nothing decrypted reaches the disk. Saving seals it again, with no Face ID needed.
struct EncryptedNoteView: View {
    let path: String

    @Environment(\.scenePhase) private var phase
    @State private var text: String?
    @State private var tags: [String] = []
    @State private var problem: String?
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var model: PhoneModel { .shared }

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $draft)
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .onAppear { focused = true }
            } else if let text {
                ScrollView {
                    NoteMarkdown(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .themedBackground()
            } else {
                ContentUnavailableView {
                    Label("Encrypted note", systemImage: "lock")
                } description: {
                    Text(problem ?? "Private note.")
                } actions: {
                    Button("Open with Face ID", systemImage: "faceid") { Task { await open() } }
                }
            }
        }
        .toolbar {
            if text != nil, model.canEncrypt {
                ToolbarItem(placement: .primaryAction) {
                    Button(editing ? "Done" : "Edit") { editing ? saveDraft() : startEditing() }
                }
            }
        }
        .onChange(of: phase) { _, now in
            if now != .active { close() }
        }
        .onDisappear { close() }
    }

    private func startEditing() {
        draft = text ?? ""
        editing = true
    }

    private func saveDraft() {
        if draft != text { model.savePrivate(EncryptedTags.embed(tags, in: draft), to: path) }
        text = draft
        editing = false
    }

    /// Leaving seals what was typed before the text is dropped.
    private func close() {
        if editing { saveDraft() }
        text = nil
        draft = ""
    }

    private func open() async {
        guard let identity = await AgeVault.unlock() else {
            problem = "No key on this phone, or Face ID was refused."
            return
        }
        do {
            let payload = try Age.decrypt(PhoneModel.shared.text(of: path), with: identity)
            let parts = EncryptedTags.extract(from: String(decoding: payload, as: UTF8.self))
            text = parts.text
            tags = parts.tags
            problem = nil
        } catch {
            problem = "This key does not open the note."
        }
    }
}
