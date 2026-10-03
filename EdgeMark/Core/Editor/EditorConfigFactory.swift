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
    /// set one point below it. `pinsLightAppearance` keeps the code colors on their light
    /// variants whatever the app appearance, for the PDF export.
    static func makeEdgeMarkConfig(
        noteFolder: String,
        fontSize: CGFloat,
        bus: MarkdownEditorBus = .default,
        pinsLightAppearance: Bool = false,
    ) -> MarkdownEditorConfiguration {
        let preset = AppSettings.shared.taskCheckboxPreset
        let highlighter = HighlighterSwiftBridge(autoSwitchAppearance: !pinsLightAppearance)
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        // Register highlight (==text==) and strikethrough (~~text~~). Opt-in since
        // swift-markdown-engine 0.10; without this, the markers render as literal text.
        // The front matter block only fires on text marked by `NoteText.frontMatterToDisplay`.
        config.extensions = [
            HighlightExtension(),
            StrikethroughExtension(),
            FrontMatterExtension(highlighter: highlighter, bodySize: fontSize),
        ]
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
            syntaxHighlighter: highlighter,
            latex: SwiftMathBridge(),
            bus: bus,
        )
        return config
    }
}

// MARK: - Rebuild key

/// Settings the engine reads only when it makes its text view: `updateNSView` keeps the
/// first configuration's task-checkbox style and extensions (the front matter block's font
/// size). Used as the engine view's `.id`, so a change rebuilds it with the new values.
/// Reading it in a view body registers @Observable tracking on these settings.
struct EditorRebuildKey: Hashable {
    let checkboxPreset: AppSettings.TaskCheckboxPreset
    let fontSize: Double

    static var current: EditorRebuildKey {
        let settings = AppSettings.shared
        return EditorRebuildKey(checkboxPreset: settings.taskCheckboxPreset, fontSize: settings.editorFontSize)
    }
}

// MARK: - Front matter block

/// Shows a leading YAML front matter block as a compact metadata block: code font one
/// point below the body, muted ink, and the code-block background band, with no rules.
/// The engine sees it as a fenced block because the editor marks both delimiter lines
/// with `NoteText.frontMatterMark` (`---` itself would parse as a horizontal rule first);
/// the fence lines hide while the caret is outside the block, like code fences.
nonisolated struct FrontMatterExtension: MarkdownExtension {
    let highlighter: any SyntaxHighlighter
    let bodySize: CGFloat

    var id: String {
        "edgemark.frontMatter"
    }

    var block: BlockSyntax? {
        BlockSyntax(fence: String(NoteText.frontMatterMark))
    }

    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        let font = highlighter.codeFont(size: max(1, bodySize - 1))
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // Same compact spacing as code lines (`CodeBlockMetrics.paragraphSpacing`).
        paragraph.paragraphSpacingBefore = 1
        paragraph.paragraphSpacing = 1
        paragraph.headIndent = 12
        paragraph.firstLineHeadIndent = 12
        paragraph.tailIndent = -12
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // The highlighter's own background color is what the engine paints as a
        // full-width band (it detects code fragments by that color).
        return [
            .font: font,
            .foregroundColor: theme.mutedText,
            .backgroundColor: highlighter.backgroundColor(),
            .paragraphStyle: paragraph,
            .spellingState: 0,
        ]
    }

    func html(childrenHTML: String) -> String {
        "<pre>\(childrenHTML)</pre>"
    }
}
