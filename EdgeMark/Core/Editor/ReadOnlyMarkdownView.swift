import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// Non-editable Markdown viewer using swift-markdown-engine.
/// Used for previewing trashed notes and peek previews.
struct ReadOnlyMarkdownView: View {
    let content: String
    var noteFolder: String = ""

    @State private var codeBlocks = CodeBlockOverlayModel()

    /// NativeTextViewWrapper's default body size, which this view does not override.
    private static let fontSize: CGFloat = 16

    var body: some View {
        // Heavy notes would freeze the engine here too (trash preview, hover peek).
        if NoteComplexity.isHeavy(content) {
            PlainTextView(
                model: PlainTextEditorModel(noteID: UUID()),
                initialContent: content,
                monoFontName: AppSettings.shared.editorMonoFontName,
                isEditable: false,
            )
        } else {
            markdownBody
        }
    }

    private var markdownBody: some View {
        // Shared with the live editor so previews match. `.id` rebuilds the view
        // (makeNSView) when a setting in `EditorRebuildKey` changes: updateNSView doesn't
        // sync taskCheckbox or extensions, so only a full re-apply picks them up.
        let config = MarkdownEditorConfiguration.makeEdgeMarkConfig(noteFolder: noteFolder, fontSize: Self.fontSize)
        // A leading front matter block renders as a metadata block, as in the editor.
        return NativeTextViewWrapper(
            text: .constant(NoteText.frontMatterToDisplay(content) ?? content),
            configuration: config,
            fontSize: Self.fontSize,
            isEditable: false,
            onCodeBlockSelectionChange: { [codeBlocks] in codeBlocks.update($0) },
        )
        .id(EditorRebuildKey.current)
        .codeBlockChrome(codeBlocks, metrics: CodeBlockMetrics(configuration: config, bodySize: Self.fontSize))
    }
}
