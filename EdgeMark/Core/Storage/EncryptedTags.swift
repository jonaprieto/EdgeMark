import Foundation

/// Tags of an encrypted note travel inside the ciphertext, as one line in front of the
/// text, so the plaintext sidecar (which is pushed to GitHub) never names them.
/// Foundation only, so the rules are unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum EncryptedTags {
    private static let prefix = "<!-- edgemark-tags: "
    private static let suffix = " -->"

    /// `text` with the tag line in front; `text` unchanged when `tags` is empty, except
    /// that a text which itself starts with a tag-shaped line gets an empty tag line in
    /// front, so reading it back does not mistake that line for the note's tags.
    static func embed(_ tags: [String], in text: String) -> String {
        if tags.isEmpty {
            return split(text) == nil ? text : prefix + suffix + "\n" + text
        }
        return prefix + tags.joined(separator: ", ") + suffix + "\n" + text
    }

    /// The tags of a leading tag line and the text without it; no tags and `text`
    /// unchanged when there is no such line.
    static func extract(from payload: String) -> (tags: [String], text: String) {
        split(payload) ?? ([], payload)
    }

    /// The leading tag line, if the first line has exactly the shape `embed` writes, an
    /// LF or CRLF included.
    private static func split(_ payload: String) -> (tags: [String], text: String)? {
        guard let newline = payload.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) else { return nil }
        let line = payload[..<newline]
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count >= prefix.count + suffix.count else { return nil }
        let body = line.dropFirst(prefix.count).dropLast(suffix.count)
        let tags = body.isEmpty ? [] : body.components(separatedBy: ", ")
        return (tags, String(payload[payload.index(after: newline)...]))
    }
}
