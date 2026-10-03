import Foundation

/// Which items the context menu on the empty space of a note list shows. Foundation-only
/// so the decision is unit tested; `NoteListMenus.backgroundMenu` turns it into an NSMenu.
nonisolated enum NoteListBackgroundMenu {
    enum Item: Equatable {
        case newNote
        case newFolder
        case sortBy
        case pasteAsNewNote
        case showInFinder
        case syncNow
        case trash
        case settings
    }

    /// The items in display order, grouped; the menu puts a separator between groups.
    /// `folder` is the folder being viewed ("" at home). A gist clone (`Gists/...`) cannot
    /// hold directories, so it gets no "New Folder". "Paste as New Note" needs pasteboard
    /// text that is not just whitespace.
    static func groups(folder: String, syncActive: Bool, pasteboardText: String?) -> [[Item]] {
        var create: [Item] = [.newNote]
        if !folder.hasPrefix("Gists/") {
            create.append(.newFolder)
        }
        var arrange: [Item] = [.sortBy]
        if let text = pasteboardText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arrange.append(.pasteAsNewNote)
        }
        var app: [Item] = [.showInFinder]
        if syncActive {
            app.append(.syncNow)
        }
        app += [.trash, .settings]
        return [create, arrange, app]
    }
}
