import SwiftUI

/// A title, and whether the note is private: encrypted, opened with Face ID.
struct NewNoteSheet: View {
    let folder: String
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isPrivate = false
    @FocusState private var focused: Bool

    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).focused($focused)
                if model.canEncrypt {
                    Toggle("Private", isOn: $isPrivate)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    private func create() {
        let path = isPrivate ? model.createPrivate(title: title, folder: folder, text: "") : model.create(title: title, folder: folder)
        guard let path else { return }
        dismiss()
        onCreated(path)
    }
}
