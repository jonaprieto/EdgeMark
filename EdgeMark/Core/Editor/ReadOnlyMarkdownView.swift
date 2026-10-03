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
        // Shared with the live editor so previews match. `.id` rebuilds the view
        // (makeNSView) when the task-checkbox style changes — updateNSView doesn't
        // sync taskCheckbox, so only a full re-apply picks up the new symbols.
        let config = MarkdownEditorConfiguration.makeEdgeMarkConfig(noteFolder: noteFolder, fontSize: Self.fontSize)
        return NativeTextViewWrapper(
            text: .constant(content),
            configuration: config,
            fontSize: Self.fontSize,
            isEditable: false,
            onCodeBlockSelectionChange: { [codeBlocks] in codeBlocks.update($0) },
        )
        .id(AppSettings.shared.taskCheckboxPreset)
        .codeBlockChrome(codeBlocks, metrics: CodeBlockMetrics(configuration: config, bodySize: Self.fontSize))
    }
}
