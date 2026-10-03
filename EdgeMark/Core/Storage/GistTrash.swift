import Foundation

/// Foundation-only rules for trashing items that live in gist clones (`Gists/<name>`),
/// shared by the app and the SPM test target. GitHub has no empty gists, so trashing the
/// last file of a gist, or the clone folder itself, is a question about the whole gist.
/// Note identity is generic so tests can use plain strings.
nonisolated enum GistTrash {
    /// One note of a trash request: its folder (relative to the notes root) and file name.
    struct Item<ID: Hashable>: Equatable {
        let id: ID
        let folder: String
        let file: String
    }

    struct Plan<ID: Hashable>: Equatable {
        /// Clone folders (`Gists/<name>`) to ask about, sorted. Their notes and folders are
        /// left out of `notes` and `folders`.
        var gists: [String]
        /// Notes trashed the usual way, in request order. A gist file whose gist keeps
        /// other files is one of them: removing it is a deletion inside the gist.
        var notes: [ID]
        /// Folders trashed the usual way, in request order.
        var folders: [String]
    }

    /// `Gists/<name>` for a folder that is a gist clone or lies inside one, else nil.
    static func gistFolder(of folder: String) -> String? {
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "Gists", !parts[1].isEmpty else { return nil }
        return "Gists/\(parts[1])"
    }

    /// Splits a trash request. `gists` are the clone folders that are known gists; any
    /// other folder is trashed like a plain folder. A gist is asked about when a requested
    /// folder is its clone folder or `Gists` itself, or when the requested notes directly
    /// in its clone folder cover every file `files` lists for it (the files on disk, so a
    /// file EdgeMark does not show still counts). `Gists` is dropped from `folders` when
    /// it holds a gist that is asked about, since trashing it would take that gist along
    /// whatever the answer.
    static func plan<ID: Hashable>(
        notes: [Item<ID>],
        folders: [String],
        gists: Set<String>,
        files: (String) -> [String],
    ) -> Plan<ID> {
        var asked = Set<String>()
        for folder in folders {
            if folder == "Gists" {
                asked.formUnion(gists)
            } else if gists.contains(folder) {
                asked.insert(folder)
            }
        }
        let direct = Dictionary(grouping: notes.filter { gists.contains($0.folder) }, by: \.folder)
        for (gist, items) in direct where !asked.contains(gist) {
            if Set(files(gist)).isSubset(of: Set(items.map(\.file))) {
                asked.insert(gist)
            }
        }
        let inAsked = { (folder: String) in gistFolder(of: folder).map(asked.contains) ?? false }
        return Plan(
            gists: asked.sorted(),
            notes: notes.filter { !inAsked($0.folder) }.map(\.id),
            folders: folders.filter { $0 == "Gists" ? asked.isEmpty : !inAsked($0) },
        )
    }
}
