import Foundation

/// File naming for encrypted notes: the plain file name plus `.age`. Foundation only, so
/// the rules are unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum EncryptedFileName {
    static let suffix = ".age"

    /// True for `<name>.age`.
    static func isEncrypted(_ fileName: String) -> Bool {
        fileName.count > suffix.count && fileName.hasSuffix(suffix)
    }

    /// `fileName` without a trailing `.age`.
    static func plainName(_ fileName: String) -> String {
        isEncrypted(fileName) ? String(fileName.dropLast(suffix.count)) : fileName
    }

    /// True for an encrypted Markdown note, `<name>.md.age`.
    static func isEncryptedMarkdown(_ fileName: String) -> Bool {
        isEncrypted(fileName) && (plainName(fileName) as NSString).pathExtension == "md"
    }

    /// The name without `.age` and without the extension under it: `Title.md.age` and
    /// `Title.md` both give `Title`. Asset folders are named after this stem.
    static func stem(_ fileName: String) -> String {
        (plainName(fileName) as NSString).deletingPathExtension
    }

    /// Title shown for a locked note outside gists, taken from its file name because the
    /// text is not readable. A trashed file is named `<UUID>_<Title>.md.age`; the id goes.
    static func lockedTitle(fileName: String, inTrash: Bool) -> String {
        let name = stem(fileName)
        guard inTrash, name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil,
              name[name.index(name.startIndex, offsetBy: 36)] == "_" else { return name }
        return String(name.dropFirst(37))
    }
}
