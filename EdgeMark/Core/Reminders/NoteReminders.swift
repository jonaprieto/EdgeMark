import AppKit
import Observation
import UserNotifications

/// Note reminders as macOS local notifications. The notification center is the only
/// store: request ids carry the note's UUID, so nothing else is saved.
@Observable
final class NoteReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoteReminders()

    /// Notes with a pending reminder, for the bell and the menus.
    private(set) var noteIDs: Set<UUID> = []
    /// Opens the note of a clicked reminder.
    @ObservationIgnored var onOpen: ((UUID) -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    private static let prefix = "reminder."

    /// Replaces the note's reminder. False when notifications are not allowed.
    func schedule(_ option: ReminderOption, for note: Note) async -> Bool {
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        await cancel(noteIDs: [note.id])
        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? L10n.shared["common.untitled"] : note.title
        if !note.isEncrypted {
            content.body = Note.plainText(from: Self.firstLine(of: note.content))
        }
        content.sound = .default
        content.userInfo = ["noteID": note.id.uuidString]
        for (index, components) in option.triggers(now: Date()).enumerated() {
            let id = Self.prefix + note.id.uuidString + (option.repeats ? ".\(index)" : "")
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: option.repeats)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        await refresh()
        return true
    }

    func cancel(noteIDs: Set<UUID>) async {
        await center.removePendingNotificationRequests(withIdentifiers: ids { noteIDs.contains($0) })
        await refresh()
    }

    func refresh() async {
        let ids = await center.pendingNotificationRequests().compactMap { Self.noteID(in: $0.identifier) }
        await MainActor.run { noteIDs = Set(ids) }
    }

    private func ids(where match: (UUID) -> Bool) async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier).filter { id in
            Self.noteID(in: id).map(match) ?? false
        }
    }

    private static func noteID(in identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count).prefix(36)))
    }

    /// First line of the body that is not the title heading.
    private static func firstLine(of content: String) -> String {
        content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        await refresh()
        return [.banner, .sound]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["noteID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onOpen?(id) }
        await refresh()
    }
}
