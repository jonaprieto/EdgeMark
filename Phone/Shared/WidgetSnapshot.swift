import Foundation
import Security

/// What the widgets show: the next meetings, reminders and top todos. The app writes it after each sync;
/// only this crosses into the widget's Keychain group, tokens and keys stay in the app's own.
public struct WidgetSnapshot: Codable, Equatable {
    public struct Event: Codable, Hashable {
        public var title: String
        public var start: Date
        public var end: Date

        public init(title: String, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    public var date: Date
    public var events: [Event]
    public var todos: [String]
    public var openTodos: Int
    public var reminders: [Event]

    public init(date: Date, events: [Event], todos: [String], openTodos: Int, reminders: [Event] = []) {
        self.date = date
        self.events = events
        self.todos = todos
        self.openTodos = openTodos
        self.reminders = reminders
    }

    /// `3:30 PM` today, `Tue 3:30 PM` this week, `Nov 12 3:30 PM` later: one format everywhere.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = days == 0 ? "h:mm a" : (1 ..< 7).contains(days) ? "EEE h:mm a" : "MMM d h:mm a"
        return formatter.string(from: date)
    }

    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "EdgeMarkWidgetAccessGroup") as? String,
              !group.contains("WIDGET_ACCESS_GROUP") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "edgemark-widget",
                kSecAttrAccount as String: "snapshot", kSecAttrAccessGroup as String: group]
    }

    public static func load() -> WidgetSnapshot? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save() throws {
        guard let query = Self.query else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement)) }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
