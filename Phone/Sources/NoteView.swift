import MarkdownUI
import SwiftUI

struct NoteView: View {
    let path: String

    @State private var text = ""
    @State private var editing = false
    @State private var edited = false
    @State private var dictation = Dictation()
    @State private var brainstorming = false
    @FocusState private var focused: Bool

    private var model: PhoneModel { .shared }
    private var encrypted: Bool { path.hasSuffix(".age") }

    var body: some View {
        Group {
            if encrypted {
                ContentUnavailableView("Encrypted note", systemImage: "lock", description: Text("Open it on the Mac."))
            } else if editing {
                TextEditor(text: $text)
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .onAppear { focused = true }
            } else {
                ScrollView {
                    Markdown(text, imageBaseURL: model.folderURL(of: path))
                        .markdownImageProvider(LocalImages())
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
            if !encrypted {
                ToolbarItem(placement: .primaryAction) {
                    Button(editing ? "Done" : "Edit") { setEditing(!editing) }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Brainstorm", systemImage: "sparkles") { brainstorming = true }
                }
            }
        }
        .sheet(isPresented: $brainstorming) { BrainstormView(source: path) }
        .onAppear { text = model.text(of: path) }
        .onDisappear { setEditing(false) }
        .onChange(of: text) { _, new in
            guard editing else { return }
            edited = true
            model.edit(new, path: path)
        }
        .onChange(of: model.revision) { text = model.text(of: path) }
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

/// Images live next to the note, in the mirror.
struct LocalImages: ImageProvider {
    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let url, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }
}
