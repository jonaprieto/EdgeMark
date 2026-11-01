import EdgeJournalLogic
import SwiftUI

struct NoteView: View {
    let path: String
    var startsEditing = false

    @State private var text = ""
    @State private var editing = false
    @State private var edited = false
    @State private var dictation = Dictation()
    @State private var brainstorming = false
    @State private var reminding = false
    @State private var sharing = false
    @FocusState private var focused: Bool

    private var model: PhoneModel { .shared }
    private var encrypted: Bool { path.hasSuffix(".age") }

    var body: some View {
        Group {
            if encrypted {
                EncryptedNoteView(path: path)
            } else if editing {
                TextEditor(text: $text)
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .onAppear { focused = true }
            } else {
                ScrollView {
                    NoteBody(text: text, path: path, imageBase: model.folderURL(of: path))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(model.note(path)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing {
                ToolbarItem(placement: .bottomBar) { MicButton(dictation: dictation, text: $text) }
            }
            if !editing {
                ToolbarItem(placement: .primaryAction) {
                    Button("Remind Me", systemImage: model.hasReminder(on: path) ? "bell.fill" : "bell") { reminding = true }
                }
            }
            if !encrypted {
                // A photo is a plain file in the repository, so a private note takes none.
                ToolbarItem(placement: .primaryAction) {
                    PhotoMenu(onPhotos: { model.add($0, to: path) }) { Label("Add Photo", systemImage: "camera") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(editing ? "Done" : "Edit") { setEditing(!editing) }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { sharing = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Brainstorm", systemImage: "sparkles") { brainstorming = true }
                }
            }
        }
        .sheet(isPresented: $brainstorming) { BrainstormView(source: path) }
        .sheet(isPresented: $sharing) { ShareSheet(items: shared).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $reminding) {
            if let note = model.note(path) { ReminderSheet(note: note) }
        }
        .onAppear {
            text = model.text(of: path)
            if startsEditing, !encrypted { setEditing(true) }
        }
        .onDisappear { setEditing(false) }
        .onChange(of: text) { _, new in
            guard editing else { return }
            edited = true
            model.edit(new, path: path)
        }
        .onChange(of: model.revision) { text = model.text(of: path) }
    }

    /// The words, then the photos as files: a path in the note means nothing to whoever gets it.
    private var shared: [Any] {
        let photos: [Any] = Journal.imagePaths(in: text).compactMap { model.imageURL($0, in: path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return [Journal.withoutImages(text).trimmingCharacters(in: .whitespacesAndNewlines)] + photos
    }

    private func setEditing(_ on: Bool) {
        if !on { Task { await dictation.stop() } }
        editing = on
        model.editing = on ? path : nil
        guard !on, edited else { return }
        edited = false
        Task { await model.finish() }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
