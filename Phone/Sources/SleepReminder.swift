import UIKit
import UserNotifications

/// An optional reminder each morning to log the night. Local, so it needs no account or server.
enum SleepReminder {
    private static let id = "sleep.morning"
    static let link = URL(string: "edgemark://capture?kind=sleep")!

    /// False when notifications are not allowed.
    static func schedule(at time: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        cancel()
        let content = UNMutableNotificationContent()
        content.title = "How did you sleep?"
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Opens the sleep capture when the reminder is tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive _: UNNotificationResponse) async {
        await UIApplication.shared.open(SleepReminder.link)
    }
}
