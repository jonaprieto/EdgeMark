import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

// MARK: - Image provider

/// Loads EdgeMark asset-dir images for the `![[.STEM/IMG-uuid.ext]]` embed syntax
/// used by the editor's display layer. The on-disk format stays as standard
/// `![](path)` markdown; MarkdownEditorView converts between the two transparently.
struct EdgeMarkImageProvider: EmbeddedImageProvider {
    let noteFolder: String

    func image(for request: EmbeddedImageRequest) -> NSImage? {
        // request.name is the relative path, e.g. ".My-Note/IMG-uuid.png"
        var base = FileStorage.rootURL
        if !noteFolder.isEmpty {
            base = base.appendingPathComponent(noteFolder, isDirectory: true)
        }
        if let image = NSImage(contentsOf: base.appendingPathComponent(request.name)) {
            return image
        }
        // A reference written before asset stems were made safe ("Q3)-results") may point
        // at an image that now lives in the safe-stem folder ("Q3--results").
        guard let safePath = NoteText.safeAssetPath(request.name) else { return nil }
        return NSImage(contentsOf: base.appendingPathComponent(safePath))
    }

    func fingerprint() -> AnyHashable {
        noteFolder
    }
}

// MARK: - MarkdownEditorView

/// SwiftUI wrapper around NativeTextViewWrapper (swift-markdown-engine).
/// Manages heading stripping, save debouncing, font observation, and the
/// slash-command popup.
struct MarkdownEditorView: View {
    let noteID: UUID
    let noteTitle: String
    let noteFolder: String
    let initialContent: String
    let onContentChanged: (UUID, String) -> Void
    /// Set to new full note content to reload the editor (e.g. from file watcher).
    /// Cleared automatically after the view applies it.
    @Binding var pendingReload: String?
    /// When true, the find bar overlay is visible. Driven by EditorScreen via ⌘F routing.
    var showFindBar: Binding<Bool> = .constant(false)
    var onNavigateNext: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?

    @State private var text: String
    @State private var hiddenHeadingLine: String
    /// The line breaks between the hidden heading and the body, kept as on disk ("\r\n"
    /// files, one or several blank lines) so viewing a note does not rewrite it.
    @State private var headingSeparator: String
    /// Alt text of each EdgeMark image, keyed by path. The `![[path]]` embed shown in the
    /// editor has no place for it, so it is put back when the text is converted for saving.
    @State private var imageAlts: [String: String]
    /// Whether the text was loaded with a leading front matter block, marked for display
    /// by `NoteText.frontMatterToDisplay`; the marks are then removed again on save.
    @State private var frontMatterMarked: Bool
    /// Whether Mermaid blocks were wrapped for display by `MermaidText.toDisplay`; the
    /// wrapping is removed again on save.
    @State private var mermaidMarked: Bool
    @State private var mermaidColumn = MermaidColumn()
    @State private var saveDebouncer = Debouncer(delay: 1.0)
    @State private var slashHandler = SlashCommandHandler()
    @State private var noteNavMonitor: Any?
    @State private var codeBlocks = CodeBlockOverlayModel()

    /// Per-note scroll offsets persisted across editor unmount/remount (engine 0.12.0
    /// `onPersistScrollOffset` / `restoreScrollOffset`). Session-level — not persisted
    /// to disk (matches the engine's original coordinator-level offsets). Keyed by noteID.
    private static var scrollOffsets: [String: CGFloat] = [:]
    /// Latched at init — never updated on re-render. Guards against @Observable pushing
    /// a new selectedNote into the animating-out EditorScreen, which would overwrite
    /// onContentChanged's captured note ID while @State text still holds the old note's content.
    @State private var stableNoteID: UUID

