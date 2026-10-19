import Cocoa
import SwiftUI

struct EditorScreen: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(AppSettings.self) var appSettings
    @Environment(L10n.self) var l10n
    @State private var pendingEditorReload: String? = nil
    @State private var isFindBarShowing = false
    /// The note this screen was opened for; `noteStore.selectedNote` has moved on by the
    /// time the screen disappears.
    @State private var shownNoteID: UUID?
    /// Gist holding the open note, for the header pill; nil for ordinary notes.
    @State private var gist: GitSync.GistInfo?

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
            if let note = noteStore.selectedNote, note.isLocked {
                // No editor while the text is not in memory: it would save emptiness.
                LockedNoteView(note: note)
            } else if let note = noteStore.selectedNote {
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
                        isEncrypted: note.isEncrypted,
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
                        language: note.isPlainTextFile
                            ? SyntaxLanguage.language(forFileName: note.title, content: note.content) : nil,
                        isEncrypted: note.isEncrypted,
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
        .onAppear { shownNoteID = noteStore.selectedNote?.id }
        .onDisappear { lockAfterLeavingEncryptedNote() }
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
    /// note can be typed into right away. The text view may not exist yet, and the title
    /// field being torn down can take focus back, so this retries every 50 ms until the
    /// editor has held focus for 0.4 s, giving up after 2 s or when another note opens.
    private func focusEditorForTyping(noteID: UUID? = nil, attempt: Int = 0, heldFor: Int = 0) {
        let noteID = noteID ?? noteStore.selectedNote?.id
        guard attempt < 40, heldFor < 8, noteID == noteStore.selectedNote?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var held = 0
            for window in NSApp.windows where window.isVisible && window.canBecomeKey {
                guard let tv = findEditorTextView(in: window.contentView) else { continue }
                if window.firstResponder === tv {
                    held = heldFor + 1
                } else {
                    window.makeKey()
                    window.makeFirstResponder(tv)
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                }
                break
            }
            focusEditorForTyping(noteID: noteID, attempt: attempt + 1, heldFor: held)
        }
    }

    /// Leaving an unlocked encrypted note for a plain note or a list ends the session, so
    /// its text does not stay readable behind the user's back. Going on to another
    /// encrypted note keeps it, or every step would ask for the key again. Deferred one
    /// turn so the editor being removed has handed over its last keystrokes.
    private func lockAfterLeavingEncryptedNote() {
        guard EncryptionSettings.shared.lockOnLeave,
              let left = noteStore.notes.first(where: { $0.id == shownNoteID }),
              left.isEncrypted, !left.isLocked else { return }
        let store = noteStore
        DispatchQueue.main.async {
            if store.selectedNote?.isEncrypted != true {
                KeySession.shared.lock()
            }
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        if let note = noteStore.selectedNote {
            VStack(spacing: 4) {
                HStack {
                    HeaderIconButton(
                        systemName: "chevron.left",
                        help: l10n.t("tooltip.backTo", backLabel),
                    ) {
                        goBack()
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if note.isPlainTextFile {
                            FileTypeBadge(fileExtension: note.fileExtension, size: 22)
                        }

                        Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                            .font(.panel(.headline))
                            .lineLimit(1)

                        Text(note.displayDirectory)
                            .font(.panel(.caption1))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        if let gist {
                            GistPill(gist: gist, fileURL: FileStorage.urlForNote(note))
                        }
                    }
                    // The note moves into the clone after publishing, so its path is the
                    // key. No clone is tracked while sync is off, so then there is no pill.
                    .task(id: "\(FileStorage.urlForNote(note).path)|\(GitSync.shared.isActive)") {
                        gist = nil
                        gist = await GitSync.shared.gistInfo(for: FileStorage.urlForNote(note))
                    }

                    Spacer()

                    PinButton()

                    if let gist {
                        GistPushButton(repoURL: gist.repoURL, fileURL: FileStorage.urlForNote(note))
                    }

                    // The visible way to encrypt the open note; the row menu has it too.
                    // An encrypted note shows a closed lock that ends the session.
                    if !note.isEncrypted {
                        HeaderIconButton(systemName: "lock.open", help: l10n["tooltip.encryptNote"]) {
                            noteStore.requestEncrypt(note)
                        }
                    } else if !note.isLocked {
                        HeaderIconButton(systemName: "lock.fill", help: l10n["encryption.lockNow"]) {
                            KeySession.shared.lock()
                        }
                    }

                    ReminderButton(note: note)

                    // A locked note has no text to copy or export.
                    if !note.isLocked {
                        CopyMenuButton(note: note)

                        ExportMenuButton(note: note)
                    }

                    // Moves to Trash like the note list's Delete, so no confirmation, unless
                    // it is the last file of a gist (see `trashItems`).
                    DeleteIconButton {
                        noteStore.closeNote()
                        noteStore.trashItems(notes: [note], folders: [])
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
/// Bell in the editor header: the note's reminder options, with Jev's pick badged.
private struct ReminderButton: View {
    let note: Note

    var body: some View {
        let hasReminder = NoteReminders.shared.noteIDs.contains(note.id)
        HeaderIconButton(systemName: hasReminder ? "bell.fill" : "bell", help: L10n.shared["tooltip.reminder"]) {
            guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
            let (menu, items) = ReminderMenu.menu(for: note)
            // The note's text goes to Jev only now, and never for an encrypted note.
            if !note.isEncrypted {
                let key = GitSync.shared.apiKeyProvider()
                Task { @MainActor in
                    let option = await ReminderSuggestion.suggest(
                        title: note.title, text: note.content, now: Date(), options: Array(items.keys), apiKey: key,
                    )
                    if let option {
                        items[option]?.badge = NSMenuItemBadge(string: L10n.shared["reminder.suggested"])
                    }
                }
            }
            menu.popUpContextMenu(with: event, for: view)
        }
        .task(id: note.id) { await NoteReminders.shared.refresh() }
    }
}

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
        .help(l10n["tooltip.copy"])
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

/// Share icon that opens a menu with the note export formats, plus the gist items of
/// `NoteExporter.gistOffer` when sync is active.
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
            gistItems(l10n)
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
        .help(l10n["tooltip.export"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    /// Re-read on every header render (each edit changes `note`), like the context menu,
    /// which reads it when it opens. With images the export items stay visible but
    /// disabled, with the reason as tooltip.
    @ViewBuilder
    private func gistItems(_ l10n: L10n) -> some View {
        switch NoteExporter.gistOffer(for: note) {
        case .none:
            EmptyView()
        case let .publish(blockedByImages):
            Divider()
            ForEach([false, true], id: \.self) { isPublic in
                Button(l10n[isPublic ? "export.gistPublic" : "export.gistPrivate"]) {
                    NoteExporter.exportAsGist(note: note, noteStore: noteStore, isPublic: isPublic)
                }
                .disabled(blockedByImages)
                .help(blockedByImages ? l10n["export.gistHasImages"] : "")
            }
        case .linkToGist:
            Divider()
            Button(l10n["sync.copyGistLink"]) {
                NoteExporter.copyGistLink(note: note)
            }
            Button(l10n["sync.openGist"]) {
                NoteExporter.openGist(note: note)
            }
        }
    }
}

// MARK: - Gist Pill

/// Small "Gist" pill shown in the header of a note that lives in a gist clone; its menu
/// links to the gist and syncs it. `EditorScreen` looks the gist up.
private struct GistPill: View {
    let gist: GitSync.GistInfo
    let fileURL: URL

    var body: some View {
        let l10n = L10n.shared
        Menu {
            Button(l10n["sync.copyGistLink"]) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(gist.webURL.absoluteString, forType: .string)
            }
            Button(l10n["gist.openOnGitHub"]) {
                NSWorkspace.shared.open(gist.webURL)
            }
            Divider()
            // Every repo, not only this gist: the pull is what reloads the open note.
            Button(l10n["sync.syncNow"]) {
                Task { await GitSync.shared.syncNow() }
            }
            Button(l10n["common.showInFinder"]) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } label: {
            Text(l10n["gist.pill"])
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n["tooltip.gistPill"])
    }
}

// MARK: - Gist Push Button

/// Pushes the open note's gist now instead of after the gist delay. The icon shows the
/// gist's sync state, so the click visibly lands.
private struct GistPushButton: View {
    let repoURL: URL
    let fileURL: URL

    @Environment(NoteStore.self) private var noteStore

    var body: some View {
        let state = GitSync.shared.repoStates[repoURL] ?? .idle(lastSync: nil)
        HeaderIconButton(systemName: Self.symbol(for: state), help: L10n.shared.t("tooltip.gist.pushNow", state.summary)) {
            // The last keystrokes may still be in the editor or only in memory.
            noteStore.onFlushEditor?()
            noteStore.saveDirtyNotes()
            Task { await GitSync.shared.pushNow(containing: fileURL) }
        }
        .disabled(state == .syncing)
    }

    private static func symbol(for state: SyncState) -> String {
        switch state {
        case .syncing: "arrow.triangle.2.circlepath"
        case .pending: "icloud.and.arrow.up"
        case .idle: "checkmark.icloud"
        default: "exclamationmark.icloud"
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
        .help(L10n.shared["tooltip.deleteNote"])
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
        .font(.panel(.caption1))
        .foregroundStyle(.tertiary)
        .contentShape(Rectangle())
        .help(tooltip)
    }
}
