import EdgeCrypto
import EdgeJournalLogic
import EdgePhoneSupport
import EdgePhoneSync
import EdgeStorageLogic
import EdgeSync
import Foundation
import UIKit
import WidgetKit

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
    /// The last sync could not run or failed; `status` says why.
    private(set) var syncFailed = false
    /// The last write to a note failed. Kept apart from `status`, which a sync overwrites.
    private(set) var saveError: String?
    private(set) var places: [PlaceLine] = []
    let calendars = Calendars()
    /// Edited since it was last finished. Finishing records the position once.
    private var unfinished: String?
    private var lastSnapshot: WidgetSnapshot?
    /// Bumped when files changed under the views, which then read them again.
    private(set) var revision = 0
    /// The note open in the editor. Sync waits for it, so a pull cannot race the typing.
    var editing: String?

    /// All that iOS will ring, soonest first.
    private(set) var reminders: [Reminder] = []
    /// iOS refused some of the todos waiting to ring.
    private(set) var notificationsOff = false
    private var lastReminders: [Todo]?
    private var scheduling: Task<Void, Never>?

    private(set) var gists: [Gist] = []
    private(set) var gistError: String?
    private(set) var refreshingGists = false

    private let mirror: NotesMirror?
    private let gistCache: NotesMirror?
    private let position = PositionLog()
    private var allowed: Set<String> {
        didSet { UserDefaults.standard.set(Array(allowed), forKey: "sync.allowedHashes") }
    }

    private init() {
        // Keys exported to scripts/phone.sh reach the app once, at launch; the Keychain keeps them.
        let environment = ProcessInfo.processInfo.environment
        for (name, account) in ["EDGEMARK_GITHUB_TOKEN": "github-token", "TYPESAFE_API_KEY": "typesafe-api-key", "OPENAI_API_KEY": "openai-api-key"] {
            if let value = environment[name], !value.isEmpty { Keychain.set(account, value) }
        }
        if let secret = environment["EDGEMARK_AGE_IDENTITY"], !secret.isEmpty { AgeVault.store(secret) }
        allowed = Set(UserDefaults.standard.stringArray(forKey: "sync.allowedHashes") ?? [])
        let support = URL.applicationSupportDirectory
        do {
            mirror = try NotesMirror(root: support.appendingPathComponent("notes"), baseURL: support.appendingPathComponent("sync-base.json"))
        } catch {
            mirror = nil
            status = "\(error)"
        }
        // Out of the notes mirror, so sync can never upload it.
        gistCache = try? NotesMirror(root: support.appendingPathComponent("gists"), baseURL: support.appendingPathComponent("gists-unused.json"))
        if let gistCache { gists = GistLibrary(token: "", cache: gistCache).cached() }
        refresh()
    }

    /// `2.17.0 (dca22ca)`: the version and the commit `scripts/phone.sh` built.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let number = info?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info?["EdgeMarkCommit"] as? String ?? "?"
        return "\(number) (\(commit))"
    }

    var openAIKey: String? {
        Keychain.get("openai-api-key")
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
        // Locked, every file reads as empty, which would cancel the reminders.
        guard UIApplication.shared.isProtectedDataAvailable, let mirror, let paths = try? mirror.paths() else { return }
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
        updateReminders()
    }

    /// Hands iOS the todos still to ring and reads back all that is pending. A sync can add or
    /// remove any of them, so this follows every refresh. One run at a time, so an older list
    /// cannot land after a newer one.
    private func updateReminders() {
        let now = Date()
        let coming = Array(todos.filter { ($0.ringsAt() ?? .distantPast) > now }.prefix(Reminders.limit))
        let changed = coming != lastReminders
        lastReminders = coming
        let paths = Set(notes.map(\.path))
        let previous = scheduling
        scheduling = Task {
            await previous?.value
            if changed {
                notificationsOff = await !Reminders.schedule(coming)
                // Try again on the next refresh rather than let a reminder go silent.
                if notificationsOff { lastReminders = nil }
            }
            await Reminders.cancelNotes { !paths.contains($0) }
            reminders = await Reminders.pending()
            updateWidgets()
        }
    }

    func hasReminder(on path: String) -> Bool {
        reminders.contains { $0.path == path && $0.raw == nil }
    }

    /// The task whose line reads `raw` in the file as it stands now.
    func todo(at path: String, raw: String) -> Todo? {
        TodoScan.todos(in: text(of: path), path: path).first { $0.raw == raw }
    }

    /// Hands the widgets the next meetings, reminders and todos, only when they changed: iOS rations reloads.
    private func updateWidgets() {
        let upcoming = meetings.compactMap { row -> WidgetSnapshot.Event? in
            guard let start = row.start else { return nil }
            let end = calendars.ends[Meeting.Event(name: row.name, start: start, place: row.place)] ?? start.addingTimeInterval(3600)
            return WidgetSnapshot.Event(title: row.name, start: start, end: end)
        }
        let open = todos
        let ringing = reminders.prefix(8).map { WidgetSnapshot.Event(title: $0.title, start: $0.date, end: $0.date) }
        var snapshot = WidgetSnapshot(date: lastSnapshot?.date ?? Date(), events: Array(upcoming.prefix(3)), todos: open.prefix(5).map(\.text), openTodos: open.count, reminders: ringing)
        guard snapshot != lastSnapshot else { return }
        snapshot.date = Date()
        lastSnapshot = snapshot
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
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
        save(Data(text.utf8), toFile: path)
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
    func create(title: String, folder: String, body: String = "") -> String? {
        guard let mirror else { return nil }
        let stem = (folder.isEmpty ? "" : folder + "/") + NoteText.sanitizeForFilename(title)
        var path = stem + ".md"
        var n = 2
        while mirror.exists(path) {
            path = "\(stem)-\(n).md"
            n += 1
        }
        save("# \(title)\n\n\(body)", to: path)
        refresh()
        return path
    }

    /// Searches the title, the file names and the text of every file.
    func gist(_ gist: Gist, matches query: String) -> Bool {
        gist.title.localizedCaseInsensitiveContains(query) || gist.files.contains {
            $0.localizedCaseInsensitiveContains(query) || gistText(of: "\(gist.id)/\($0)").localizedCaseInsensitiveContains(query)
        }
    }

    func gistText(of path: String) -> String {
        gistCache.flatMap { try? $0.read(path) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Lists your gists and downloads what changed. Runs on its own, so leaving the Gists screen
    /// does not cut it off, and the cached copy stays readable offline.
    func refreshGists() async {
        guard !refreshingGists, let gistCache else { return }
        guard let token = Keychain.get("github-token") else {
            gistError = "No GitHub token on this phone"
            return
        }
        refreshingGists = true
        await Task {
            defer { refreshingGists = false }
            do {
                try await GistLibrary(token: token, cache: gistCache).refresh { listed in
                    await MainActor.run { self.gists = listed }
                }
                gistError = nil
            } catch {
                gistError = "\(error)"
            }
        }.value
    }

    /// Open todos across every note, soonest first.
    var todos: [Todo] {
        let open = notes.flatMap { TodoScan.todos(in: $0.text, path: $0.path) }.filter { !$0.done }
        return TodoScan.sorted(open, today: Journal.day(Date()))
    }

    @discardableResult func toggle(_ todo: Todo) -> Task<Void, Never> {
        write(TodoScan.toggled(todo, in: text(of: todo.path)), to: todo.path)
    }

    @discardableResult func setDue(_ due: String?, on todo: Todo) -> Task<Void, Never> {
        write(TodoScan.settingDue(due, on: todo, in: text(of: todo.path)), to: todo.path)
    }

    /// Nil means the line changed since the scan: reread instead of writing over it.
    @discardableResult private func write(_ text: String?, to path: String) -> Task<Void, Never> {
        if let text { save(text, to: path) }
        refresh()
        return Task { await sync() }
    }

    /// One kind of entry from every day file, newest first, with where each was written.
    func entries(_ kind: Journal.Kind) -> [(entry: Journal.Entry, place: PlaceLine?)] {
        notes.filter { $0.folder == Journal.folder }
            .flatMap { Journal.entries(in: $0.text, path: $0.path) }
            .filter { $0.kind == kind }
            .sorted { ($0.day, $0.time) > ($1.day, $1.time) }
            .map { ($0, PlaceLine.place(of: $0, in: places)) }
    }

    /// Takes a line out of its day file, with its photos, on every device.
    func remove(_ entry: Journal.Entry) {
        let folder = (entry.path as NSString).deletingLastPathComponent
        let remaining = Journal.removing(entry, from: text(of: entry.path))
        if remaining != nil {
            for image in entry.images {
                try? mirror?.delete("\(folder)/\(image)")
            }
        }
        write(remaining, to: entry.path)
    }

    /// Calendar events and meeting notes, soonest first.
    var meetings: [Meeting.Row] {
        let events = calendars.events
        let inFolder = notes.filter { $0.folder == Meeting.folder }.map { (path: $0.path, title: $0.title, time: Meeting.time(inNote: $0.text), place: Meeting.place(inNote: $0.text)) }
        return Meeting.rows(events: events, notes: inFolder, today: Journal.day(Date()))
    }

    /// A meeting added by hand: a note with its day and hour, shown with the calendar's events.
    func addMeeting(name: String, on date: Date, hasTime: Bool, place: String, note: String) {
        let title = Meeting.title(day: Journal.day(date), name: name.trimmingCharacters(in: .whitespaces))
        _ = create(title: title, folder: Meeting.folder, body: Meeting.body(time: hasTime ? Journal.time(date) : nil, place: place, note: note))
        Task { await sync() }
    }

    /// The note of a meeting, created on first use.
    func notePath(for row: Meeting.Row) -> String? {
        row.path ?? create(title: row.title, folder: Meeting.folder, body: Meeting.template)
    }

    /// Adds an idea to the next meeting's note. False when no meeting is coming.
    func addMeetingIdea(_ text: String) -> Bool {
        guard let path = nextMeetingPath else { return false }
        let line = "- " + text.split(whereSeparator: \.isNewline).joined(separator: " ")
        unfinished = path
        save(Journal.appending(line, under: .idea, to: self.text(of: path)), to: path)
        refresh()
        Task { await finish() }
        return true
    }

    /// Saves a photo where the Mac keeps a note's images, and returns the Markdown that shows it.
    /// Longest side 2048 px: a full camera photo would sit in the repository's history for good.
    func attach(_ photo: UIImage, to path: String) -> String? {
        let scale = min(1, 2048 / max(photo.size.width, photo.size.height, 1))
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.75) { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }
        let stem = NoteText.safeAssetStem(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let name = ".\(stem)/IMG-\(UUID().uuidString).jpg"
        let folder = (path as NSString).deletingLastPathComponent
        save(jpeg, toFile: folder.isEmpty ? name : "\(folder)/\(name)")
        return saveError == nil ? "![](\(name))" : nil
    }

    private func save(_ data: Data, toFile path: String) {
        do {
            try mirror?.write(data, to: path)
            saveError = nil
        } catch {
            saveError = "Could not save \(path): \(error)"
        }
    }

    /// The file behind an image path written in the note at `path`.
    func imageURL(_ image: String, in path: String) -> URL? {
        folderURL(of: path)?.appendingPathComponent(image)
    }

    /// The note an idea for the next meeting goes to, created on first use.
    var nextMeetingPath: String? {
        meetings.first.flatMap(notePath(for:))
    }

    /// Deletes a note and its images from every device. It stays in the repository's history.
    func delete(_ path: String) {
        guard let mirror else { return }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = (path as NSString).deletingLastPathComponent
        let images = (folder.isEmpty ? "" : folder + "/") + ".\(NoteText.safeAssetStem(name))/"
        do {
            for file in try mirror.paths() where file == path || file.hasPrefix(images) {
                try mirror.delete(file)
            }
        } catch {
            saveError = "Could not delete \(path): \(error)"
        }
        refresh()
        Task { await sync() }
    }

    /// Makes sure today's file exists, for writing in it directly.
    func startToday() {
        let now = Date()
        let path = Journal.path(for: now)
        guard mirror?.exists(path) == false else { return }
        save(Journal.emptyDay(for: now), to: path)
        refresh()
    }

    /// Adds last night to today's file. It records no position: nobody finishes a note asleep.
    func capture(_ sleep: Sleep) {
        let now = Date()
        let path = Journal.path(for: now)
        let existing = mirror?.exists(path) == true ? text(of: path) : Journal.emptyDay(for: now)
        save(Journal.appending(sleep.line, under: .sleep, to: existing), to: path)
        refresh()
        Task { await sync() }
    }

    /// One night per day file, newest first, from the last seven days.
    private var recentNights: [Sleep] {
        let week = (0 ..< 7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }.map { Journal.path(for: $0) }
        return week.compactMap { path in note(path).flatMap { Sleep.entries(in: $0.text).first } }
    }

    /// `Last night 8h · 7 days 7h20`, nil before anything is logged.
    var sleepSummary: String? {
        let nights = recentNights
        guard let average = Sleep.average(nights) else { return nil }
        let today = note(Journal.path(for: Date())).flatMap { Sleep.entries(in: $0.text).first }
        let mean = nights.count > 1 ? "\(nights.count)-day average \(Sleep.duration(average))" : nil
        let parts = [today.map { "Last night \(Sleep.duration($0.minutes))" }, mean].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Adds a line to today's file. Needs no network; sync carries it when it can.
    func capture(_ text: String, kind: Journal.Kind, due: String?) {
        let now = Date()
        let path = Journal.path(for: now)
        let existing = mirror?.exists(path) == true ? self.text(of: path) : Journal.emptyDay(for: now)
        let entry = Journal.entry(text, kind: kind, at: now, due: due)
        save(Journal.appending(entry, under: kind, to: existing), to: path)
        unfinished = path
        refresh()
        Task { await finish() }
    }

    /// The Mac's public age key, set by `scripts/phone.sh`. Writing needs only this, so a private
    /// note is sealed with no Face ID; reading it back takes the key behind Face ID.
    private var ageRecipient: AgeRecipient? {
        (Bundle.main.object(forInfoDictionaryKey: "EdgeMarkAgeRecipient") as? String).flatMap(AgeRecipient.init(bech32:))
    }

    var canEncrypt: Bool {
        ageRecipient != nil
    }

    /// Seals `text` into the age note at `path`, as the Mac reads it.
    func savePrivate(_ text: String, to path: String) {
        guard let ageRecipient else { return }
        save(Data(Age.encrypt(Data(text.utf8), to: ageRecipient).utf8), toFile: path)
        refresh()
        Task { await sync() }
    }

    /// A new encrypted note. It records no position, so nothing about it stays in the clear
    /// beyond its file name.
    func createPrivate(title: String, folder: String, text: String) -> String? {
        guard canEncrypt, let mirror else { return nil }
        let stem = (folder.isEmpty ? "" : folder + "/") + NoteText.sanitizeForFilename(title)
        var path = stem + ".md.age"
        var n = 2
        while mirror.exists(path) {
            path = "\(stem)-\(n).md.age"
            n += 1
        }
        savePrivate("# \(title)\n\n\(text)", to: path)
        return saveError == nil ? path : nil
    }

    /// A private capture: its own encrypted note, since the day file is plain text.
    func capturePrivately(_ text: String, kind: String) -> Bool {
        let now = Date()
        return createPrivate(title: "\(Journal.day(now)) \(Journal.time(now)) \(kind)", folder: Journal.folder, text: text) != nil
    }

    /// Private captures. Only what their file names say can be read without Face ID.
    var privateCaptures: [Journal.PrivateEntry] {
        notes.compactMap { Journal.privateEntry(path: $0.path) }
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
            syncFailed = true
            return
        }
        syncing = true
        defer { syncing = false }
        let jevKey = Keychain.get("typesafe-api-key")
        let allowed = allowed
        let sync = TreeSync(repo: GitHubRepo(repository: Self.repository, token: token), mirror: mirror) { items in
            // The position log is private and no secret: it never goes to the guard's Jev check.
            // Ciphertext has nothing to check either.
            await NoteGuard.held(items.filter { $0.path != PlaceLine.logPath && !$0.path.hasSuffix(".age") }, jevKey: jevKey, allowed: allowed)
        }
        do {
            let report = try await sync.run()
            lastSync = Date()
            syncFailed = false
            held = report.held
            status = Self.summary(of: report)
        } catch {
            status = "\(error)"
            syncFailed = true
        }
        refresh()
    }

    /// What a finished sync must tell you. A held note has not left the phone, whatever else went well.
    private static func summary(of report: SyncReport) -> String {
        var parts: [String] = []
        if !report.held.isEmpty { parts.append("Held on this phone, see Settings: \(report.held.keys.sorted().joined(separator: ", "))") }
        if !report.conflicts.isEmpty { parts.append("Kept both versions: \(report.conflicts.joined(separator: ", "))") }
        return parts.joined(separator: "\n")
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
