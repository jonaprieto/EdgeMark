import Foundation

/// Rules for the files of a gist clone that EdgeMark shows besides `.md` notes: any small
/// UTF-8 text file (code, JSON, plain text). They open in the plain-text editor and are
/// saved back unchanged apart from the user's edits. Foundation only, so the rules are
/// unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum GistTextFile {
    /// Larger files are left out of the list.
    static let maxBytes = 1024 * 1024

    /// Extensions known to be text: a UTF-8 file with one of them is listed even when it
    /// holds unusual control characters (an escape sequence in a log, say).
    static let textExtensions: Set<String> = [
        "agda", "lagda", "lean", "ex", "exs", "heex", "sol", "rs", "py", "json", "txt", "text",
        "swift", "sh", "bash", "zsh", "fish", "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h",
        "cpp", "cc", "cxx", "hpp", "hh", "go", "hs", "lhs", "ml", "mli", "nix", "yaml", "yml",
        "toml", "html", "htm", "css", "scss", "xml", "svg", "csv", "tsv", "sql", "rb", "java",
        "kt", "kts", "scala", "clj", "el", "lisp", "scm", "rkt", "lua", "pl", "r", "jl", "dart",
        "zig", "v", "idr", "elm", "erl", "hrl", "fs", "fsx", "cs", "php", "tex", "bib", "org",
        "rst", "adoc", "ini", "cfg", "conf", "env", "diff", "patch", "log", "graphql", "proto",
        "vim", "markdown", "ipynb",
    ]

    /// Extensions that are never shown, whatever their bytes look like.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns", "pdf", "zip",
        "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "pkg", "exe", "dll", "so", "dylib",
        "o", "a", "class", "jar", "wasm", "mp3", "mp4", "mov", "m4a", "wav", "ogg", "flac",
        "ttf", "otf", "woff", "woff2", "sqlite", "db", "bin",
    ]

    /// Whether a gist file named `name` with these bytes is listed as an editable note.
    /// `.md` files are notes anyway and are not judged here. Dot-files, known binary
    /// extensions, files over `maxBytes`, bytes with a NUL and bytes that are not valid
    /// UTF-8 are left out. A file whose extension is not in `textExtensions` (`LICENSE`,
    /// `Makefile`, anything unknown) must also be free of control characters other than
    /// tab, line feed, form feed and carriage return.
    static func isEditableText(name: String, data: Data) -> Bool {
        guard isCandidate(name: name, size: data.count), !data.contains(0),
              String(data: data, encoding: .utf8) != nil else { return false }
        if textExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return true
        }
        return !data.contains { $0 == 0x7F || ($0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains($0)) }
    }

    /// The checks that need no bytes: name and size. Lets a caller skip reading a file.
    static func isCandidate(name: String, size: Int) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), size <= maxBytes else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext != "md" && !binaryExtensions.contains(ext)
    }

    /// UTF-8 text of `data` with a leading byte order mark kept as U+FEFF (Foundation drops
    /// it), so writing `text.utf8` back gives the same bytes. Nil when not UTF-8.
    static func decode(_ data: Data) -> String? {
        let bom = Data([0xEF, 0xBB, 0xBF])
        guard data.starts(with: bom) else { return String(data: data, encoding: .utf8) }
        return String(data: data.dropFirst(bom.count), encoding: .utf8).map { "\u{FEFF}" + $0 }
    }

    /// Reads `url` and applies `isEditableText`; false when the file cannot be read.
    static func isEditableText(at url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard isCandidate(name: url.lastPathComponent, size: size),
              let data = try? Data(contentsOf: url) else { return false }
        return isEditableText(name: url.lastPathComponent, data: data)
    }

    /// File name for a rename of a gist file to `typed`, keeping the old file's extension
    /// `ext` (appended unless `typed` already ends with it; empty for a file without one).
    /// Nil when the result is not a valid single file name: empty, a dot-file, containing
    /// `/`, `:` or a control character, or longer than 255 UTF-8 bytes.
    static func renamedFileName(typed: String, keepingExtension ext: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
              !trimmed.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        var name = trimmed
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += "." + ext
        }
        guard name.utf8.count <= 255, (name as NSString).deletingPathExtension != "" else { return nil }
        return name
    }
}
