import Cocoa
import SwiftUI

/// Shared footer bar with sort (left), sync and settings (right) menus.
/// Pinned at the bottom of the content card on home and folder list screens.
/// While rows are selected it shows the selection actions instead.
struct ContentFooterBar: View {
    @Environment(AppSettings.self) var settings
    @Environment(NoteStore.self) var noteStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if noteStore.selection.isEmpty {
            footer
        } else {
            SelectionBar()
        }
    }

    private var footer: some View {
        let l10n = L10n.shared
        return HStack {
            HeaderIconButton(systemName: "arrow.up.arrow.down", help: l10n["tooltip.sort"]) {
                showSortMenu()
            }
            Spacer()
            if GitSync.shared.isActive || GitSync.shared.rootRepo != nil {
                let advice = SyncAdvice.current(GitSync.shared, l10n: l10n)
                let detail = advice?.text ?? GitSync.shared.state.summary
                SyncFooterButton(state: GitSync.shared.state, help: l10n.t("sync.footer.help", detail)) {
                    showSyncMenu()
                }
            }
            HeaderIconButton(systemName: "gearshape", help: l10n["tooltip.menu"]) {
                showSettingsMenu()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Sort Menu

    private func showSortMenu() {
        let l10n = L10n.shared
        let menu = NSMenu()
        let delegate = NSApp.delegate as? AppDelegate

        NoteListMenus.addSortFieldItems(to: menu, settings: settings, l10n: l10n)

        menu.addItem(.separator())

        let dirItem = NSMenuItem(
            title: settings.sortAscending ? l10n["sort.ascending"] : l10n["sort.descending"],
            action: #selector(AppDelegate.toggleSortDirection),
            keyEquivalent: "",
        )
        dirItem.image = NSImage(
            systemSymbolName: settings.sortAscending ? "arrow.up" : "arrow.down",
            accessibilityDescription: nil,
        )
        dirItem.target = delegate
        menu.addItem(dirItem)

        popUpMenu(menu)
    }

    // MARK: - Settings Menu

    private func showSettingsMenu() {
        let l10n = L10n.shared
        let menu = NSMenu()
        let delegate = NSApp.delegate as? AppDelegate

        let trashItem = NSMenuItem(
            title: l10n["common.trash"],
            action: #selector(AppDelegate.showTrash),
            keyEquivalent: "",
        )
        trashItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        trashItem.target = delegate
        menu.addItem(trashItem)

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["menu.settings"], icon: "gearshape") { [openSettings] in
            openSettings()
        }

        let updateItem = NSMenuItem(
            title: l10n["menu.checkUpdates"],
            action: #selector(AppDelegate.checkForUpdates),
            keyEquivalent: "",
        )
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.target = delegate
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: l10n["menu.quit"],
            action: #selector(AppDelegate.quitApp),
            keyEquivalent: "",
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = delegate
        menu.addItem(quitItem)

        popUpMenu(menu)
    }

    // MARK: - Sync Menu

    private func showSyncMenu() {
        let l10n = L10n.shared
        let sync = GitSync.shared
        let state = sync.state
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: state.summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        if let advice = SyncAdvice.current(sync, l10n: l10n) {
            for line in [advice.problem, advice.fix] {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        menu.addActionItem(title: l10n["sync.syncNow"], icon: "arrow.triangle.2.circlepath") {
            Task { await sync.syncNow() }
        }.isEnabled = sync.isActive && state != .syncing

        let root = sync.root
        menu.addActionItem(title: l10n["sync.menu.openRepo"], icon: "arrow.up.right.square") {
            guard let root else { return }
            Task { _ = await Shell.run("gh", ["repo", "view", "--web"], cwd: root) }
        }.isEnabled = sync.rootRepo != nil

        menu.addActionItem(title: l10n["sync.menu.showFolder"], icon: "folder") {
            guard let root else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }.isEnabled = root != nil

        let heldCount = sync.heldFiles.values.reduce(0) { $0 + $1.count }
        var isConflict = false
        if case .conflict = state { isConflict = true }
        if heldCount > 0 || isConflict {
            menu.addItem(.separator())
        }
        if heldCount > 0 {
            menu.addActionItem(title: l10n.t("sync.menu.held", "\(heldCount)"), icon: "lock.shield") { [openSettings] in
                SettingsRouter.shared.tab = .sync
                openSettings()
            }
        }
        if isConflict {
            menu.addActionItem(title: l10n["sync.menu.resolve"], icon: "exclamationmark.triangle") { [openSettings] in
                SettingsRouter.shared.tab = .sync
                openSettings()
            }
        }

        menu.addItem(.separator())
        menu.addActionItem(title: l10n["sync.menu.settings"], icon: "gearshape") { [openSettings] in
            SettingsRouter.shared.tab = .sync
            openSettings()
        }

        popUpMenu(menu)
    }

    // MARK: - Helpers

    /// Show an NSMenu at the current click location.
    private func popUpMenu(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent,
              let view = event.window?.contentView
        else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

// MARK: - Selection Bar

/// Footer content while rows are selected: the count, then Move, Tag, Move to Trash and
/// Clear. The menus are the ones the right-click selection menu uses, so both act the
/// same way. Falls back to icons only when the panel is too narrow for the labels.
private struct SelectionBar: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(L10n.self) var l10n

    var body: some View {
        let count = noteStore.selection.count
        let canMove = NoteListMenus.canMoveSelection(noteStore: noteStore)
        let canTag = !noteStore.selectedNotes.isEmpty
        HStack(spacing: 4) {
            Text(l10n.t(count == 1 ? "selection.count.one" : "selection.count.other", "\(count)"))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                buttons(showTitles: true, canMove: canMove, canTag: canTag)
                buttons(showTitles: false, canMove: canMove, canTag: canTag)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func buttons(showTitles: Bool, canMove: Bool, canTag: Bool) -> some View {
        HStack(spacing: 2) {
            if canMove {
                SelectionBarButton(
                    title: l10n["selection.bar.move"],
                    systemName: "tray.and.arrow.down",
                    help: l10n["tooltip.selection.move"],
                    showTitle: showTitles,
                ) {
                    guard let menu = NoteListMenus.selectionMoveSubmenu(noteStore: noteStore, l10n: l10n) else { return }
                    popUp(menu)
                }
            }
            if canTag {
                SelectionBarButton(
                    title: l10n["selection.bar.tag"],
                    systemName: "tag",
                    help: l10n["tooltip.selection.tag"],
                    showTitle: showTitles,
                ) {
                    popUp(NoteListMenus.selectionTagsSubmenu(noteStore: noteStore, appSettings: AppSettings.shared))
                }
            }
            SelectionBarButton(
                title: l10n["selection.bar.trash"],
                systemName: "trash",
                help: l10n["tooltip.selection.trash"],
                showTitle: showTitles,
                role: .destructive,
            ) {
                noteStore.trashSelection()
            }
            SelectionBarButton(
                title: nil,
                systemName: "xmark",
                help: l10n["tooltip.selection.clear"],
                showTitle: false,
            ) {
                noteStore.clearSelection()
            }
            .accessibilityLabel(l10n["selection.bar.clear"])
        }
        .fixedSize()
    }

    /// Show a menu at the click that pressed the button.
    private func popUp(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent,
              let view = event.window?.contentView
        else { return }
        menu.popUpContextMenu(with: event, for: view)
    }
}

/// Compact footer button: an icon, with its title when there is room.
private struct SelectionBarButton: View {
    let title: String?
    let systemName: String
    let help: String
    let showTitle: Bool
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                if showTitle, let title {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(isHovered ? .primary : .secondary))
            .padding(.horizontal, 6)
            .frame(minWidth: 28, minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(isHovered ? 0.1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title ?? help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

/// Footer sync button: the sync arrows (turning while syncing) with the status dot as a
/// badge on the lower right corner.
private struct SyncFooterButton: View {
    let state: SyncState
    let help: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// One turn every 1.2 s.
    private static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
    }

    var body: some View {
        Button(action: action) {
            // Clock-driven rotation, paused unless syncing, so an idle panel draws no frames.
            TimelineView(.animation(paused: state != .syncing || reduceMotion)) { context in
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .rotationEffect(.degrees(state == .syncing && !reduceMotion ? Self.angle(at: context.date) : 0))
            }
                .frame(width: 20, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    SyncStatusDot(state: state)
                        .padding(1)
                        .background(Circle().fill(.background))
                        .offset(x: 2, y: 2)
                }
                // Same 28 pt hit area as the neighbouring icon buttons.
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(state.summary)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
