import Cocoa
import SwiftUI

/// Shared footer bar with sort (left), sync and settings (right) menus.
/// Pinned at the bottom of the content card on home and folder list screens.
struct ContentFooterBar: View {
    @Environment(AppSettings.self) var settings
    @Environment(NoteStore.self) var noteStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let l10n = L10n.shared
        HStack {
            HeaderIconButton(systemName: "arrow.up.arrow.down", help: l10n["sort.help"]) {
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
            HeaderIconButton(systemName: "gearshape", help: l10n["menu.settings"]) {
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

/// Footer sync button: the sync arrows (turning while syncing) with the status dot as a
/// badge on the lower right corner.
private struct SyncFooterButton: View {
    let state: SyncState
    let help: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state == .syncing && !reduceMotion)
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
