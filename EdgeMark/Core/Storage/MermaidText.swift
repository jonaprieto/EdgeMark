import CryptoKit
import Foundation

/// Pure text rules for Mermaid diagrams: finding ```` ```mermaid ```` fences, the render
/// cache key, and the editor's display round trip. No AppKit or WebKit, so the rules are
/// unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum MermaidText {
    // MARK: - Fences

    /// A fenced code block whose info string starts with `mermaid` (any case).
    struct Block: Equatable {
        /// The diagram source: the lines between the fences, without line breaks at the
        /// ends and with up to the opening fence's indentation removed from each line.
        let code: String
        /// Start of the opening fence line.
        let openLineStart: String.Index
        /// End of the closing fence line, before its line break; nil when the fence is
        /// never closed (the block then runs to the end of the text).
        let closeLineEnd: String.Index?
        /// The fence character, "`" or "~", and the length of the opening run.
        let fence: Character
        let openLength: Int
        /// The run of fence characters on the closing line; nil when unclosed.
        let closeRun: Range<String.Index>?
    }

    private struct Fence {
        let character: Character
        let length: Int
        let indent: Int
        let isMermaid: Bool
    }

    /// Every Mermaid block in `text`, in order. Follows CommonMark fences: three or more
    /// backticks or tildes after at most three spaces, closed by a run of the same
    /// character at least as long. Mermaid-looking fences inside another fenced block are
    /// code of that block, not diagrams.
    static func blocks(in text: String) -> [Block] {
        let lines = lineRanges(text)
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            guard let fence = openingFence(text[lines[i].start ..< lines[i].end]) else {
                i += 1
                continue
            }
            var close: Int?
            var j = i + 1
            while j < lines.count {
                if isClosingFence(text[lines[j].start ..< lines[j].end], for: fence) {
                    close = j
                    break
                }
                j += 1
            }
            if fence.isMermaid {
                let content = lines[(i + 1) ..< (close ?? lines.count)]
                let code = content
                    .map { stripIndent(text[$0.start ..< $0.end], upTo: fence.indent) }
                    .joined(separator: "\n")
                let closeRun = close.map { j -> Range<String.Index> in
                    let line = text[lines[j].start ..< lines[j].end]
                    let scalars = line.unicodeScalars
                    let start = scalars.index(scalars.startIndex, offsetBy: leadingSpaces(line))
                    let end = scalars[start...].firstIndex { Character($0) != fence.character } ?? scalars.endIndex
                    return start ..< end
                }
                blocks.append(Block(
                    code: code,
                    openLineStart: lines[i].start,
                    closeLineEnd: close.map { lines[$0].end },
                    fence: fence.character,
                    openLength: fence.length,
                    closeRun: closeRun,
                ))
            }
            i = (close ?? lines.count) + 1
        }
        return blocks
    }

    /// Each line as (start, end before the line break, start of the next line). Splits on
    /// "\n" only; a "\r" before it belongs to the break, so CRLF files parse too.
    private static func lineRanges(_ text: String) -> [(start: String.Index, end: String.Index)] {
        var lines: [(start: String.Index, end: String.Index)] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var index = start
        var previous: String.Index?
        while index < scalars.endIndex {
            if scalars[index] == "\n" {
                let end = previous.flatMap { scalars[$0] == "\r" ? $0 : nil } ?? index
                lines.append((start, end))
                start = scalars.index(after: index)
                previous = nil
                index = start
                continue
            }
            previous = index
            index = scalars.index(after: index)
        }
        if start < scalars.endIndex {
            lines.append((start, scalars.endIndex))
        }
        return lines
    }

    private static func leadingSpaces(_ line: Substring) -> Int {
        line.unicodeScalars.prefix { $0 == " " }.count
    }

    private static func openingFence(_ line: Substring) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.unicodeScalars.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = String(String.UnicodeScalarView(rest.dropFirst(length)))
            .trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not hold a backtick (that is inline code).
        if first == "`", info.contains("`") {
            return nil
        }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        return Fence(
            character: Character(first),
            length: length,
            indent: indent,
            isMermaid: language.lowercased() == "mermaid",
        )
    }

    private static func isClosingFence(_ line: Substring, for fence: Fence) -> Bool {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return false }
        let rest = line.unicodeScalars.dropFirst(indent)
        let length = rest.prefix { Character($0) == fence.character }.count
        guard length >= fence.length else { return false }
        return rest.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func stripIndent(_ line: Substring, upTo indent: Int) -> Substring {
        line.dropFirst(min(indent, leadingSpaces(line)))
    }

    // MARK: - Cache Key

    /// Hex SHA-256 of everything that changes the picture: the Mermaid version, the theme,
    /// the font and the diagram source. NUL-separated, so no two inputs share a key.
    static func cacheKey(code: String, theme: String, fontFamily: String, version: String) -> String {
        let input = [version, theme, fontFamily, code].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Editor Display

    /// Blank anchor (BRAILLE PATTERN BLANK) the editor puts after the `$$` that opens a
    /// wrapped Mermaid block, so the engine treats the block like a display formula:
    /// rendered as a picture while the caret is outside, source while it is inside. The
    /// engine plants the picture on the first character of the formula, and it must take up
    /// space (an invisible format character gets no glyph and the picture lands off-center),
    /// so this is a blank that has a width. It also tells the formula renderer the block is
    /// Mermaid. Display-only, like `mark`: `fromDisplay` removes both before saving.
    static let openMark: Character = "\u{2800}"

    /// Invisible mark (INVISIBLE SEPARATOR) before the `$$` that closes a wrapped block,
    /// and inside a closing backtick run (see `toDisplay`).
    static let mark: Character = "\u{2063}"

    /// `text` with every closed Mermaid block wrapped for display, or nil when there is
    /// nothing to wrap. A block becomes (`⠀` the open mark, `⁣` the invisible mark)
    ///
    ///     $$⠀
    ///     ```mermaid
    ///     …
    ///     `⁣``⁣$$
    ///
    /// The `$$` opens on a line of its own, so the picture anchors on the open mark and not
    /// on the fence line. The mark splits the closing backtick run (1 + rest), so the
    /// engine's inline parser does not pair the two fences into a code span, which would
    /// stop the formula from rendering.
    ///
    /// Left alone, as plain code blocks: a block holding `$$` (the engine would end the
    /// formula there), a backtick block holding a backtick (a code span inside would stop
    /// the formula too), and one whose closing run is one longer than its opening run (the
    /// split would leave a run matching the opening). A text that already holds either
    /// mark is not converted at all, which keeps the round trip exact.
    static func toDisplay(_ text: String) -> String? {
        guard !text.contains(mark), !text.contains(openMark) else { return nil }
        let targets = blocks(in: text).filter { block in
            guard let end = block.closeLineEnd, let run = block.closeRun else { return false }
            if text[block.openLineStart ..< end].contains("$$") { return false }
            if block.fence == "`" {
                let closeLength = text[run].unicodeScalars.count
                return !block.code.contains("`") && closeLength - 1 != block.openLength
            }
            return true
        }
        guard !targets.isEmpty else { return nil }
        let m = String(mark)
        var result = ""
        var cursor = text.startIndex
        for block in targets {
            guard let end = block.closeLineEnd, let run = block.closeRun else { continue }
            result += text[cursor ..< block.openLineStart]
            result += "$$" + String(openMark) + "\n"
            if block.fence == "`" {
                let split = text.index(after: run.lowerBound)
                result += text[block.openLineStart ..< split]
                result += m
                result += text[split ..< end]
            } else {
                result += text[block.openLineStart ..< end]
            }
            result += m + "$$"
            cursor = end
        }
        result += text[cursor...]
        return result
    }

    /// Inverse of `toDisplay`: every mark removed, together with what it brought: the `$$`
    /// before an open mark and the line break after it, or the `$$` after a mark. A mark
    /// inside a fence run, or one whose neighbors were edited away, goes alone. Only
    /// applied to text that `toDisplay` converted, whose source held neither mark.
    static func fromDisplay(_ text: String) -> String {
        guard text.contains(mark) || text.contains(openMark) else { return text }
        let markScalar = mark.unicodeScalars.first!
        let openScalar = openMark.unicodeScalars.first!
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            i += 1
            if scalar == openScalar {
                if out.count >= 2, out[out.index(out.endIndex, offsetBy: -1)] == "$",
                   out[out.index(out.endIndex, offsetBy: -2)] == "$"
                {
                    out.removeLast(2)
                    if i < scalars.count, scalars[i] == "\n" {
                        i += 1
                    }
                }
            } else if scalar == markScalar {
                if i + 1 < scalars.count, scalars[i] == "$", scalars[i + 1] == "$" {
                    i += 2
                }
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The diagram source of a display-layer formula whose content (between its `$$`) is a
    /// marked Mermaid block, as the engine hands it to the formula renderer. Nil for any
    /// other content: a real formula, or a marked block whose fence is no longer `mermaid`.
    static func code(fromDisplayContent content: String) -> String? {
        guard content.first == openMark else { return nil }
        var text = content.filter { $0 != mark && $0 != openMark }
        // The line break after the open mark; the fence's own indentation stays.
        while let first = text.first, first.isNewline {
            text.removeFirst()
        }
        guard let block = blocks(in: text).first,
              block.openLineStart == text.startIndex,
              block.closeLineEnd != nil
        else { return nil }
        return block.code
    }
}
