import EdgeJournalLogic
import EdgePhoneSupport
import EdgeReminderLogic
import SwiftUI
import UserNotifications

/// Something iOS will ring. A todo with a time comes from the notes, so it reaches this phone from
/// the Mac too. A reminder on a note lives in the notification center only, as it does on the Mac,
/// so it stays on the device that set it.
struct Reminder: Identifiable, Equatable {
    let title: String
    let date: Date
    let path: String
    /// The task line of a todo, nil for a reminder on a note.
    let raw: String?
    let repeats: Bool

    var id: String {
        raw ?? path
    }
}

enum Reminders {
    private static let center = UNUserNotificationCenter.current()
    private static let todoPrefix = "reminder.todo."
    private static let notePrefix = "reminder.note."
    private static let done = "reminder.action.done"
    private static let later = "reminder.action.later"
    /// iOS keeps 64 pending. This leaves room for the sleep prompts and the notes' reminders.
    static let limit = 50

    /// Editing a note takes an unlocked phone: its files stay sealed until then.
    static let todoCategory = UNNotificationCategory(
        identifier: "reminder.todo",
        actions: [
            UNNotificationAction(identifier: done, title: "Done", options: [.authenticationRequired]),
            UNNotificationAction(identifier: later, title: "In 1 hour", options: [.authenticationRequired]),
        ],
        intentIdentifiers: [],
    )

    private static var allowed: Bool {
        get async { (try? await center.requestAuthorization(options: [.alert, .sound])) == true }
    }

    /// False when iOS refused it, which can happen just after it granted permission.
    private static func add(_ id: String, _ content: UNNotificationContent, _ trigger: UNNotificationTrigger) async -> Bool {
        (try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))) != nil
    }

    /// Replaces the todos waiting to ring. False when any of them could not be set.
    static func schedule(_ todos: [Todo]) async -> Bool {
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(todoPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard !todos.isEmpty else { return true }
        guard await allowed else { return false }
        var added = true
        for todo in todos {
            guard let date = todo.ringsAt() else { continue }
            let content = UNMutableNotificationContent()
            content.title = Journal.withoutImages(todo.text)
            content.sound = .default
            content.categoryIdentifier = todoCategory.identifier
            content.userInfo = ["path": todo.path, "raw": todo.raw]
            let trigger = UNCalendarNotificationTrigger(dateMatching: ReminderOption.trigger(at: date), repeats: false)
            added = await add(todoPrefix + todo.id, content, trigger) && added
        }
        return added
    }

    /// Replaces the note's reminder. False when it could not be set.
    static func schedule(_ triggers: [DateComponents], repeats: Bool, for note: PhoneNote) async -> Bool {
        guard await allowed else { return false }
        await cancelNotes { $0 == note.path }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.text.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("#") }.map(String.init) ?? ""
        content.sound = .default
        content.userInfo = ["path": note.path]
        var added = true
        for (index, components) in triggers.enumerated() {
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
            added = await add("\(notePrefix)\(note.path).\(index)", content, trigger) && added
        }
        return added
    }

    /// Cancels the reminders on the notes `match` picks.
    static func cancelNotes(where match: (String) -> Bool) async {
        let ids = await center.pendingNotificationRequests().filter {
            $0.identifier.hasPrefix(notePrefix) && ($0.content.userInfo["path"] as? String).map(match) == true
        }
        center.removePendingNotificationRequests(withIdentifiers: ids.map(\.identifier))
    }

    /// All that is still to ring, soonest first. An every-weekday reminder counts once.
    static func pending() async -> [Reminder] {
        let all = await center.pendingNotificationRequests().compactMap { request -> Reminder? in
            guard let path = request.content.userInfo["path"] as? String,
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate() else { return nil }
            return Reminder(title: request.content.title, date: date, path: path, raw: request.content.userInfo["raw"] as? String, repeats: trigger.repeats)
        }
        var seen = Set<String>()
        return all.sorted { $0.date < $1.date }.filter { seen.insert($0.id).inserted }
    }

    /// A tap opens the note; the buttons act on the todo and wait for the sync, since iOS keeps
    /// the app awake only until this returns.
    @MainActor
    static func handle(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let path = info["path"] as? String else { return }
        let model = PhoneModel.shared
        let todo = (info["raw"] as? String).flatMap { model.todo(at: path, raw: $0) }
        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier: break
        case done: await todo.map { model.toggle($0) }?.value
        case later: await todo.map { model.setDue(Journal.stamp(Date().addingTimeInterval(3600)), on: $0) }?.value
        default:
            var link = URLComponents(string: "edgemark://note")!
            link.queryItems = [URLQueryItem(name: "path", value: path)]
            if let url = link.url { await UIApplication.shared.open(url) }
        }
    }
}

extension Todo {
    /// When it is due, as the app writes it.
    var dueLabel: String? {
        ringsAt().map { WidgetSnapshot.when($0) } ?? due
    }
}

extension ReminderOption {
    var title: String {
        switch self {
        case .in1h: "In 1 hour"
        case .in3h: "In 3 hours"
        case .tonight: "Tonight at 8:00 PM"
        case .tomorrowMorning: "Tomorrow at 9:00 AM"
        case .everyWeekday: "Every weekday at 9:00 AM"
        }
    }

    var icon: String {
        switch self {
        case .in1h, .in3h: "clock"
        case .tonight: "moon"
        case .tomorrowMorning: "sunrise"
        case .everyWeekday: "repeat"
        }
    }
}

/// Remind Me on a note: the Mac's options with Jev's pick marked, or any date and time.
struct ReminderSheet: View {
    let note: PhoneNote

    @Environment(\.dismiss) private var dismiss
    @State private var suggested: ReminderOption?
    @State private var custom = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var refused = false

    private var model: PhoneModel { .shared }
    private let options = ReminderOption.available(now: Date())

    var body: some View {
        NavigationStack {
            Form {
                if refused {
                    Text("Could not set it. Check that notifications are on for EdgeMark in the Settings app, then try again.").foregroundStyle(.red)
                }
                Section {
                    ForEach(options, id: \.self) { option in
                        Button { set(option.triggers(now: Date()), repeats: option.repeats) } label: {
                            LabeledContent {
                                if option == suggested { Text("Suggested") }
                            } label: {
                                Label(option.title, systemImage: option.icon)
                            }
                        }
                    }
                }
                Section {
                    DatePicker("Date and time", selection: $custom, in: Date()...)
                    Button("Set", systemImage: "calendar") { set([ReminderOption.trigger(at: custom)], repeats: false) }
                }
                if model.hasReminder(on: note.path) {
                    Button("Cancel Reminder", systemImage: "bell.slash", role: .destructive) {
                        Task {
                            await Reminders.cancelNotes { $0 == note.path }
                            model.refresh()
                            dismiss()
                        }
                    }
                }
            }
            .themedBackground()
            .navigationTitle("Remind Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Nothing leaves the phone for an encrypted note.
            guard !note.isEncrypted else { return }
            suggested = await ReminderSuggestion.suggest(title: note.title, text: note.text, now: Date(), options: options, apiKey: Keychain.get("typesafe-api-key"))
        }
    }

    private func set(_ triggers: [DateComponents], repeats: Bool) {
        Task {
            refused = await !Reminders.schedule(triggers, repeats: repeats, for: note)
            model.refresh()
            if !refused { dismiss() }
        }
    }
}
