import Foundation

// MARK: - CodeBlockGutter

/// Pure geometry and text helpers behind the code-block overlay (line numbers and
/// the copy button). Foundation-only so the logic can be checked without AppKit.
///
/// The engine (swift-markdown-engine 0.12) reports each visible fenced block as one
/// rect covering the open fence, the content lines, and the close fence, and draws
/// every one of those lines as its own paragraph with a fixed line height. It does not
/// report per-line rects, so the gutter rebuilds them from the font metrics and
/// validates the result against the block height (see `lineOffsets`).
enum CodeBlockGutter {
    /// The code exactly as written between the fences: the engine's content range
    /// ends with the newline before the closing fence, which is not part of the code.
    static func copyText(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }

    /// Lines of the block content, one per gutter number. Empty content has no lines.
    static func lines(_ code: String) -> [Substring] {
        let text = copyText(code)
        guard !text.isEmpty || code.hasSuffix("\n") else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Top offset of each content line, measured from the top of the block rect.
    ///
    /// - Parameters:
    ///   - lineLengths: character count of each content line.
    ///   - columns: characters that fit on one visual row (monospaced, char-wrapped).
    ///   - blockHeight: height of the rect the engine reported for the whole block.
    ///   - rowHeight: fixed height of one visual row (the engine pins min == max).
    ///   - paragraphSpacing: spacing the engine adds before and after each line.
    /// - Returns: `nil` when the predicted layout does not match `blockHeight` within
    ///   half a row (for example a line with tabs or wide characters wrapped
    ///   differently than predicted); the caller then hides the gutter for that block
    ///   rather than show misaligned numbers.
    static func lineOffsets(
        lineLengths: [Int],
        columns: Int,
        blockHeight: CGFloat,
        rowHeight: CGFloat,
        paragraphSpacing: CGFloat,
    ) -> [CGFloat]? {
        guard columns > 0, rowHeight > 0, !lineLengths.isEmpty else { return nil }
        let rows = lineLengths.map { max(1, Int((Double($0) / Double(columns)).rounded(.up))) }
        // Open fence + content lines + close fence, one row each for the fences.
        let paragraphs = CGFloat(lineLengths.count + 2)
        let rowsHeight = CGFloat(rows.reduce(2, +)) * rowHeight
        let predicted = rowsHeight + paragraphs * 2 * paragraphSpacing
        guard abs(predicted - blockHeight) <= rowHeight / 2 else { return nil }

        // Spread whatever spacing the layout really used evenly over the paragraphs,
        // so a point of difference at the block edges does not drift the numbers.
        let spacing = max(0, (blockHeight - rowsHeight) / paragraphs)
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(rows.count)
        var y = rowHeight + spacing + spacing / 2 // past the open fence paragraph
        for count in rows {
            offsets.append(y)
            y += CGFloat(count) * rowHeight + spacing
        }
        return offsets
    }
}
