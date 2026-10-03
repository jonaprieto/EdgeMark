import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - Metrics

/// Code-block geometry shared by the engine config and the overlay, so the gutter
/// lines up with the rows the engine actually lays out.
struct CodeBlockMetrics {
    /// Left/right indent of code text inside the block. Wider than the engine's 12 pt
    /// default to leave room for the line-number gutter on the left.
    static let textIndent: CGFloat = 36
    /// Spacing before and after each code line (engine default 2, halved for density).
    static let paragraphSpacing: CGFloat = 1
    /// Gap between the right edge of the line numbers and the code text.
    static let gutterGap: CGFloat = 8

    let font: NSFont
    let rowHeight: CGFloat
    let advance: CGFloat

    /// Code font one point smaller than the body font, as a scale for the engine.
    static func fontSizeScale(bodySize: CGFloat) -> CGFloat {
        bodySize > 1 ? (bodySize - 1) / bodySize : 1
    }

    /// Mirrors MarkdownASTStyler: code size = round(body * scale), and the row height
    /// is pinned to ceil(ascender - descender + leading) of the highlighter's code font.
    init(configuration: MarkdownEditorConfiguration, bodySize: CGFloat) {
        let size = round(bodySize * configuration.codeBlock.fontSizeScale)
        font = configuration.services.syntaxHighlighter.codeFont(size: size)
        rowHeight = ceil(font.ascender - font.descender + font.leading)
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// Characters per visual row for a block of the given width (char-wrapped, mono).
    func columns(blockWidth: CGFloat) -> Int {
        guard advance > 0 else { return 0 }
        return Int(((blockWidth - 2 * Self.textIndent) / advance).rounded(.down))
    }
}

// MARK: - Model

/// Visible code blocks plus hover/copy state. A reference type so the engine callback
/// and the hover handler only invalidate the overlay layer, never the editor view
/// that owns the text view (re-rendering that would re-run updateNSView, which
/// re-posts the code-block callback).
@Observable
final class CodeBlockOverlayModel {
    private(set) var blocks: [CodeBlockSelection] = []
    private(set) var hoveredID: Int?
    private(set) var copiedID: Int?

    func update(_ new: [CodeBlockSelection]) {
        let same = new.count == blocks.count && zip(new, blocks).allSatisfy {
            $0.id == $1.id && $0.rect == $1.rect && $0.code == $1.code
        }
        if !same { blocks = new }
    }

    func hover(at point: CGPoint?) {
        let id = point.flatMap { p in blocks.first { $0.rect.contains(p) }?.id }
        if id != hoveredID { hoveredID = id }
    }

    func copy(_ block: CodeBlockSelection, transform: (String) -> String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transform(CodeBlockGutter.copyText(block.code)), forType: .string)
        copiedID = block.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == block.id { self?.copiedID = nil }
        }
    }
}

// MARK: - Modifier

extension View {
    /// Overlays line numbers and a hover copy button on the code blocks reported by
    /// NativeTextViewWrapper's `onCodeBlockSelectionChange`. The engine skips the
    /// block holding the caret, so that block shows neither while it is edited.
    /// `transformCopy` maps the display-layer code to what is copied.
    func codeBlockChrome(
        _ model: CodeBlockOverlayModel,
        metrics: CodeBlockMetrics,
        transformCopy: @escaping (String) -> String = { $0 },
    ) -> some View {
        overlay(alignment: .topLeading) {
            CodeBlockOverlayLayer(model: model, metrics: metrics, transformCopy: transformCopy)
        }
        // On the composite (not the text view alone) so moving onto the button does
        // not end the hover and hide the button under the pointer.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point): model.hover(at: point)
            case .ended: model.hover(at: nil)
            }
        }
    }
}

// MARK: - Overlay layer

private struct CodeBlockOverlayLayer: View {
    let model: CodeBlockOverlayModel
    let metrics: CodeBlockMetrics
    let transformCopy: (String) -> String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(model.blocks) { block in
                    gutter(for: block, viewportHeight: geo.size.height)
                    copyButton(for: block)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipped()
    }

    @ViewBuilder
    private func gutter(for block: CodeBlockSelection, viewportHeight: CGFloat) -> some View {
        let lines = CodeBlockGutter.lines(block.code)
        if let offsets = CodeBlockGutter.lineOffsets(
            lineLengths: lines.map(\.count),
            columns: metrics.columns(blockWidth: block.rect.width),
            blockHeight: block.rect.height,
            rowHeight: metrics.rowHeight,
            paragraphSpacing: CodeBlockMetrics.paragraphSpacing,
        ) {
            let width = CodeBlockMetrics.textIndent - CodeBlockMetrics.gutterGap
            // Only the numbers inside the viewport; a long block would otherwise build
            // one Text per line on every scroll tick.
            let visible = offsets.indices.filter {
                let y = block.rect.minY + offsets[$0]
                return y > -metrics.rowHeight && y < viewportHeight
            }
            ForEach(visible, id: \.self) { index in
                Text(verbatim: "\(index + 1)")
                    .font(Font(metrics.font as CTFont))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: width, height: metrics.rowHeight, alignment: .trailing)
                    .offset(x: block.rect.minX, y: block.rect.minY + offsets[index])
            }
            .allowsHitTesting(false)
        }
    }

    private func copyButton(for block: CodeBlockSelection) -> some View {
        let copied = model.copiedID == block.id
        let visible = copied || model.hoveredID == block.id
        let size = CGSize(width: 22, height: 20)
        return Button {
            model.copy(block, transform: transformCopy)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.shared["editor.copyCode"])
        .accessibilityLabel(L10n.shared["editor.copyCode"])
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.12), value: visible)
        // Top-right corner, inside the (hidden) opening-fence row so it never covers code.
        .offset(x: block.rect.maxX - size.width - 6, y: block.rect.minY + 3)
    }
}
