import AppKit

/// "Remind Me" options for a note: the list's note menu shows them as a submenu, the
/// editor's bell pops them up and badges Jev's suggestion.
enum ReminderMenu {
    static func menu(for note: Note) -> (menu: NSMenu, items: [ReminderOption: NSMenuItem]) {
        let l10n = L10n.shared
        let menu = NSMenu()
        var items: [ReminderOption: NSMenuItem] = [:]
        for option in ReminderOption.available(now: Date()) {
            items[option] = menu.addActionItem(title: title(of: option), icon: icon(of: option)) {
                Task { @MainActor in
                    if await !NoteReminders.shared.schedule(option, for: note) {
                        showNotificationsOff()
                    }
                }
            }
        }
        if NoteReminders.shared.noteIDs.contains(note.id) {
            menu.addItem(.separator())
            menu.addActionItem(title: l10n["reminder.cancel"], icon: "bell.slash") {
                Task { await NoteReminders.shared.cancel(noteIDs: [note.id]) }
            }
        }
        return (menu, items)
    }

    /// "Tonight (8:00 PM)": the clock time for the options that have one.
    private static func title(of option: ReminderOption) -> String {
        let name = L10n.shared["reminder.\(option.rawValue)"]
        let hour: Int? = switch option {
        case .tonight: ReminderOption.tonightHour
        case .tomorrowMorning, .everyWeekday: ReminderOption.morningHour
        case .in1h, .in3h: nil
        }
        guard let hour, let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else {
            return name
        }
        return "\(name) (\(date.formatted(date: .omitted, time: .shortened)))"
    }

    private static func icon(of option: ReminderOption) -> String {
        switch option {
        case .in1h, .in3h: "clock"
        case .tonight: "moon"
        case .tomorrowMorning: "sunrise"
        case .everyWeekday: "repeat"
        }
    }

    private static func showNotificationsOff() {
        let l10n = L10n.shared
        let alert = NSAlert()
        alert.messageText = l10n["reminder.offTitle"]
        alert.informativeText = l10n["reminder.offBody"]
        alert.addButton(withTitle: l10n["reminder.openSettings"])
        alert.addButton(withTitle: l10n["common.cancel"])
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
