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
