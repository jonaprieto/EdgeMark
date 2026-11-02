import EdgeJournalLogic
import SwiftUI
import UserNotifications

/// Two taps instead of a sentence: when you go to bed, then when you get up. The bedtime waits in
/// UserDefaults, which stays writable on a locked phone, unlike the note files.
enum SleepTracker {
    static let bedKey = "sleep.bedAt"
    /// An older bedtime is a night that was never closed.
    private static let longestNight: TimeInterval = 18 * 3600

    static func inBed(since stored: Double, now: Date = Date()) -> Date? {
        guard stored > 0 else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: stored)
        return now.timeIntervalSince(date) < longestNight ? date : nil
    }

    static func goingToBed(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: bedKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bedKey)
    }

    /// The sleep capture, filled in with the night when a bedtime is waiting.
    static var capture: CaptureRequest {
        var request = CaptureRequest(kind: .sleep)
        if let bed = inBed(since: UserDefaults.standard.double(forKey: bedKey)) {
            request.text = "\(Journal.time(bed)) \(Journal.time(Date()))"
        }
        return request
    }

    static var link: URL {
        var parts = URLComponents(string: "edgemark://capture")!
        parts.queryItems = [URLQueryItem(name: "kind", value: "sleep"), URLQueryItem(name: "text", value: capture.text)]
        return parts.url!
    }
}

/// An evening or morning prompt set to ring every day.
struct SleepPrompt: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
}

/// Optional evening and morning prompts. Local, so they need no account or server.
enum SleepReminder {
    static let bedTime = "sleep.bed"
    static let wakeTime = "sleep.morning"
    static let goingToBed = "sleep.action.bed"
    static let imUp = "sleep.action.up"

    /// Actions on the notifications themselves. Only "I'm up" opens the app, to show the night.
    static func registerActions() {
        let bed = UNNotificationCategory(
            identifier: bedTime,
            actions: [UNNotificationAction(identifier: goingToBed, title: "Going to bed", options: [])],
            intentIdentifiers: [],
        )
        let wake = UNNotificationCategory(
            identifier: wakeTime,
            actions: [UNNotificationAction(identifier: imUp, title: "I'm up", options: [.foreground])],
            intentIdentifiers: [],
        )
        UNUserNotificationCenter.current().setNotificationCategories([bed, wake, Reminders.todoCategory])
    }

    /// False when it could not be set.
    static func schedule(_ id: String, title: String, at time: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        cancel(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.categoryIdentifier = id
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        return (try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))) != nil
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Stops a prompt for good, which turns off its switch in Settings too.
    static func turnOff(_ id: String) {
        cancel(id)
        UserDefaults.standard.set(false, forKey: id == bedTime ? "sleep.bedReminder" : "sleep.reminder")
    }

    static func pending() async -> [SleepPrompt] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.compactMap { request -> SleepPrompt? in
            guard [bedTime, wakeTime].contains(request.identifier),
                  let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return nil }
            return SleepPrompt(id: request.identifier, title: request.content.title, date: date)
        }.sorted { $0.date < $1.date }
    }
}

/// Handles the notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SleepReminder.registerActions()
        Task { await Dictation.endActivities() }
        return true
    }

    @MainActor
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["path"] != nil {
            await Reminders.handle(response)
            return
        }
        // Tapping the notification itself means the same as its button.
        if response.notification.request.content.categoryIdentifier == SleepReminder.bedTime {
            guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
            SleepTracker.goingToBed()
        } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            await UIApplication.shared.open(SleepTracker.link)
        }
    }

    /// Shows them even with the app open, at bedtime as much as any other time.
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
