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
        menu.addActionItem(title: l10n["reminder.custom"], icon: "calendar") {
            guard let date = pickDate() else { return }
            Task { @MainActor in
                if await !NoteReminders.shared.schedule(at: date, for: note) {
                    showNotificationsOff()
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

    /// Asks for a day (calendar) and a time; nil on Cancel or a moment already past.
    private static func pickDate() -> Date? {
        let l10n = L10n.shared
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let start = calendar.date(bySettingHour: ReminderOption.morningHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow

        let day = NSDatePicker()
        day.datePickerStyle = .clockAndCalendar
        day.datePickerElements = .yearMonthDay
        day.minDate = calendar.startOfDay(for: Date())
        day.dateValue = start
        let time = NSDatePicker()
        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = .hourMinute
        time.dateValue = start
        let stack = NSStackView(views: [day, time])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.frame.size = stack.fittingSize

        let alert = NSAlert()
        alert.messageText = l10n["reminder.customTitle"]
        alert.accessoryView = stack
        alert.addButton(withTitle: l10n["reminder.set"])
        alert.addButton(withTitle: l10n["common.cancel"])
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let hm = calendar.dateComponents([.hour, .minute], from: time.dateValue)
        guard let date = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day.dateValue),
              date > Date()
        else {
            NSSound.beep()
            return nil
        }
        return date
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
