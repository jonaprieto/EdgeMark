import Foundation

/// Pure text rules for note files: front matter detection and the first line used as a
/// title. Foundation only, so the rules are unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum NoteText {
    // MARK: - Front Matter

    /// A leading block that opens with a `---` line and closes at the next `---` line.
    /// `metadata` holds every `key: value` line inside it; `body` is the text after the
    /// closing line, with one leading newline dropped. Nil when there is no closed block.
    /// Lines are split on any newline, so CRLF files parse too.
    static func frontMatter(_ text: String) -> (metadata: [String: String], body: String)? {
        scanFrontMatter(text).map { ($0.metadata, $0.body) }
    }

    /// `frontMatter` plus whether the block reads as YAML: every non-blank line inside is a
    /// key, a list item, a comment or indented, rather than a horizontal rule and prose.
    private static func scanFrontMatter(_ text: String) -> (metadata: [String: String], body: String, isYAML: Bool)? {
        guard text.hasPrefix("---") else { return nil }
        var metadata: [String: String] = [:]
        var isYAML = true
        var lineStart = text.startIndex
        var isFirstLine = true
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if isFirstLine {
                guard line == "---", lineEnd < text.endIndex else { return nil }
                isFirstLine = false
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" {
                    var body = text[next...]
                    if body.first?.isNewline == true {
                        body = body.dropFirst()
                    }
                    return (metadata, String(body), isYAML)
                }
                if let colon = trimmed.firstIndex(of: ":") {
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        metadata[key] = value
                    }
                } else if !(trimmed.isEmpty || line.first == " " || line.first == "\t"
                    || line.first == "#" || line.hasPrefix("- "))
                {
                    isYAML = false
                }
            }
            lineStart = next
        }
        return nil
    }

    /// The metadata block EdgeMark itself wrote before the sidecar existed
    /// (`FileStorage.serializeFrontMatter`): a front matter block whose `id:` is a UUID.
    /// Any other leading `---` block (user YAML, a horizontal rule) is note content.
    static func legacyFrontMatter(_ text: String) -> (metadata: [String: String], body: String)? {
        guard let parsed = frontMatter(text),
              let id = parsed.metadata["id"],
              UUID(uuidString: id) != nil
        else { return nil }
        return parsed
    }

    /// `text` without EdgeMark's legacy metadata block, or `text` unchanged.
    static func strippingLegacyFrontMatter(_ text: String) -> String {
        legacyFrontMatter(text)?.body ?? text
    }

    // MARK: - Front Matter Display

    /// Invisible mark (WORD JOINER) the editor puts in front of the delimiter lines of a
    /// leading YAML block, so the engine sees a fenced block instead of two horizontal
    /// rules. It is display-only: `frontMatterFromDisplay` removes it before saving.
    static let frontMatterMark: Character = "\u{2060}"

    /// Start of the closing `---` or `...` line of a leading YAML front matter block (its
    /// opening `---` is always the first line of `text`). Nil unless the
    /// block opens on the very first line, closes, holds at least one `key:` line, and every
    /// other line inside is YAML-like (list item, comment, indented line or blank), so a
    /// horizontal rule followed by prose stays a rule. Nil when `text` already holds the
    /// mark, which keeps the display round trip exact.
    static func frontMatterCloseLine(_ text: String) -> String.Index? {
        guard text.hasPrefix("---"), !text.contains(frontMatterMark) else { return nil }
        var lineStart = text.startIndex
        var isFirstLine = true
        var hasKey = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            var trimmed = line
            while let last = trimmed.last, last == " " || last == "\t" {
                trimmed = trimmed.dropLast()
            }
            if isFirstLine {
                guard trimmed == "---", lineEnd < text.endIndex else { return nil }
                isFirstLine = false
            } else if trimmed == "---" || trimmed == "..." {
                return hasKey ? lineStart : nil
            } else if isYAMLKeyLine(trimmed) {
                hasKey = true
            } else if !(trimmed.isEmpty || line.first == " " || line.first == "\t"
                || trimmed.hasPrefix("#") || trimmed == "-" || trimmed.hasPrefix("- "))
            {
                return nil
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return nil
    }

    /// `key:` alone or `key: value`, with a plain key (letters, digits, `_`, `-`, `.`) or a
    /// quoted one. A key with spaces reads as prose ("Note that: ..."), not YAML.
    private static func isYAMLKeyLine(_ line: Substring) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" else { return false }
        let key = line[..<colon]
        guard let first = key.first else { return false }
        if first == "\"" || first == "'" {
            return key.count >= 2 && key.last == first
        }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// `text` with `frontMatterMark` in front of both delimiter lines of its leading front
    /// matter block, or nil when it has none (see `frontMatterCloseLine`).
    static func frontMatterToDisplay(_ text: String) -> String? {
        guard let close = frontMatterCloseLine(text) else { return nil }
        var result = text
        result.insert(frontMatterMark, at: close)
        result.insert(frontMatterMark, at: result.startIndex)
        return result
    }

    /// Inverse of `frontMatterToDisplay`: `text` without any `frontMatterMark`. Only applied
    /// to text that `frontMatterToDisplay` converted, whose source held no mark, so the
    /// result is byte for byte what the user typed even after edits around the delimiters.
    static func frontMatterFromDisplay(_ text: String) -> String {
        guard text.contains(frontMatterMark) else { return text }
        var result = text
        result.removeAll { $0 == frontMatterMark }
        return result
    }

    // MARK: - Title

    /// The first line of `text`, ended by any newline ("\n", "\r\n", "\r", U+2028...).
    static func firstLine<S: StringProtocol>(_ text: S) -> S.SubSequence {
        let end = text.firstIndex(where: \.isNewline) ?? text.endIndex
        return text[..<end]
    }

    /// Title shown for a note: the first line without leading `#` and spaces, or "Untitled".
    /// A leading YAML block is skipped: its `title:` key wins, otherwise the first body line.
    static func title(from content: String) -> String {
        var source = Substring(content)
        if let block = scanFrontMatter(content), block.isYAML {
            if let title = block.metadata["title"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
               !title.isEmpty
            {
                return title
            }
            source = block.body[...]
        }
        let line = firstLine(source)
        let stripped = line.drop { $0 == "#" || $0 == " " }
        return stripped.isEmpty ? "Untitled" : String(stripped)
    }

    /// Splits a note whose first line is a `#` heading into that line, the line breaks
    /// after it (any number, any style) and the rest, so the editor can hide the heading
    /// and `joinHeading` can put back exactly what was on disk. `heading` is empty when the
    /// first line is not a heading.
    static func splitHeading(_ content: String) -> (heading: String, separator: String, body: String) {
        let heading = firstLine(content)
        guard heading.hasPrefix("#") else { return ("", "", content) }
        let rest = content[heading.endIndex...]
        let bodyStart = rest.firstIndex { !$0.isNewline } ?? rest.endIndex
        return (String(heading), String(rest[..<bodyStart]), String(rest[bodyStart...]))
    }

    /// Inverse of `splitHeading`. A heading with no line break after it gets a blank line
    /// once there is a body, so typed text never runs into the heading.
    static func joinHeading(_ heading: String, separator: String, body: String) -> String {
        guard !heading.isEmpty else { return body }
        let separator = separator.isEmpty && !body.isEmpty ? "\n\n" : separator
        return heading + separator + body
    }

    // MARK: - Decoding

    /// Text of a note file that is not valid UTF-8: Windows-1252 (the usual source of such
    /// files), else ISO Latin-1, which maps every byte, so the note is never dropped.
    static func decodeLegacyEncoding(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Asset Folders

    /// Characters the editor's image link patterns cannot carry in a path: the engine ends
    /// a `![](...)` destination at an unbalanced `)` and an `![[...]]` embed at the first `]`.
    private static let unsafeAssetStemCharacters: Set<Character> = ["(", ")", "[", "]", "{", "}", "<", ">", "`"]

    /// Stem of a note's hidden image folder: the file name without ".md", with every
    /// character the link patterns cannot handle replaced by "-".
    static func safeAssetStem(_ stem: String) -> String {
        String(stem.map { unsafeAssetStemCharacters.contains($0) ? "-" : $0 })
    }

    /// For an image path `.STEM/name`, the same path under `safeAssetStem(STEM)`, or nil
    /// when the path has another shape or the stem is already safe. Lets a reference
    /// written before stems were made safe find an image that now lives in the safe folder.
    static func safeAssetPath(_ path: String) -> String? {
        guard path.hasPrefix("."), let slash = path.firstIndex(of: "/") else { return nil }
        let stem = String(path[path.index(after: path.startIndex) ..< slash])
        let safe = safeAssetStem(stem)
        guard safe != stem else { return nil }
        return "." + safe + path[slash...]
    }
}
