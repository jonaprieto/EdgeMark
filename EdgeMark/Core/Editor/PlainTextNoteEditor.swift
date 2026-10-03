import AppKit
import SwiftUI

/// Editor for notes that `NoteComplexity.isHeavy` flags: a plain `NSTextView` with the
/// user's monospace font and no Markdown engine, highlighting or spell checking, so a huge or
/// pathological note stays responsive. Saves through the same `onContentChanged` path as
/// `MarkdownEditorView` (debounced, flushed on disappear) and applies `pendingReload`.
/// Non-Markdown gist files open here too, without the large-note banner.
struct PlainTextNoteEditor: View {
    let initialContent: String
    let showsBanner: Bool
    let onContentChanged: (UUID, String) -> Void
    @Binding var pendingReload: String?

    /// Latched at init, like `MarkdownEditorView.stableNoteID`: an animating-out editor
    /// may be re-rendered with the next note's data, but must keep saving its own note.
    @State private var model: PlainTextEditorModel

    init(
        noteID: UUID,
        initialContent: String,
        onContentChanged: @escaping (UUID, String) -> Void,
        pendingReload: Binding<String?>,
        showsBanner: Bool = true,
    ) {
        self.initialContent = initialContent
        self.showsBanner = showsBanner
        self.onContentChanged = onContentChanged
        _pendingReload = pendingReload
        _model = State(initialValue: PlainTextEditorModel(noteID: noteID))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsBanner {
                Text(L10n.shared["editor.plainTextBanner"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
            }
            PlainTextView(
                model: model,
                initialContent: initialContent,
                monoFontName: AppSettings.shared.editorMonoFontName,
            )
        }
        .onAppear {
            model.onSave = onContentChanged
        }
        .onChange(of: pendingReload) { _, newContent in
            guard let newContent else { return }
            model.replaceText(newContent)
            pendingReload = nil
        }
        .onDisappear {
            model.flush()
        }
    }
}

/// Owns the text view's save debouncing so the SwiftUI side can flush and reload it.
final class PlainTextEditorModel: NSObject, NSTextViewDelegate {
    let noteID: UUID
    var onSave: ((UUID, String) -> Void)?
    weak var textView: NSTextView?
    private let saveDebouncer = Debouncer(delay: 1.0)
    private var hasEdits = false

    init(noteID: UUID) {
        self.noteID = noteID
    }

    func textDidChange(_: Notification) {
        hasEdits = true
        saveDebouncer.call { [weak self] in self?.flush() }
    }

    /// Push the text to the store if the user edited it since the last push.
    func flush() {
        saveDebouncer.cancel()
        guard hasEdits, let textView else { return }
        hasEdits = false
        onSave?(noteID, textView.string)
    }

    func replaceText(_ text: String) {
        saveDebouncer.cancel()
        hasEdits = false
        textView?.string = text
    }
}

/// The plain `NSTextView`, also used read-only by `ReadOnlyMarkdownView` for heavy notes.
struct PlainTextView: NSViewRepresentable {
    let model: PlainTextEditorModel
    let initialContent: String
    /// `AppSettings.editorMonoFontName`, passed in so the parent's body tracks it and a
    /// change reaches `updateNSView`.
    let monoFontName: String?
    var isEditable = true

    /// The monospace font at the system text size; the system monospaced font by default.
    private static func font(named name: String?) -> NSFont {
        let size = NSFont.systemFontSize
        return name.flatMap { NSFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeNSView(context _: Context) -> NSScrollView {
        // TextKit 1 with non-contiguous layout lays out only what is on screen, which
        // keeps a multi-megabyte note scrollable.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.font = Self.font(named: monoFontName)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = initialContent
        textView.delegate = model
        model.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let font = Self.font(named: monoFontName)
        if textView.font != font {
            textView.font = font
        }
    }
}
