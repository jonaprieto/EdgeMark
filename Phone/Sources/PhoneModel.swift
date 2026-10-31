import EdgeJournalLogic
import EdgePhoneSync
import EdgeStorageLogic
import EdgeSync
import Foundation
import UIKit

struct PhoneNote: Identifiable, Hashable {
    let path: String
    var title: String
    var text: String
    var modified: Date

    var id: String { path }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var isEncrypted: Bool { path.hasSuffix(".age") }
}

@MainActor @Observable
final class PhoneModel {
    static let shared = PhoneModel()
    // ponytail: one user, one repo. Move to Settings if that ever changes.
    static let repository = "owner/notes"

    private(set) var notes: [PhoneNote] = []
    private(set) var status = ""
    private(set) var lastSync: Date?
    private(set) var held: [String: [String]] = [:]
    private(set) var syncing = false
    private(set) var places: [PlaceLine] = []
    /// Edited since it was last finished. Finishing records the position once.
    private var unfinished: String?
    /// Bumped when files changed under the views, which then read them again.
    private(set) var revision = 0
    /// The note open in the editor. Sync waits for it, so a pull cannot race the typing.
    var editing: String?

    private let mirror: NotesMirror?
    private let position = PositionLog()
    private var allowed: Set<String> {
        didSet { UserDefaults.standard.set(Array(allowed), forKey: "sync.allowedHashes") }
    }

    private init() {
        // Keys exported to scripts/phone.sh reach the app once, at launch; the Keychain keeps them.
        let environment = ProcessInfo.processInfo.environment
        for (name, account) in ["EDGEMARK_GITHUB_TOKEN": "github-token", "TYPESAFE_API_KEY": "typesafe-api-key"] {
            if let value = environment[name], !value.isEmpty { Keychain.set(account, value) }
        }
        allowed = Set(UserDefaults.standard.stringArray(forKey: "sync.allowedHashes") ?? [])
        let support = URL.applicationSupportDirectory
        do {
            mirror = try NotesMirror(root: support.appendingPathComponent("notes"), baseURL: support.appendingPathComponent("sync-base.json"))
        } catch {
            mirror = nil
            status = "\(error)"
        }
        refresh()
    }

    func note(_ path: String) -> PhoneNote? {
        notes.first { $0.path == path }
    }

    func text(of path: String) -> String {
        mirror.flatMap { try? $0.read(path) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func folderURL(of path: String) -> URL? {
        mirror?.root.appendingPathComponent((path as NSString).deletingLastPathComponent, isDirectory: true)
    }

    // ponytail: keeps every note's text in memory for search, fine for tens of notes.
    func refresh() {
        guard let mirror, let paths = try? mirror.paths() else { return }
        let dates = sidecarDates()
        let base = mirror.loadBase().blobs
        let local = (try? mirror.shas()) ?? [:]
        notes = paths.filter(Self.isNote).map { path in
            let name = (path as NSString).lastPathComponent
            let encrypted = path.hasSuffix(".age")
            let text = encrypted ? "" : self.text(of: path)
            let file = mirror.modified(path) ?? .distantPast
            return PhoneNote(
                path: path,
                title: encrypted ? String(name.prefix { $0 != "." }) : NoteText.title(from: text),
                text: text,
                modified: local[path] == base[path] ? dates[path] ?? file : file,
            )
        }.sorted { $0.modified > $1.modified }
        places = PlaceLine.all(in: text(of: PlaceLine.logPath))
        revision += 1
    }

    /// A note is an `.md` or `.md.age` file outside hidden folders.
    private static func isNote(_ path: String) -> Bool {
        (path.hasSuffix(".md") || path.hasSuffix(".md.age")) && !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Modification dates the Mac keeps in the sidecar. Pulled files only carry the sync time.
    private func sidecarDates() -> [String: Date] {
        struct Entry: Decodable {
            var path: String
            var modifiedAt: Date
        }
        struct Sidecar: Decodable {
            var notes: [String: Entry]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? mirror?.read(".edgemark/meta.json"),
              let sidecar = try? decoder.decode(Sidecar.self, from: data) else { return [:] }
        return Dictionary(sidecar.notes.values.map { ($0.path, $0.modifiedAt) }) { $0 > $1 ? $0 : $1 }
    }

    func save(_ text: String, to path: String) {
        do {
            try mirror?.write(Data(text.utf8), to: path)
        } catch {
            status = "Could not save: \(error)"
        }
    }

    /// A change typed in the editor.
    func edit(_ text: String, path: String) {
        unfinished = path
        save(text, to: path)
    }

    /// A note is done: records where, then syncs. Without a position the note still syncs.
    func finish(inBackground: Bool = false) async {
        if let path = unfinished {
            unfinished = nil
            await recordPosition(of: path)
        }
        await sync(inBackground: inBackground)
    }

    private func recordPosition(of path: String) async {
        guard let fix = await position.fix() else { return }
        let line = PlaceLine(date: Date(), path: path, latitude: fix.location.coordinate.latitude, longitude: fix.location.coordinate.longitude, place: fix.place)
        save(text(of: PlaceLine.logPath) + line.text + "\n", to: PlaceLine.logPath)
    }

    /// Creates a note whose first line is the title, as the Mac expects, and returns its path.
    func create(title: String, folder: String) -> String? {
        guard let mirror else { return nil }
        let stem = (folder.isEmpty ? "" : folder + "/") + NoteText.sanitizeForFilename(title)
        var path = stem + ".md"
        var n = 2
        while mirror.exists(path) {
            path = "\(stem)-\(n).md"
            n += 1
        }
        save("# \(title)\n\n", to: path)
        refresh()
        return path
    }

    /// Adds a line to today's file. Needs no network; sync carries it when it can.
    func capture(_ text: String, kind: Journal.Kind, due: Date?) {
        let now = Date()
        let path = Journal.path(for: now)
        let existing = mirror?.exists(path) == true ? self.text(of: path) : Journal.emptyDay(for: now)
        let entry = Journal.entry(text, kind: kind, at: now, due: due)
        save(Journal.appending(entry, under: kind, to: existing), to: path)
        unfinished = path
        refresh()
        Task { await finish() }
    }

    /// Lets the held file through on the next sync.
    func allow(_ path: String) {
        allowed.insert(NoteGuard.hash(path: path, text: text(of: path)))
        Task { await sync() }
    }

    func sync(inBackground: Bool = false) async {
        guard !syncing, let mirror, inBackground || editing == nil else { return }
        // Locked: the files are unreadable, and the next foreground syncs anyway.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        guard let token = Keychain.get("github-token") else {
            status = "Sync is off: no GitHub token on this phone"
            return
        }
        syncing = true
        defer { syncing = false }
        let jevKey = Keychain.get("typesafe-api-key")
        let allowed = allowed
        let sync = TreeSync(repo: GitHubRepo(repository: Self.repository, token: token), mirror: mirror) { items in
            // The position log is private and no secret: it never goes to the guard's Jev check.
            await NoteGuard.held(items.filter { $0.path != PlaceLine.logPath }, jevKey: jevKey, allowed: allowed)
        }
        do {
            let report = try await sync.run()
            lastSync = Date()
            held = report.held
            status = report.conflicts.isEmpty ? "" : "Kept both versions: \(report.conflicts.joined(separator: ", "))"
        } catch {
            status = "\(error)"
        }
        refresh()
    }

    /// Uses the short time iOS grants, so a note reaches GitHub without reopening the app.
    func syncBeforeSuspend() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task {
            await finish(inBackground: true)
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
