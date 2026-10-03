import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

// MARK: - Shared editor configuration

extension MarkdownEditorConfiguration {
    /// Shared config for the live editor and the read-only preview/card view.
    ///
    /// Both call sites must stay in sync so previews match the editor. Keeps the
    /// text insets, highlight/strikethrough extensions, task-checkbox style, and the
    /// image/syntax/latex services in one place. The live editor passes its
    /// formatting-request `bus`; the read-only view uses the default (no formatting).
    /// `fontSize` is the body size handed to NativeTextViewWrapper; code blocks are
    /// set one point below it.
    static func makeEdgeMarkConfig(
        noteFolder: String,
        fontSize: CGFloat,
        bus: MarkdownEditorBus = .default,
    ) -> MarkdownEditorConfiguration {
        let preset = AppSettings.shared.taskCheckboxPreset
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        // Register highlight (==text==) and strikethrough (~~text~~). Opt-in since
        // swift-markdown-engine 0.10; without this, the markers render as literal text.
        config.extensions = [HighlightExtension(), StrikethroughExtension()]
        // Compact code blocks: half the default line spacing, and a wider indent that
        // leaves room for the line-number gutter drawn by `codeBlockChrome`.
        config.codeBlock = CodeBlockStyle(
            fontSizeScale: CodeBlockMetrics.fontSizeScale(bodySize: fontSize),
            paragraphSpacing: CodeBlockMetrics.paragraphSpacing,
            horizontalIndent: CodeBlockMetrics.textIndent,
        )
        config.taskCheckbox = TaskCheckboxStyle(
            uncheckedSymbolName: preset.uncheckedSymbolName,
            checkedSymbolName: preset.checkedSymbolName,
        )
        config.services = MarkdownEditorServices(
            images: EdgeMarkImageProvider(noteFolder: noteFolder),
            syntaxHighlighter: HighlighterSwiftBridge(),
            latex: SwiftMathBridge(),
            bus: bus,
        )
        return config
    }
}
