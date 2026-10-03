import AppKit
import Foundation

/// Trash requests that touch gist clones. Trashing the last file of a gist, or a gist's
/// folder, asks once whether to delete the gist on GitHub too (see `GistTrash`); every
/// other item goes to EdgeMark's Trash as before.
extension NoteStore {
    /// The user's answer to the gist question.
    enum GistTrashAnswer {
        case cancel
        case deleteOnGitHub
        case removeHere
    }

    /// Moves `notes` and `folders` to the Trash. When a gist would be left without files,
    /// asks first (one alert for all of them); Cancel leaves every requested item in place.
    /// When no gist is involved and `ifNoGist` is set, it runs instead of trashing, so the
    /// caller can show its usual confirmation. `completion` runs once the items were
    /// handled, not on Cancel.
    func trashItems(
        notes requested: [Note],
        folders: [String],
        ifNoGist: (() -> Void)? = nil,
        completion: (() -> Void)? = nil,
    ) {
        let first = gistTrashPlan(requested, folders, gists: Self.gistCloneFolders())
        guard !first.gists.isEmpty else {
            if let ifNoGist { return ifNoGist() }
            trashPlanned(first)
            completion?()
            return
        }
        Task {
            if await confirmGistTrash(requested, folders, candidates: first.gists, ifNoGist: ifNoGist) {
                completion?()
            }
        }
    }

    /// Resolves the candidate gists, asks, and applies the answer. False on Cancel or
    /// when `ifNoGist` took over.
    private func confirmGistTrash(
        _ requested: [Note],
        _ folders: [String],
        candidates: [String],
        ifNoGist: (() -> Void)?,
    ) async -> Bool {
        let sync = GitSync.shared
        var clones: [String: GitSync.GistClone] = [:]
        for folder in candidates {
            if let clone = await sync.gistClone(at: FileStorage.urlForFolder(folder)) {
                clones[folder] = clone
            }
        }
        // A folder that is not a synced gist (no gist origin, or deleted on GitHub) is
        // trashed like any other folder.
        let plan = gistTrashPlan(requested, folders, gists: Set(clones.keys))
        guard !plan.gists.isEmpty else {
            if let ifNoGist {
                ifNoGist()
                return false
            }
            trashPlanned(plan)
            return true
        }
        var lines: [String] = []
        var descriptions: [String: String] = [:]
        for folder in plan.gists {
            guard let clone = clones[folder] else { continue }
            let details = await sync.gistDetails(clone)
            let description = details?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = description.isEmpty ? (folder as NSString).lastPathComponent : description
            descriptions[folder] = name
            let visibility = details.map { L10n.shared[$0.isPublic ? "gistTrash.public" : "gistTrash.secret"] }
            lines.append(visibility.map { "\(name) (\($0))" } ?? name)
        }
        let l10n = L10n.shared
        switch Self.askAboutGists(lines) {
        case .cancel:
            return false
        case .removeHere:
            var failure: String?
            for folder in plan.gists {
                guard let clone = clones[folder] else { continue }
                if let error = await sync.hideGist(clone, description: descriptions[folder]) {
                    failure = failure ?? error.message
                } else {
                    forgetFolder(folder)
                }
            }
            trashPlanned(plan)
            if let failure {
                FeedbackToast.shared.show(l10n.t("gistTrash.hideFailed", Self.shortMessage(failure)), isError: true)
            }
            return true
        case .deleteOnGitHub:
            var deleted = 0
            var failure: String?
            for folder in plan.gists {
                guard let clone = clones[folder] else { continue }
                switch await sync.deleteGist(clone) {
                case .success:
                    forgetFolder(folder)
                    deleted += 1
                case let .failure(error):
                    failure = failure ?? error.message
                }
            }
            trashPlanned(plan)
            if let failure {
                FeedbackToast.shared.show(l10n.t("gistTrash.failed", Self.shortMessage(failure)), isError: true)
            } else {
                FeedbackToast.shared.show(deleted == 1 ? l10n["gistTrash.deleted"] : l10n.t("gistTrash.deletedMany", "\(deleted)"))
            }
            return true
        }
    }

    /// One alert for every gist in `lines` (name, plus visibility when known). Cancel is
    /// the default button; the destructive one is never chosen by Return. "Only Remove
    /// Here" hides the gist on this Mac and leaves it on GitHub.
    private static func askAboutGists(_ lines: [String]) -> GistTrashAnswer {
        let l10n = L10n.shared
        let one = lines.count == 1
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n[one ? "gistTrash.title" : "gistTrash.titleMany"]
        alert.informativeText = lines.joined(separator: "\n") + "\n\n"
            + l10n[one ? "gistTrash.info" : "gistTrash.infoMany"] + " " + l10n[one ? "gistTrash.onlyHereInfo" : "gistTrash.onlyHereInfoMany"]
        alert.addButton(withTitle: l10n["common.cancel"])
        let delete = alert.addButton(withTitle: l10n["gistTrash.delete"])
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: l10n["gistTrash.onlyHere"])
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .deleteOnGitHub
        case .alertThirdButtonReturn: return .removeHere
        default: return .cancel
        }
    }

    /// Trashes the plan's plain notes and folders, resolved against the live lists.
    private func trashPlanned(_ plan: GistTrash.Plan<UUID>) {
        for id in plan.notes {
            if let note = notes.first(where: { $0.id == id }) {
                trashNote(note)
            }
        }
        for path in plan.folders where self.folders.contains(where: { $0.name == path }) {
            trashFolder(path)
        }
    }

    private func gistTrashPlan(_ requested: [Note], _ folders: [String], gists: Set<String>) -> GistTrash.Plan<UUID> {
        GistTrash.plan(
            notes: requested.map { GistTrash.Item(id: $0.id, folder: $0.folder, file: $0.savedFilename ?? $0.filename) },
            folders: folders,
            gists: gists,
            files: Self.filesOnDisk(in:),
        )
    }

    /// `Gists/<name>` for every git clone under `Gists/`.
    private static func gistCloneFolders() -> Set<String> {
        let dir = FileStorage.urlForFolder("Gists")
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return Set(children.filter { GitRepo(url: $0).isRepo }.map { "Gists/\($0.lastPathComponent)" })
    }

    /// Names of the regular files directly in `folder` (hidden files and folders skipped).
    private static func filesOnDisk(in folder: String) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: FileStorage.urlForFolder(folder), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent)
    }

    /// First line of `message`, cut to 120 characters, for the toast.
    private static func shortMessage(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 120 ? String(line.prefix(117)) + "..." : line
    }
}
