import SwiftUI

/// Read-only preview body for the peek window. Renders a `Note` via the
/// engine-backed `ReadOnlyMarkdownView`, or a `Folder` as a compact
/// child-note list (header + rows styled like `NoteRowView`).
struct PeekContentView: View {
    @Environment(L10n.self) var l10n
    let content: PeekContent
    /// Opens a row of a folder preview in the panel. Nil leaves the rows inert.
    var onOpen: ((NoteStore.SelectableID) -> Void)?

    var body: some View {
        switch content {
        case let .note(note):
            notePreview(note)
        case let .folder(folder, subfolders, notes):
            folderPreview(folder: folder, subfolders: subfolders, notes: notes)
        }
    }

    // MARK: - Note

    @ViewBuilder
    private func notePreview(_ note: Note) -> some View {
        if note.isLocked {
            LockedNotePlaceholder()
        } else if note.isPlainTextFile {
            // Code and data files are shown as they are, coloured like in their editor.
            PlainTextView(
                model: PlainTextEditorModel(noteID: note.id),
                initialContent: note.content,
                font: AppSettings.shared.editorMonoFont,
                language: SyntaxLanguage.language(forFileName: note.title, content: note.content),
                isEditable: false,
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ReadOnlyMarkdownView(content: note.content, noteFolder: note.folder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Folder

    private func folderPreview(folder: Folder, subfolders: [Folder], notes: [Note]) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.panel(.title3))
                    .foregroundStyle(folder.color?.color ?? Color.accentColor)
                Text(folder.displayName)
                    .font(.panel(.headline))
                    .lineLimit(1)
                Spacer()
                Text("\(folder.noteCount)")
                    .font(.panel(.subheadline).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if subfolders.isEmpty, notes.isEmpty {
                emptyFolderPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Subfolders
                        ForEach(subfolders) { subfolder in
                            PeekRowButton(action: { onOpen?(.folder(subfolder.name)) }) {
                                subfolderRow(subfolder)
                            }
                            Divider()
                                .padding(.horizontal, 16)
                        }
                        // Notes
                        ForEach(notes) { note in
                            PeekRowButton(action: { onOpen?(.note(note.id)) }) {
                                folderNoteRow(note)
                            }
                            if note.id != notes.last?.id {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Compact row for a subfolder inside a folder preview.
    private func subfolderRow(_ subfolder: Folder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.panel(.title3))
                .foregroundStyle(subfolder.color?.color ?? Color.accentColor)
                .frame(width: 22)

            Text(subfolder.displayName)
                .font(.panel(.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text("\(subfolder.noteCount)")
                .font(.panel(.caption1).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyFolderPlaceholder: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 32)
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(l10n["peek.emptyFolder"])
                .font(.panel(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Compact row for a child note inside a folder preview. Matches the NoteRowView
    /// look so the preview reads as the same list the user would see on open.
    private func folderNoteRow(_ note: Note) -> some View {
        HStack(spacing: 10) {
            NoteTypeIcon(note: note, width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if !note.isLocked {
                        TagDotsView(tags: note.tags)
                    }
                    Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                        .font(.panel(.body))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(note.modifiedAt.homeDisplayFormat)
                        .font(.panel(.caption1))
                        .foregroundStyle(.tertiary)
                }
                if !note.previewText.isEmpty {
                    Text(note.previewText)
                        .font(.panel(.caption1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of a folder preview: highlights under the pointer and opens on click.
private struct PeekRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(isHovered ? 0.08 : 0))
        .onHover { isHovered = $0 }
    }
}
