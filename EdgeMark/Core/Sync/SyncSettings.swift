import Foundation
import Observation

/// User options for GitHub sync, persisted in UserDefaults under `sync.*` keys.
@Observable
final class SyncSettings {
    static let shared = SyncSettings()

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "sync.enabled") } }
    /// Seconds between the last note save and the commit+push (30 to 600).
    var debounceSeconds: Double { didSet { defaults.set(debounceSeconds, forKey: "sync.debounceSeconds") } }
    /// Minimum seconds between two unforced pulls (panel shows in quick succession).
    var pullIntervalSeconds: Double { didSet { defaults.set(pullIntervalSeconds, forKey: "sync.pullIntervalSeconds") } }
    /// Placeholders: `{date}` (yyyy-MM-dd HH:mm) and `{host}`.
    var commitTemplate: String { didSet { defaults.set(commitTemplate, forKey: "sync.commitTemplate") } }
    var pushOnQuit: Bool { didSet { defaults.set(pushOnQuit, forKey: "sync.pushOnQuit") } }
    var syncGists: Bool { didSet { defaults.set(syncGists, forKey: "sync.syncGists") } }
    /// GitHub login used for gh calls and embedded in remote URLs. Empty = not chosen.
    var account: String { didSet { defaults.set(account, forKey: "sync.account") } }

    static let defaultTemplate = "notes: {date}"

    static var hostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "mac" }
        let name = String(cString: buffer)
        return name.isEmpty ? "mac" : name
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "sync.enabled") as? Bool ?? true
        debounceSeconds = defaults.object(forKey: "sync.debounceSeconds") as? Double ?? 120
        pullIntervalSeconds = defaults.object(forKey: "sync.pullIntervalSeconds") as? Double ?? 60
        commitTemplate = defaults.string(forKey: "sync.commitTemplate") ?? Self.defaultTemplate
        pushOnQuit = defaults.object(forKey: "sync.pushOnQuit") as? Bool ?? true
        syncGists = defaults.object(forKey: "sync.syncGists") as? Bool ?? true
        account = defaults.string(forKey: "sync.account") ?? ""
    }

    func renderCommitMessage(date: Date = Date(), host: String = SyncSettings.hostName) -> String {
        let template = commitTemplate.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultTemplate : commitTemplate
        return template
            .replacingOccurrences(of: "{date}", with: Self.dateFormatter.string(from: date))
            .replacingOccurrences(of: "{host}", with: host)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
