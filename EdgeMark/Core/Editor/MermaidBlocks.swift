import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

// MARK: - Column width

/// Width of the text column a view lays diagrams out in. Diagrams render at their natural
/// size and are scaled down to this width, never up. A reference type so the formula
/// bridge (fixed when the engine makes its text view) sees the view's current width.
nonisolated final class MermaidColumn: @unchecked Sendable {
    private(set) var width: CGFloat

    init(width: CGFloat = 600) {
        self.width = width
    }

    /// Sets the column from the engine view's width (text insets of 16 and the text
    /// container's 5 pt line padding on each side). `restyle` when the view shows
    /// diagrams, so they take the new width.
    @MainActor
    func update(viewWidth: CGFloat, restyle: Bool) {
        let column = max(80, viewWidth - 2 * 16 - 10)
        guard abs(column - width) >= 1 else { return }
        width = column
        if restyle {
            MermaidRestyle.schedule()
        }
    }
}

// MARK: - Style

extension MermaidRenderer.Style {
    /// Theme from the app's effective appearance (or light, for paper) and the labels in
    /// the editor's prose font.
    static func current(lightOnly: Bool) -> MermaidRenderer.Style {
        let isDark = !lightOnly && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let system = "-apple-system, BlinkMacSystemFont, sans-serif"
        let family = AppSettings.shared.editorFontName
            .flatMap { NSFont(name: $0, size: 16)?.familyName }
            // Keep the family a plain CSS string: no quotes or syntax from a font name.
            .map { $0.filter { !"\"'\\;{}<>".contains($0) } }
        let fontFamily = family.map { "\"\($0)\", \(system)" } ?? system
        return MermaidRenderer.Style(theme: isDark ? "dark" : "default", fontFamily: fontFamily)
    }
}

// MARK: - Restyle

/// Asks every engine view to restyle, so finished diagrams replace their placeholders.
/// The engine restyles on its highlighter's appearance notification, which carries no
/// payload; bursts (several diagrams finishing, a window resize) collapse into one.
@MainActor
enum MermaidRestyle {
    private static var observer: NSObjectProtocol?
    private static var pending: DispatchWorkItem?

    static func installIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: MermaidRenderer.didRenderNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { schedule() }
        }
    }

    static func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .markdownEngineHighlighterDidChangeAppearance, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}

// MARK: - Formula bridge

/// The engine's formula renderer, extended to Mermaid blocks. The editor wraps each
/// Mermaid block as a display formula (`MermaidText.toDisplay`), so the engine shows this
/// renderer's picture while the caret is outside the block and the editable source while
/// it is inside. Real formulas go to SwiftMath unchanged.
///
/// A diagram not rendered yet, or one that failed, is drawn as its source in the code
/// style, the failure with a one-line red error under it, so the block never flashes
/// the `$$` wrapping and a broken diagram reads like the code block it is.
nonisolated final class MermaidLatexBridge: LatexRenderer, @unchecked Sendable {
    private let math = SwiftMathBridge()
    private let column: MermaidColumn
    private let highlighter: any SyntaxHighlighter
    private let bodySize: CGFloat
    private let lightOnly: Bool

    init(column: MermaidColumn, highlighter: any SyntaxHighlighter, bodySize: CGFloat, lightOnly: Bool) {
        self.column = column
        self.highlighter = highlighter
        self.bodySize = bodySize
        self.lightOnly = lightOnly
    }

    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        guard latex.first == MermaidText.openMark else {
            return math.render(latex: latex, fontSize: fontSize, theme: theme)
        }
        // A marked block whose fence is no longer `mermaid` (being edited) shows as source.
        guard let code = MermaidText.code(fromDisplayContent: latex), Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { diagram(code) }
    }

    @MainActor
    private func diagram(_ code: String) -> LatexRenderResult {
        MermaidRestyle.installIfNeeded()
        let style = MermaidRenderer.Style.current(lightOnly: lightOnly)
        let renderer = MermaidRenderer.shared
        switch renderer.cached(code: code, style: style) {
        case let .image(image):
            let natural = image.size
            let scale = min(1, column.width / max(natural.width, 1))
            let size = CGSize(width: floor(natural.width * scale), height: floor(natural.height * scale))
            return LatexRenderResult(image: image, size: size, baselineOffset: 0)
        case let .failure(message):
            let line = message == MermaidRenderer.timeoutMessage
                ? L10n.shared["mermaid.timeout"]
                : L10n.shared.t("mermaid.error", message)
            return source(code, error: line)
        case nil:
            renderer.request(code: code, style: style)
            return source(code, error: nil)
        }
    }

    /// The diagram source as a code block picture, column wide, with an optional red
    /// error line. Colors resolve when drawn, so they follow the view's appearance.
    @MainActor
    private func source(_ code: String, error: String?) -> LatexRenderResult {
        let inset: CGFloat = 12
        let width = column.width
        let codeFont = highlighter.codeFont(size: max(1, bodySize - 1))
        let errorFont = NSFont.systemFont(ofSize: max(1, bodySize - 3))
        let wrap = NSMutableParagraphStyle()
        wrap.lineBreakMode = .byCharWrapping
        let codeText = NSAttributedString(string: code.isEmpty ? " " : code, attributes: [
            .font: codeFont, .foregroundColor: NSColor.textColor, .paragraphStyle: wrap,
        ])
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        let errorText = error.map { NSAttributedString(string: $0, attributes: [
            .font: errorFont, .foregroundColor: NSColor.systemRed, .paragraphStyle: truncate,
        ]) }
        let textWidth = max(1, width - 2 * inset)
        let codeHeight = ceil(codeText.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
        ).height)
        let bandHeight = codeHeight + 2 * 8
        let errorHeight = errorText.map { ceil($0.size().height) + 4 } ?? 0
        let size = CGSize(width: width, height: bandHeight + errorHeight)
        let background = highlighter.backgroundColor()
        let image = NSImage(size: size, flipped: true) { _ in
            background.setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: bandHeight), xRadius: 6, yRadius: 6).fill()
            codeText.draw(with: CGRect(x: inset, y: 8, width: textWidth, height: codeHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            errorText?.draw(with: CGRect(x: 2, y: bandHeight + 4, width: width - 4, height: errorHeight),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        return LatexRenderResult(image: image, size: size, baselineOffset: 0)
    }
}

// MARK: - Export

extension MermaidRenderer {
    /// Renders the note's diagrams for paper (light theme) before an export lays it out,
    /// waiting at most `limit` in all; any diagram still pending then exports as source.
    func prepare(for content: String, within limit: Duration = .seconds(10)) async {
        let codes = MermaidText.blocks(in: content).filter { $0.closeLineEnd != nil }.map(\.code)
        await prepare(codes, style: .current(lightOnly: true), within: limit)
    }
}