    init(
        noteID: UUID,
        noteTitle: String,
        noteFolder: String,
        initialContent: String,
        onContentChanged: @escaping (UUID, String) -> Void,
        pendingReload: Binding<String?> = .constant(nil),
        showFindBar: Binding<Bool> = .constant(false),
        onNavigateNext: (() -> Void)? = nil,
        onNavigatePrevious: (() -> Void)? = nil,
    ) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.noteFolder = noteFolder
        self.initialContent = initialContent
        self.onContentChanged = onContentChanged
        _pendingReload = pendingReload
        self.showFindBar = showFindBar
        self.onNavigateNext = onNavigateNext
        self.onNavigatePrevious = onNavigatePrevious
        let (heading, separator, body) = NoteText.splitHeading(initialContent)
        let display = Self.displayText(heading: heading, body: body)
        _text = State(initialValue: display.text)
        _imageAlts = State(initialValue: display.alts)
        _frontMatterMarked = State(initialValue: display.frontMatterMarked)
        _mermaidMarked = State(initialValue: display.mermaidMarked)
        _hiddenHeadingLine = State(initialValue: heading)
        _headingSeparator = State(initialValue: separator)
        _stableNoteID = State(initialValue: noteID)
    }

    var body: some View {
        // Reading AppSettings.shared properties here registers @Observable tracking —
        // the view re-renders (and NativeTextViewWrapper.updateNSView re-applies font)
        // whenever editorFontName or editorFontSize changes.
        let appSettings = AppSettings.shared
        let fontName = Self.resolvedFontFamily(from: appSettings.editorFontName) ?? "SF Pro"
        let fontSize = CGFloat(appSettings.editorFontSize)

        var config = MarkdownEditorConfiguration.makeEdgeMarkConfig(
            noteFolder: noteFolder,
            fontSize: fontSize,
            mermaidColumn: mermaidColumn,
            bus: MarkdownEditorBus(
                // Formatting-request channels — posting these drives the engine's
                // didMarkdown* actions (bold/italic/code/link/strikethrough), which in
                // 0.8+ also word-wrap the token under the caret when nothing is selected.
                applyBoldRequest: .editorApplyBold,
                applyItalicRequest: .editorApplyItalic,
                applyStrikethroughRequest: .editorApplyStrikethrough,
                applyInlineCodeRequest: .editorApplyInlineCode,
                applyLinkRequest: .editorApplyLink,
                findScrollToRange: .editorFindScrollToRange,
                findClearHighlights: .editorFindClearHighlights,
            ),
        )
        config.spellChecking = SpellCheckingPolicy(
            continuousSpellChecking: appSettings.spellCheckingEnabled,
            grammarChecking: appSettings.grammarCheckingEnabled,
            automaticSpellingCorrection: appSettings.automaticSpellingCorrectionEnabled,
        )

        return ZStack(alignment: .bottom) {
            NativeTextViewWrapper(
                text: $text,
                configuration: config,
                fontName: fontName,
                fontSize: fontSize,
                documentId: noteID.uuidString,
                onPasteImage: { [noteID, noteTitle, noteFolder] pasteboard in
                    guard let (data, ext) = Self.imageData(from: pasteboard) else { return nil }
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    // Return embed syntax — gets inserted into the display-layer text.
                    // onChange converts it back to standard ![](path) markdown before saving.
                    return (try? FileStorage.saveImage(data: data, ext: ext, forNote: note))?.embedMarkdown
                },
                onCodeBlockSelectionChange: { [codeBlocks] in codeBlocks.update($0) },
                onSpellCheckingPolicyChanged: { policy in
                    // Persist context-menu spelling/grammar/autocorrect toggles back to settings
                    // so they survive note switches and app restarts.
                    AppSettings.shared.spellCheckingEnabled = policy.continuousSpellChecking
                    AppSettings.shared.grammarCheckingEnabled = policy.grammarChecking
                    AppSettings.shared.automaticSpellingCorrectionEnabled = policy.automaticSpellingCorrection
                },
                onPersistScrollOffset: { docId, offset in
                    Self.scrollOffsets[docId] = offset
                },
                restoreScrollOffset: { docId in
                    Self.scrollOffsets[docId]
                },
            )
            // Force the text view to rebuild (makeNSView) when the task-checkbox style or
            // the font size changes: the engine's updateNSView doesn't sync taskCheckbox or
            // extensions, so only a full config re-application picks up the new values.
            .id(EditorRebuildKey.current)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [mermaidColumn] width in
                mermaidColumn.update(viewWidth: width, restyle: mermaidMarked)
            }
            // Line numbers + hover copy button. Copies what is saved to disk: image
            // embeds inside the block are mapped back to `![](path)` like on save.
            .codeBlockChrome(
                codeBlocks,
                metrics: CodeBlockMetrics(configuration: config, bodySize: fontSize),
                transformCopy: { [imageAlts] in Self.embedsToImages($0, alts: imageAlts) },
            )
            .onChange(of: text) { _, newText in
                let cursorPos = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange().location ?? 0
                slashHandler.contentDidChange(content: newText, cursorPos: cursorPos)
                let heading = hiddenHeadingLine
                let separator = headingSeparator
                let noteIDSnapshot = stableNoteID
                let alts = imageAlts
                let marked = frontMatterMarked
                let mermaid = mermaidMarked
                saveDebouncer.call { [onContentChanged] in
                    // Convert display-layer ![[path]] embeds back to on-disk ![alt](path) before saving.
                    let storage = Self.storageText(
                        newText, alts: alts, frontMatterMarked: marked, mermaidMarked: mermaid,
                    )
                    let full = NoteText.joinHeading(heading, separator: separator, body: storage)
                    onContentChanged(noteIDSnapshot, full)
                }
            }
            .onChange(of: pendingReload) { _, newContent in
                guard let newContent else { return }
                saveDebouncer.cancel()
                let (heading, separator, body) = NoteText.splitHeading(newContent)
                hiddenHeadingLine = heading
                headingSeparator = separator
                let display = Self.displayText(heading: heading, body: body)
                imageAlts = display.alts
                frontMatterMarked = display.frontMatterMarked
                mermaidMarked = display.mermaidMarked
                text = display.text
                pendingReload = nil
            }
            .overlay(
                ImageDropOverlay { [noteID, noteTitle, noteFolder] url in
                    guard let data = try? Data(contentsOf: url) else { return }
                    let ext = url.pathExtension.lowercased()
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    guard let result = try? FileStorage.saveImage(data: data, ext: ext, forNote: note) else { return }
                    // After a drag completes the text view may have lost first responder.
                    // Fall back to walking the window hierarchy to find it.
                    let window = NSApp.keyWindow
                    let tv = (window?.firstResponder as? NSTextView)
                        ?? findEditorTextView(in: window?.contentView)
                    guard let tv else { return }
                    window?.makeFirstResponder(tv)
                    tv.insertText(result.embedMarkdown, replacementRange: tv.selectedRange())
                },
            )

            // Find bar overlay — slides in from the bottom when showFindBar is true.
            if showFindBar.wrappedValue {
                FindBarView(isPresented: showFindBar, editorText: $text)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showFindBar.wrappedValue)
        .onAppear {
            noteNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                // Markdown formatting shortcuts — route through the engine's bus so the
                // didMarkdown* actions run (with word-boundary auto-wrap when no selection).
                // Guard on the editor's text view being focused, not a field editor (find
                // bar / search / rename), so typing into those doesn't bold/italicize.
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.isFieldEditor {
                    let key = event.charactersIgnoringModifiers?.lowercased()
                    let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    if key == "b", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyBold, object: nil); return nil
                    }
                    if key == "i", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyItalic, object: nil); return nil
                    }
                    if key == "e", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyInlineCode, object: nil); return nil
                    }
                    if key == "k", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyLink, object: nil); return nil
                    }
                    if key == "x", mods == [.command, .shift] {
                        NotificationCenter.default.post(name: .editorApplyStrikethrough, object: nil); return nil
                    }
                }
                let s = ShortcutSettings.shared
                if s.previousNoteShortcut?.matches(event) == true {
                    onNavigatePrevious?(); return nil
                }
                if s.nextNoteShortcut?.matches(event) == true {
                    onNavigateNext?(); return nil
                }
                return event
            }
        }
        .onDisappear {
            // Flush debounced save immediately on note switch or panel hide.
            // Use stableNoteID (latched @State) — not noteID (let) — because @Observable
            // may re-render this view with a new note's data while it's animating out,
            // which would update onContentChanged to point to the new note. stableNoteID
            // always holds the note that was active when this view was first inserted.
            let capturedID = stableNoteID
            saveDebouncer.cancel()
            let storage = Self.storageText(
                text, alts: imageAlts, frontMatterMarked: frontMatterMarked, mermaidMarked: mermaidMarked,
            )
            let full = NoteText.joinHeading(hiddenHeadingLine, separator: headingSeparator, body: storage)
            onContentChanged(capturedID, full)
            slashHandler.dismiss()
            if let m = noteNavMonitor {
                NSEvent.removeMonitor(m); noteNavMonitor = nil
            }
        }
    }

    // MARK: - Helpers

    private static func resolvedFontFamily(from postscriptName: String?) -> String? {
        guard let name = postscriptName, let font = NSFont(name: name, size: 16) else { return nil }
        return font.familyName
    }

    /// Editor text for a note body: EdgeMark images as `![[path]]` embeds, a leading front
    /// matter block marked so the engine renders it as a metadata block, and Mermaid blocks
    /// wrapped so it renders them as diagrams. Front matter only counts at the very start
    /// of the note, so not after a hidden heading.
    private static func displayText(heading: String, body: String)
        -> (text: String, alts: [String: String], frontMatterMarked: Bool, mermaidMarked: Bool)
    {
        let display = imagesToEmbedsKeepingAlts(body)
        var text = display.text
        var frontMatterMarked = false
        if heading.isEmpty, let marked = NoteText.frontMatterToDisplay(text) {
            text = marked
            frontMatterMarked = true
        }
        let mermaid = MermaidText.toDisplay(text)
        return (mermaid ?? text, display.alts, frontMatterMarked, mermaid != nil)
    }

    /// Inverse of `displayText` for the body: what is saved to disk.
    private static func storageText(
        _ text: String, alts: [String: String], frontMatterMarked: Bool, mermaidMarked: Bool,
    ) -> String {
        let diagrams = mermaidMarked ? MermaidText.fromDisplay(text) : text
        let unmarked = frontMatterMarked ? NoteText.frontMatterFromDisplay(diagrams) : diagrams
        return embedsToImages(unmarked, alts: alts)
    }

    /// Display text for the PDF export, which never saves: embeds, a marked front matter
    /// block and wrapped Mermaid blocks.
    static func exportDisplayText(_ content: String) -> String {
        let embeds = imagesToEmbeds(content)
        let frontMatter = NoteText.frontMatterToDisplay(embeds) ?? embeds
        return MermaidText.toDisplay(frontMatter) ?? frontMatter
    }

    /// Convert on-disk `![](. STEM/IMG-uuid.ext)` references to editor embed `![[.STEM/IMG-uuid.ext]]`.
    /// Only converts EdgeMark-format images (path starts with `.`, filename starts with `IMG-`).
    /// The STEM may hold `)` (folders named before stems were made safe): the embed carries
    /// it, while a `![](...)` destination would end there. A path with `]` stays `![](...)`,
    /// since an embed ends at the first `]`.
    static func imagesToEmbeds(_ text: String) -> String {
        imagesToEmbedsKeepingAlts(text).text
    }

    /// `imagesToEmbeds` plus the non-empty alt text of each converted image, keyed by path,
    /// for `embedsToImages(_:alts:)` to put back.
    static func imagesToEmbedsKeepingAlts(_ text: String) -> (text: String, alts: [String: String]) {
        guard text.contains("![") else { return (text, [:]) }
        let pattern = #"!\[([^\]]*)\]\((\.[^/\n]+/IMG-[A-Za-z0-9\-]+\.[A-Za-z0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, [:]) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        let result = NSMutableString(string: text)
        var alts: [String: String] = [:]
        for match in matches {
            let alt = ns.substring(with: match.range(at: 1))
            let path = ns.substring(with: match.range(at: 2))
            if path.contains("]") {
                continue
            }
            if !alt.isEmpty {
                alts[path] = alt
            }
            result.replaceCharacters(in: match.range, with: "![[\(path)]]")
        }
        return (result as String, alts)
    }

    /// Convert editor embed `![[.STEM/IMG-uuid.ext]]` back to on-disk `![alt](path)`, with the
    /// alt from `alts` (captured by `imagesToEmbedsKeepingAlts`) or empty for new images.
    static func embedsToImages(_ text: String, alts: [String: String] = [:]) -> String {
        guard text.contains("![[") else { return text }
        let pattern = #"!\[\[(\.[^/\]\n]+/IMG-[A-Za-z0-9\-]+\.[A-Za-z0-9]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        let result = NSMutableString(string: text)
        for match in matches {
            let path = ns.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: "![\(alts[path] ?? "")](\(path))")
        }
        return result as String
    }

    private static func imageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) {
            return (data, "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let img = NSImage(data: tiff),
           let rep = NSBitmapImageRep(data: img.tiffRepresentation ?? Data()),
           let png = rep.representation(using: .png, properties: [:])
        {
            return (png, "png")
        }
        return nil
    }
}

// MARK: - Notification names for the editor find bus

extension Notification.Name {
    static let editorFindScrollToRange = Notification.Name("io.github.ender-wang.EdgeMark.editor.findScrollToRange")
    static let editorFindClearHighlights = Notification.Name("io.github.ender-wang.EdgeMark.editor.findClearHighlights")

    // Formatting-request bus channels — posting these drives the engine's
    // didMarkdown* actions (routed from the ⌘B/⌘I/⌘E/⌘K/⇧⌘X local key monitor).
    static let editorApplyBold = Notification.Name("io.github.ender-wang.EdgeMark.editor.applyBold")
    static let editorApplyItalic = Notification.Name("io.github.ender-wang.EdgeMark.editor.applyItalic")
    static let editorApplyInlineCode = Notification.Name("io.github.ender-wang.EdgeMark.editor.applyInlineCode")
    static let editorApplyLink = Notification.Name("io.github.ender-wang.EdgeMark.editor.applyLink")
    static let editorApplyStrikethrough = Notification.Name("io.github.ender-wang.EdgeMark.editor.applyStrikethrough")
}
