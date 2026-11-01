import EdgeCrypto
import EdgeStorageLogic
import SwiftUI

/// An age note, read-only. The text lives in this view alone and goes when the view or the
/// app does: nothing decrypted reaches the disk.
struct EncryptedNoteView: View {
    let path: String

    @Environment(\.scenePhase) private var phase
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    NoteMarkdown(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("Encrypted note", systemImage: "lock")
                } description: {
                    Text(problem ?? "Read-only on this phone.")
                } actions: {
                    Button("Open with Face ID", systemImage: "faceid") { Task { await open() } }
                }
            }
        }
        .onChange(of: phase) { _, now in
            if now != .active { text = nil }
        }
        .onDisappear { text = nil }
    }

    private func open() async {
        guard let identity = await AgeVault.unlock() else {
            problem = "No key on this phone, or Face ID was refused."
            return
        }
        do {
            let payload = try Age.decrypt(PhoneModel.shared.text(of: path), with: identity)
            text = EncryptedTags.extract(from: String(decoding: payload, as: UTF8.self)).text
            problem = nil
        } catch {
            problem = "This key does not open the note."
        }
    }
}
