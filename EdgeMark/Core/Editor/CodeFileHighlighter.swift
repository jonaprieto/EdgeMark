import AppKit
import MarkdownEngineCodeBlocks

/// Syntax colours for a gist code file shown in `PlainTextView`, from the same highlight.js
/// themes as the editor's code blocks (`HighlighterSwiftBridge` defaults: atom-one-light and
/// atom-one-dark). highlight.js runs on a private serial queue; only foreground colour runs
/// come back, so the caller recolours its text storage and never touches the characters.
nonisolated final class CodeFileHighlighter: @unchecked Sendable {
    /// One foreground colour over a UTF-16 range of the highlighted text.
    struct Run {
        let range: NSRange
        let color: NSColor
    }

    static let shared = CodeFileHighlighter()

    private let queue = DispatchQueue(label: "EdgeMark.CodeFileHighlighter", qos: .userInitiated)
    // Each bridge is pinned to one theme, so it never reads `NSApp` to pick one and can run
    // off the main thread; both are only used on `queue`, which keeps their JavaScript
    // contexts single-threaded. Made on first use there.
    private var light: HighlighterSwiftBridge?
    private var dark: HighlighterSwiftBridge?

    /// Colour runs for `text` in `language`, delivered on the main thread. Nil when `text`
    /// is too large (`SyntaxLanguage.isSmallEnough`), highlighting fails, or the highlighter
    /// would give back different characters.
    func colorRuns(for text: String, language: String, dark isDark: Bool, completion: @escaping @MainActor ([Run]?) -> Void) {
        queue.async { [self] in
            let runs = SyntaxLanguage.isSmallEnough(text) ? runs(for: text, language: language, dark: isDark) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(runs) }
            }
        }
    }

    /// Synchronous variant of `colorRuns`, for the offscreen check harness.
    func colorRunsNow(for text: String, language: String, dark isDark: Bool) -> [Run]? {
        queue.sync { SyntaxLanguage.isSmallEnough(text) ? runs(for: text, language: language, dark: isDark) : nil }
    }

    /// On `queue` only.
    private func runs(for text: String, language: String, dark isDark: Bool) -> [Run]? {
        let bridge: HighlighterSwiftBridge
        if isDark {
            bridge = dark ?? HighlighterSwiftBridge(lightTheme: "atom-one-dark", autoSwitchAppearance: false)
            dark = bridge
        } else {
            bridge = light ?? HighlighterSwiftBridge(lightTheme: "atom-one-light", autoSwitchAppearance: false)
            light = bridge
        }
        guard let highlighted = bridge.highlight(code: text, language: language),
              highlighted.string.utf16.elementsEqual(text.utf16) else { return nil }
        var runs: [Run] = []
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, range, _ in
            if let color = value as? NSColor {
                runs.append(Run(range: range, color: color))
            }
        }
        return runs
    }

    /// Recolours `storage` with `runs`, or with `base` alone when `runs` is nil. Attributes
    /// only, outside the text view's change and undo machinery, so the characters, the
    /// selection and the undo stack are left as they are. `runs` must come from the
    /// storage's current string.
    @MainActor
    static func apply(_ runs: [Run]?, to storage: NSTextStorage, base: NSColor) {
        let length = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: base, range: NSRange(location: 0, length: length))
        for run in runs ?? [] where NSMaxRange(run.range) <= length {
            storage.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        storage.endEditing()
    }
}
