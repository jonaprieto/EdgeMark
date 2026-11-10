import EdgeJournalLogic
import EdgePhoneSync
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
    @State private var deleting: PhoneNote?
    @State private var tooLong: ChatApp?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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
                    // A bottom bar would sit behind the keyboard.
                    .safeAreaInset(edge: .bottom) { MicButton(dictation: dictation, text: $text).padding(8) }
            } else {
                ScrollView {
                    NoteBody(text: text, path: path, imageBase: model.folderURL(of: path))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .themedBackground()
            }
        }
        .navigationTitle(model.note(path)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                ToolbarItemGroup(placement: .secondaryAction) {
                    ForEach(ChatApp.allCases, id: \.self) { app in
                        Button("Open in \(app.rawValue)", systemImage: "arrow.up.forward.app") { open(in: app) }
                    }
                }
            }
            if !editing {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = model.note(path) }
                }
            }
        }
        .deleteDialog(for: $deleting)
        .alert(
            "Too long for a link",
            isPresented: Binding(get: { tooLong != nil }, set: { if !$0 { tooLong = nil } }),
            presenting: tooLong,
        ) { app in
            Button("Copy and Open \(app.rawValue)") {
                UIPasteboard.general.string = words
                openURL(app.home)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Copy the note, then paste it into the new chat.")
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
        .onChange(of: model.revision) {
            text = model.text(of: path)
            // Gone from here, or from the Mac by the last sync.
            if model.note(path) == nil { dismiss() }
        }
    }

    private var words: String {
        Journal.withoutImages(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words, then the photos as files: a path in the note means nothing to whoever gets it.
    private var shared: [Any] {
        let photos: [Any] = Journal.imagePaths(in: text).compactMap { model.imageURL($0, in: path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return [words] + photos
    }

    private func open(in app: ChatApp) {
        if let link = app.link(with: words) { openURL(link) } else { tooLong = app }
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
