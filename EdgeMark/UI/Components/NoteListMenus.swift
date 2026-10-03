import Carbon
import Cocoa
import OSLog
import SwiftUI

/// Shared NSMenu builders for note and folder context menus.
/// Uses NSMenu instead of SwiftUI `.contextMenu` so SF Symbol icons render reliably on macOS.
enum NoteListMenus {
    // MARK: - Background Context Menu

    /// Build an NSMenu shown when right-clicking the empty space of a note list.
    /// `folder` is the folder being viewed ("" at home); `onNewNote` and `onNewFolder`
    /// are the list's own creation paths so the inline rename flow runs as usual.
    static func backgroundMenu(
        folder: String,
        noteStore: NoteStore,
        settings: AppSettings,
        l10n: L10n,
        onNewNote: @escaping () -> Void,
        onNewFolder: @escaping () -> Void,
        onSettings: @escaping () -> Void,
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sync = GitSync.shared
        let pasteText = NSPasteboard.general.string(forType: .string)
        let groups = NoteListBackgroundMenu.groups(
            folder: folder,
            syncActive: sync.isActive,
            pasteboardText: pasteText,
        )

        for (index, group) in groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in group {
                switch item {
                case .newNote:
                    let menuItem = menu.addActionItem(title: l10n["common.newNote"], icon: "square.and.pencil", action: onNewNote)
                    showShortcut(ShortcutSettings.shared.newNoteShortcut, on: menuItem)
                case .newFolder:
                    let menuItem = menu.addActionItem(title: l10n["common.newFolder"], icon: "folder.badge.plus", action: onNewFolder)
                    showShortcut(ShortcutSettings.shared.newFolderShortcut, on: menuItem)
                case .sortBy:
                    let sortItem = NSMenuItem(title: l10n["sort.sortBy"], action: nil, keyEquivalent: "")
                    sortItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
                    sortItem.submenu = sortSubmenu(settings: settings, l10n: l10n)
                    menu.addItem(sortItem)
                case .pasteAsNewNote:
                    guard let pasteText else { continue }
                    menu.addActionItem(title: l10n["noteList.pasteAsNewNote"], icon: "doc.on.clipboard") {
                        let note = noteStore.createNote(withText: pasteText, in: folder)
                        noteStore.openNote(note)
                    }
                case .showInFinder:
                    menu.addActionItem(title: l10n["common.showInFinder"], icon: "folder") {
                        NSWorkspace.shared.open(FileStorage.urlForFolder(folder))
                    }
                case .syncNow:
                    menu.addActionItem(title: l10n["sync.syncNow"], icon: "arrow.triangle.2.circlepath") {
                        Task { await sync.syncNow() }
                    }.isEnabled = sync.state != .syncing
                case .trash:
                    menu.addActionItem(title: l10n["common.trash"], icon: "trash") {
                        noteStore.openTrash()
                    }
                case .settings:
                    menu.addActionItem(title: l10n["menu.settings"], icon: "gearshape", action: onSettings)
                }
            }
        }
        return menu
    }

    /// Sort field items (Name, Date Modified, Date Created) with the current one checked.
    /// Shared by the footer sort menu and the background menu's "Sort By" submenu.
    static func addSortFieldItems(to menu: NSMenu, settings: AppSettings, l10n: L10n) {
        let delegate = NSApp.delegate as? AppDelegate
        for option in AppSettings.SortBy.allCases {
            let action: Selector = switch option {
            case .name: #selector(AppDelegate.setSortByName)
            case .dateModified: #selector(AppDelegate.setSortByDateModified)
            case .dateCreated: #selector(AppDelegate.setSortByDateCreated)
            }
            let iconName = switch option {
            case .name: "textformat"
            case .dateModified: "clock"
            case .dateCreated: "calendar"
            }
            let item = NSMenuItem(title: option.displayName(l10n), action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            item.target = delegate
            item.state = settings.sortBy == option ? .on : .off
            menu.addItem(item)
        }
    }

    private static func sortSubmenu(settings: AppSettings, l10n: L10n) -> NSMenu {
        let menu = NSMenu()
        addSortFieldItems(to: menu, settings: settings, l10n: l10n)
        menu.addItem(.separator())
        for (title, icon, ascending) in [(l10n["sort.ascending"], "arrow.up", true), (l10n["sort.descending"], "arrow.down", false)] {
            let item = menu.addActionItem(title: title, icon: icon) {
                settings.sortAscending = ascending
            }
            item.state = settings.sortAscending == ascending ? .on : .off
        }
        return menu
    }

    /// Show a configured shortcut next to a menu item. Only plain letter and digit keys
    /// map to a key equivalent; other keys are left off.
    private static func showShortcut(_ shortcut: KeyboardShortcut?, on item: NSMenuItem) {
        guard let shortcut,
              let key = KeyCodeTranslator.shared.string(for: shortcut.keyCode),
              key.count == 1, key.first?.isLetter == true || key.first?.isNumber == true
        else { return }
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if shortcut.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        item.keyEquivalent = key.lowercased()
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - Multi-Selection Context Menu

    /// Build an NSMenu shown when right-clicking on a multi-row selection.
    /// Mirrors the single-row menu shape (Move → Tags → Trash) but operates on
    /// every item in `noteStore.selection` at once.
    static func selectionMenu(noteStore: NoteStore, l10n: L10n) -> NSMenu {
        let menu = NSMenu()
        let count = noteStore.selection.count
        let countString = "\(count)"
        let noteCount = noteStore.selectedNotes.count

        // Move To submenu — always offered (notes always movable; folders skip invalid targets).
        if let moveSubmenu = selectionMoveSubmenu(noteStore: noteStore, l10n: l10n) {
            let moveItem = NSMenuItem(
                title: l10n.t("selection.moveTo", countString),
                action: nil,
                keyEquivalent: "",
            )
            moveItem.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)
        }

        // Tags submenu — only meaningful when at least one note is selected.
        if noteCount > 0 {
            let tagsItem = NSMenuItem(
                title: l10n.t("selection.tag", "\(noteCount)"),
                action: nil,
                keyEquivalent: "",
            )
            tagsItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
            tagsItem.submenu = selectionTagsSubmenu(noteStore: noteStore, appSettings: AppSettings.shared)
            menu.addItem(tagsItem)
        }

        menu.addItem(.separator())

        menu.addActionItem(
            title: l10n.t("selection.moveToTrash", countString),
            icon: "trash",
        ) {
            noteStore.trashSelection()
        }
        return menu
    }

    // MARK: - Selection Move Submenu

    /// Folders the selection can move to; nil when there is nowhere to go. Shared by the
    /// selection context menu and the selection bar's Move button.
    static func selectionMoveSubmenu(noteStore: NoteStore, l10n: L10n) -> NSMenu? {
        guard canMoveSelection(noteStore: noteStore) else { return nil }
        let selectedFolders = Set(noteStore.selectedFolderPaths)
        let offerRoot = selectionOffersRoot(noteStore: noteStore)
        let topLevel = noteStore.folders.filter(\.isTopLevel)

        let submenu = NSMenu()
        if offerRoot {
            submenu.addActionItem(title: l10n["common.root"], icon: "house") {
                noteStore.moveSelection(toFolder: "")
            }
        }
        for folder in topLevel {
            selectionMoveTreeItem(
                folder: folder,
                selectedFolders: selectedFolders,
                noteStore: noteStore,
                l10n: l10n,
                menu: submenu,
            )
        }
        return submenu
    }

    /// Whether the selection has anywhere to move, without building the menu.
    static func canMoveSelection(noteStore: NoteStore) -> Bool {
        selectionOffersRoot(noteStore: noteStore) || noteStore.folders.contains(where: \.isTopLevel)
    }

    /// Offer "Root" only when something in the selection isn't already at root: some
    /// selected note has a folder, or some selected folder is nested.
    private static func selectionOffersRoot(noteStore: NoteStore) -> Bool {
        let everyoneAtRoot = noteStore.selectedNotes.allSatisfy(\.folder.isEmpty)
            && noteStore.selectedFolderPaths.allSatisfy { path in
                noteStore.folders.first(where: { $0.name == path })?.isTopLevel ?? true
            }
        return !everyoneAtRoot
    }

    private static func selectionMoveTreeItem(
        folder: Folder,
        selectedFolders: Set<String>,
        noteStore: NoteStore,
        l10n: L10n,
        menu: NSMenu,
    ) {
        // Skip targets that would move a selected folder into itself or a descendant.
        let invalidTarget = selectedFolders.contains(folder.name)
            || selectedFolders.contains(where: { folder.name.hasPrefix($0 + "/") })
        let children = noteStore.childFolders(of: folder.name)

        if children.isEmpty {
            if invalidTarget {
                return
            }
            menu.addActionItem(title: folder.displayName, icon: "folder") {
                noteStore.moveSelection(toFolder: folder.name)
            }
        } else {
            let item = NSMenuItem(title: folder.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            if !invalidTarget {
                sub.addActionItem(title: l10n["common.moveHere"], icon: "arrow.right") {
                    noteStore.moveSelection(toFolder: folder.name)
                }
                sub.addItem(.separator())
            }
            for child in children {
                selectionMoveTreeItem(
                    folder: child,
                    selectedFolders: selectedFolders,
                    noteStore: noteStore,
                    l10n: l10n,
                    menu: sub,
                )
            }
            // If the parent was invalid AND its subtree produced no entries,
            // skip adding an empty submenu.
            guard sub.items.contains(where: { !$0.isSeparatorItem }) else { return }
            item.submenu = sub
            menu.addItem(item)
        }
    }

    // MARK: - Selection Tags Submenu

    /// Tag toggles for the selected notes. Shared by the selection context menu and the
    /// selection bar's Tag button.
    static func selectionTagsSubmenu(noteStore: NoteStore, appSettings: AppSettings) -> NSMenu {
        let menu = NSMenu()
        for tag in TagColor.allCases {
            let item = menu.addActionItem(title: appSettings.label(for: tag), icon: "circle.fill") {
                noteStore.toggleTagOnSelection(tag)
            }
            item.image = tagImage(for: tag)
            switch noteStore.tagState(tag) {
            case .on: item.state = .on
            case .off: item.state = .off
            case .mixed: item.state = .mixed
            }
        }
        return menu
    }

    // MARK: - Note Context Menu

    /// Build an NSMenu for a note row context menu.
    static func noteMenu(
        note: Note,
        noteStore: NoteStore,
        l10n: L10n,
        onRename: @escaping () -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addActionItem(title: l10n["common.rename"], icon: "pencil", action: onRename)

        // Move To submenu
        if let moveSubmenu = noteMoveSubmenu(for: note, noteStore: noteStore, l10n: l10n) {
            let moveItem = NSMenuItem(title: l10n["common.moveTo"], action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)
        }

        // Tags submenu
        let tagsItem = NSMenuItem(title: l10n["common.tags"], action: nil, keyEquivalent: "")
        tagsItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        tagsItem.submenu = tagsSubmenu(for: note, noteStore: noteStore, appSettings: AppSettings.shared)
        menu.addItem(tagsItem)

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["common.copyPlainText"], icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.plainText, forType: .string)
        }

        menu.addActionItem(title: l10n["common.copyMarkdown"], icon: "doc.richtext") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.content, forType: .string)
        }

        menu.addActionItem(title: l10n["common.copyRTF"], icon: "textformat") {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let rtf = note.rtfData {
                pb.setData(rtf, forType: .rtf)
            } else {
                pb.setString(note.plainText, forType: .string)
            }
        }

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["common.showInFinder"], icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([
                FileStorage.urlForNote(note),
            ])
        }

        menu.addActionItem(title: l10n["export.markdown"], icon: "square.and.arrow.up") {
            NoteExporter.exportMarkdown(note: note, noteStore: noteStore)
        }

        menu.addActionItem(title: l10n["export.pdf"], icon: "doc.richtext") {
            NoteExporter.exportPDF(note: note, noteStore: noteStore)
        }

        addGistItems(to: menu, note: note, noteStore: noteStore, l10n: l10n)

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["common.delete"], icon: "trash") {
            noteStore.trashItems(notes: [note], folders: [])
        }

        return menu
    }

    // MARK: - Gist Items

    /// "Copy Gist Link" and "Open Gist" for notes inside a gist clone; "Publish as Private
    /// Gist" and "Publish as Public Gist..." for ordinary notes without images when sync is
    /// active. Menu items are resolved synchronously, so the gist lookup runs when the item
    /// is clicked.
    private static func addGistItems(to menu: NSMenu, note: Note, noteStore: NoteStore, l10n: L10n) {
        switch NoteExporter.gistOffer(for: note) {
        case .none, .publish(blockedByImages: true):
            return
        case .linkToGist:
            menu.addActionItem(title: l10n["sync.copyGistLink"], icon: "link") {
                NoteExporter.copyGistLink(note: note)
            }
            menu.addActionItem(title: l10n["sync.openGist"], icon: "safari") {
                NoteExporter.openGist(note: note)
            }
        case .publish(blockedByImages: false):
            for (title, isPublic) in [(l10n["sync.publishGist"], false), (l10n["sync.publishGistPublic"], true)] {
                menu.addActionItem(title: title, icon: "arrow.up.doc") {
                    NoteExporter.exportAsGist(note: note, noteStore: noteStore, isPublic: isPublic)
                }
            }
        }
    }

    // MARK: - Tags Submenu

    private static func tagsSubmenu(for note: Note, noteStore: NoteStore, appSettings: AppSettings) -> NSMenu {
        let menu = NSMenu()
        let noteID = note.id
        for tag in TagColor.allCases {
            // Reuse the standard MenuDispatch wiring — capture noteID so the toggle
            // always reads the latest note state at click time.
            let item = menu.addActionItem(title: appSettings.label(for: tag), icon: "circle.fill") {
                guard let current = noteStore.notes.first(where: { $0.id == noteID }) else { return }
                noteStore.toggleTag(tag, on: current)
            }
            item.image = tagImage(for: tag)
            item.state = note.tags.contains(tag) ? .on : .off
        }
        return menu
    }

    /// 12pt circle filled with the tag color, used as the menu item icon.
    private static func tagImage(for tag: TagColor) -> NSImage {
        let size: CGFloat = 12
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(tag.color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Folder Color Submenu

    private static func folderColorSubmenu(
        for folder: Folder,
        noteStore: NoteStore,
        l10n: L10n,
    ) -> NSMenu {
        let menu = NSMenu()
        let folderName = folder.name
        let currentColor = folder.color

        for tag in TagColor.allCases {
            // Use the static palette name (Red / Orange / …), not the user's tag label,
            // so renaming a tag does not bleed into the folder color picker.
            let item = menu.addActionItem(title: tag.defaultLabel, icon: "circle.fill") {
                noteStore.setFolderColor(tag, for: folderName)
            }
            item.image = tagImage(for: tag)
            item.state = currentColor == tag ? .on : .off
        }

        menu.addItem(.separator())

        let noneItem = menu.addActionItem(title: l10n["common.none"], icon: "circle") {
            noteStore.setFolderColor(nil, for: folderName)
        }
        noneItem.state = currentColor == nil ? .on : .off

        return menu
    }

    // MARK: - Folder Context Menu

    /// Build an NSMenu for a folder row context menu.
    static func folderMenu(
        folder: Folder,
        noteStore: NoteStore,
        l10n: L10n,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addActionItem(title: l10n["common.rename"], icon: "pencil", action: onRename)

        // Move To submenu
        if let moveSubmenu = folderMoveSubmenu(for: folder, noteStore: noteStore, l10n: l10n) {
            let moveItem = NSMenuItem(title: l10n["common.moveTo"], action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)
        }

        // Folder Color submenu
        let colorItem = NSMenuItem(title: l10n["common.folderColor"], action: nil, keyEquivalent: "")
        colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        colorItem.submenu = folderColorSubmenu(for: folder, noteStore: noteStore, l10n: l10n)
        menu.addItem(colorItem)

        menu.addActionItem(title: l10n["common.showInFinder"], icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([
                FileStorage.urlForFolder(folder.name),
            ])
        }

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["common.delete"], icon: "trash", action: onDelete)

        return menu
    }

    // MARK: - Note Move Submenu

    private static func noteMoveSubmenu(for note: Note, noteStore: NoteStore, l10n: L10n) -> NSMenu? {
        let topLevel = noteStore.folders.filter(\.isTopLevel)
        let canMoveToRoot = !note.folder.isEmpty
        guard canMoveToRoot || !topLevel.isEmpty else { return nil }

        let submenu = NSMenu()

        if canMoveToRoot {
            submenu.addActionItem(title: l10n["common.root"], icon: "house") {
                noteStore.moveNote(note, to: "")
            }
        }

        for folder in topLevel {
            noteMoveTreeItem(folder: folder, note: note, noteStore: noteStore, l10n: l10n, menu: submenu)
        }

        return submenu
    }

    private static func noteMoveTreeItem(
        folder: Folder,
        note: Note,
        noteStore: NoteStore,
        l10n: L10n,
        menu: NSMenu,
    ) {
        let children = noteStore.childFolders(of: folder.name)

        if children.isEmpty {
            let item = menu.addActionItem(title: folder.displayName, icon: "folder") {
                guard folder.name != note.folder else { return }
                noteStore.moveNote(note, to: folder.name)
            }
            if folder.name == note.folder {
                item.state = .on
            }
        } else {
            let item = NSMenuItem(title: folder.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            let moveHere = sub.addActionItem(title: l10n["common.moveHere"], icon: "arrow.right") {
                guard folder.name != note.folder else { return }
                noteStore.moveNote(note, to: folder.name)
            }
            if folder.name == note.folder {
                moveHere.state = .on
            }
            sub.addItem(.separator())
            for child in children {
                noteMoveTreeItem(folder: child, note: note, noteStore: noteStore, l10n: l10n, menu: sub)
            }
            item.submenu = sub
            menu.addItem(item)
        }
    }

    // MARK: - Folder Move Submenu

    private static func folderMoveSubmenu(for folder: Folder, noteStore: NoteStore, l10n: L10n) -> NSMenu? {
        let topLevel = noteStore.folders.filter(\.isTopLevel)
            .filter { $0.name != folder.name && !$0.name.hasPrefix(folder.name + "/") }
        let canMoveToRoot = !folder.isTopLevel
        guard canMoveToRoot || !topLevel.isEmpty else { return nil }

        let submenu = NSMenu()

        if canMoveToRoot {
            submenu.addActionItem(title: l10n["common.root"], icon: "house") {
                noteStore.moveFolder(folder.name, toParent: "")
            }
        }

        for target in topLevel {
            folderMoveTreeItem(target: target, movingFolder: folder, noteStore: noteStore, l10n: l10n, menu: submenu)
        }

        return submenu
    }

    private static func folderMoveTreeItem(
        target: Folder,
        movingFolder: Folder,
        noteStore: NoteStore,
        l10n: L10n,
        menu: NSMenu,
    ) {
        let isCurrentParent = target.name == movingFolder.parentPath
        let children = noteStore.childFolders(of: target.name)
            .filter { $0.name != movingFolder.name && !$0.name.hasPrefix(movingFolder.name + "/") }

        if isCurrentParent {
            guard !children.isEmpty else { return }
            let item = NSMenuItem(title: target.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            for child in children {
                folderMoveTreeItem(target: child, movingFolder: movingFolder, noteStore: noteStore, l10n: l10n, menu: sub)
            }
            item.submenu = sub
            menu.addItem(item)
            return
        }

        if children.isEmpty {
            menu.addActionItem(title: target.displayName, icon: "folder") {
                noteStore.moveFolder(movingFolder.name, toParent: target.name)
            }
        } else {
            let item = NSMenuItem(title: target.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            sub.addActionItem(title: l10n["common.moveHere"], icon: "arrow.right") {
                noteStore.moveFolder(movingFolder.name, toParent: target.name)
            }
            sub.addItem(.separator())
            for child in children {
                folderMoveTreeItem(target: child, movingFolder: movingFolder, noteStore: noteStore, l10n: l10n, menu: sub)
            }
            item.submenu = sub
            menu.addItem(item)
        }
    }
}
