import Cocoa
import SwiftUI

struct EditorScreen: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(AppSettings.self) var appSettings
    @Environment(L10n.self) var l10n
    @State private var pendingEditorReload: String? = nil
    @State private var isFindBarShowing = false

    private var backLabel: String {
        noteStore.selectedFolder?.name ?? l10n["common.home"]
    }

    var body: some View {
        PageLayout(
            onSwipeBack: { goBack() },
            onContentSwipeRight: PanelSettings.shared.editorSwipeToNavigateEnabled
                ? { noteStore.navigateToPreviousNote(sortedBy: appSettings) } : nil,
            onContentSwipeLeft: PanelSettings.shared.editorSwipeToNavigateEnabled
                ? { noteStore.navigateToNextNote(sortedBy: appSettings) } : nil,
        ) {
            headerContent
        } content: {
            if let note = noteStore.selectedNote {
                EditorModeChooser(content: note.content, isPlainTextFile: note.isPlainTextFile) {
                    MarkdownEditorView(
                        noteID: note.id,
                        noteTitle: note.title,
                        noteFolder: note.folder,
                        initialContent: note.content,
                        onContentChanged: { id, newContent in
                            noteStore.updateContent(for: id, content: newContent)
                        },
                        pendingReload: $pendingEditorReload,
                        showFindBar: $isFindBarShowing,
                        onNavigateNext: { noteStore.navigateToNextNote(sortedBy: appSettings) },
                        onNavigatePrevious: { noteStore.navigateToPreviousNote(sortedBy: appSettings) },
                    )
                } plain: {
                    PlainTextNoteEditor(
                        noteID: note.id,
                        initialContent: note.content,
                        onContentChanged: { id, newContent in
                            noteStore.updateContent(for: id, content: newContent)
                        },
                        pendingReload: $pendingEditorReload,
                        showsBanner: !note.isPlainTextFile,
                    )
                }
                .onAppear {
                    noteStore.onNeedEditorReload = { content in
                        pendingEditorReload = content
                    }
                    if noteStore.focusEditorOnOpen {
                        noteStore.focusEditorOnOpen = false
                        focusEditorForTyping()
                    }
                }
                .onChange(of: noteStore.pendingEditorFind) { _, pending in
                    guard pending else { return }
                    noteStore.pendingEditorFind = false
                    isFindBarShowing = true
                }
            }
        }
        .alert(
            l10n["alert.externalChange.title"],
            isPresented: Binding(
                get: { noteStore.pendingExternalChange != nil },
                set: {
                    if !$0 {
                        noteStore.pendingExternalChange = nil
                    }
                },
            ),
        ) {
            Button(l10n["alert.externalChange.keepEdgeMarkEdits"]) {
                noteStore.resolveExternalChange(keepEdgeMarkEdits: true)
            }
            Button(l10n["alert.externalChange.reloadFromDisk"], role: .destructive) {
                noteStore.resolveExternalChange(keepEdgeMarkEdits: false)
            }
        } message: {
            Text(l10n["alert.externalChange.message"])
        }
    }

    /// Gives the editor keyboard focus with the cursor at the end, so a freshly created
    /// note can be typed into right away. Waits for the push transition to finish.
    private func focusEditorForTyping() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
            guard let window, let tv = findEditorTextView(in: window.contentView) else { return }
            window.makeKey()
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        if let note = noteStore.selectedNote {
            VStack(spacing: 4) {
                HStack {
                    HeaderIconButton(
                        systemName: "chevron.left",
                        help: backLabel,
                    ) {
                        goBack()
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if note.isPlainTextFile {
                            FileTypeBadge(fileExtension: note.fileExtension, size: 22)
                        }

                        Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(note.displayDirectory)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    PinButton()

                    CopyMenuButton(note: note)

                    ExportMenuButton(note: note)

                    // Moves to Trash like the note list's Delete, so no confirmation.
                    DeleteIconButton {
                        noteStore.closeNote()
                        noteStore.trashNote(note)
                    }
                }

                HStack(spacing: 12) {
                    DateLabelView(
                        systemName: "clock",
                        date: note.modifiedAt.homeDisplayFormat,
                        tooltip: L10n.shared.t("editor.modifiedAt", note.modifiedAt.homeDisplayFormat),
                    )

                    DateLabelView(
                        systemName: "calendar",
                        date: note.createdAt.homeDisplayFormat,
                        tooltip: L10n.shared.t("editor.createdAt", note.createdAt.homeDisplayFormat),
                    )
                }
            }
        }
    }

    private func goBack() {
        noteStore.closeNote()
    }
}

// MARK: - Editor Mode

/// Picks the editor once per note, from the content it opened with: the plain-text editor
/// for a non-Markdown gist file or when `NoteComplexity.isHeavy`, the Markdown editor
/// otherwise. Latched so the editor does not swap while typing across a limit; the next
/// open decides again.
private struct EditorModeChooser<Rich: View, Plain: View>: View {
    @State private var isHeavy: Bool
    private let rich: () -> Rich
    private let plain: () -> Plain

    init(content: String, isPlainTextFile: Bool, @ViewBuilder rich: @escaping () -> Rich, @ViewBuilder plain: @escaping () -> Plain) {
        _isHeavy = State(initialValue: isPlainTextFile || NoteComplexity.isHeavy(content))
        self.rich = rich
        self.plain = plain
    }

    var body: some View {
        if isHeavy {
            plain()
        } else {
            rich()
        }
    }
}

// MARK: - Copy Menu Button

/// Copy icon that opens a menu with plain text and Markdown copy options.
/// If text is selected in the editor, copies the selection; otherwise copies the whole document.
private struct CopyMenuButton: View {
    let note: Note

    @State private var isHovered = false

    var body: some View {
        let l10n = L10n.shared
        Menu {
            Button(l10n["common.copyPlainText"]) {
                let selected = Self.getSelectedText()
                let source = selected.isEmpty ? note.content : selected
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Note.plainText(from: source), forType: .string)
            }
            Button(l10n["common.copyMarkdown"]) {
                let selected = Self.getSelectedText()
                let text = selected.isEmpty ? note.content : selected
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button(l10n["common.copyRTF"]) {
                let selected = Self.getSelectedText()
                let source = selected.isEmpty ? note.content : selected
                let pb = NSPasteboard.general
                pb.clearContents()
                if let rtf = Note.rtfData(from: source) {
                    pb.setData(rtf, forType: .rtf)
                } else {
                    pb.setString(Note.plainText(from: source), forType: .string)
                }
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n["editor.copyNote"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private static func getSelectedText() -> String {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
              tv.selectedRange().length > 0
        else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
}

// MARK: - Export Menu Button

/// Share icon that opens a menu with the note export formats.
private struct ExportMenuButton: View {
    let note: Note

    @Environment(NoteStore.self) private var noteStore
    @State private var isHovered = false

    var body: some View {
        let l10n = L10n.shared
        Menu {
            Button(l10n["export.markdown"]) {
                NoteExporter.exportMarkdown(note: note, noteStore: noteStore)
            }
            Button(l10n["export.pdf"]) {
                NoteExporter.exportPDF(note: note, noteStore: noteStore)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n["editor.exportNote"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Delete Icon Button

/// Trash icon that turns red on hover.
private struct DeleteIconButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? .red : .secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.shared["editor.deleteNote"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Date Label View

/// Icon + date text in a compact row with hover tooltip.
private struct DateLabelView: View {
    let systemName: String
    let date: String
    let tooltip: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
            Text(date)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .contentShape(Rectangle())
        .help(tooltip)
    }
}
