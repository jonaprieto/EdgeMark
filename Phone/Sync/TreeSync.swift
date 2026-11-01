import Foundation

public struct SyncReport: Equatable, Sendable {
    public var pulled = 0
    public var pushed = 0
    /// Conflict copies written this run.
    public var conflicts: [String] = []
    /// Paths kept on the phone, with why.
    public var held: [String: [String]] = [:]
}

/// Two-way sync of the mirror with the branch. No text is ever dropped: edits that cannot merge
/// leave the remote file in place and the local text in a conflict copy.
public struct TreeSync: Sendable {
    public typealias Hold = @Sendable (_ items: [(path: String, text: String)]) async -> [String: [String]]

    /// Rewritten by the Mac on every save, so the phone only ever reads it.
    static let macOnly: Set<String> = [".edgemark/meta.json"]

    let repo: GitHubRepo
    let mirror: NotesMirror
    let hold: Hold
    let now: @Sendable () -> Date

    public init(repo: GitHubRepo, mirror: NotesMirror, hold: @escaping Hold, now: @escaping @Sendable () -> Date = { Date() }) {
        self.repo = repo
        self.mirror = mirror
        self.hold = hold
        self.now = now
    }

    public func run() async throws -> SyncReport {
        for _ in 1 ... 3 {
            if let report = try await round() { return report }
        }
        throw SyncError.busy
    }

    /// One pass, nil when another device pushed first. Files already written stay: the next
    /// pass finds them equal to the remote, or merges them again from the same base.
    private func round() async throws -> SyncReport? {
        var base = mirror.loadBase()
        let head = try await repo.head()
        let local = try mirror.shas()
        if head.commit == base.commit, local == base.blobs { return SyncReport() }
        let remote = try await repo.tree(head.tree)

        var report = SyncReport()
        var uploads: [String: Data] = [:]
        var blobs = base.blobs

        for path in Set(base.blobs.keys).union(remote.keys).union(local.keys).sorted() {
            let (b, l, r) = (base.blobs[path], local[path], remote[path])
            if l == r {
                blobs[path] = r
            } else if l == b || l == nil || Self.macOnly.contains(path) {
                if let r {
                    try mirror.write(try await repo.blob(r), to: path)
                } else {
                    try mirror.remove(path)
                }
                blobs[path] = r
                report.pulled += 1
            } else if r == b || r == nil {
                // Also a file the remote deleted while it was edited here: the edit survives.
                uploads[path] = try mirror.read(path)
            } else if let r {
                try await reconcile(path, ancestor: b, theirs: r, blobs: &blobs, uploads: &uploads, report: &report)
            }
        }

        let items = uploads.compactMap { path, data in String(data: data, encoding: .utf8).map { (path: path, text: $0) } }
        report.held = await hold(items)
        for path in report.held.keys { uploads[path] = nil }

        var commit = head.commit
        if !uploads.isEmpty {
            let stamp = Self.stamp("yyyy-MM-dd HH:mm", now())
            let made = try await repo.commit(files: uploads, parent: head.commit, baseTree: head.tree, message: "notes: phone \(stamp)")
            guard try await repo.moveHead(to: made.commit) else { return nil }
            commit = made.commit
            blobs.merge(made.blobs) { $1 }
            report.pushed = uploads.count
        }
        base.commit = commit
        base.blobs = blobs
        try mirror.saveBase(base)
        return report
    }

    /// Both sides changed `path`.
    private func reconcile(_ path: String, ancestor: String?, theirs r: String, blobs: inout [String: String], uploads: inout [String: Data], report: inout SyncReport) async throws {
        let mine = try mirror.read(path)
        let theirs = try await repo.blob(r)
        var common: Data?
        if let ancestor { common = try await repo.blob(ancestor) }

        if let myText = String(data: mine, encoding: .utf8), let theirText = String(data: theirs, encoding: .utf8),
           let merged = Self.merged(path, base: common.flatMap { String(data: $0, encoding: .utf8) }, mine: myText, theirs: theirText)
        {
            let data = Data(merged.utf8)
            try mirror.write(data, to: path)
            blobs[path] = r
            if merged != theirText { uploads[path] = data }
            return
        }

        let day = Self.stamp("yyyy-MM-dd", now())
        let copy = conflictPath(path, day: day)
        let kept = String(data: mine, encoding: .utf8).map { Data(Self.conflictText($0, day: day).utf8) } ?? mine
        try mirror.write(theirs, to: path)
        try mirror.write(kept, to: copy)
        blobs[path] = r
        uploads[copy] = kept
        report.conflicts.append(copy)
    }

    /// Two files that appeared apart merge only when they are logs of lines. Two notes that happen
    /// to share a name are different notes, so they stay apart in a conflict copy.
    private static func merged(_ path: String, base: String?, mine: String, theirs: String) -> String? {
        // Ciphertext has no lines to merge: a mixed file would decrypt to nothing.
        if path.hasSuffix(".age") { return nil }
        if let base { return ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) }
        guard path.hasPrefix("Journal/") || path == ".edgemark/places.jsonl" else { return nil }
        return ThreeWayMerge.union(mine: mine, theirs: theirs)
    }

    /// `a/Note.md` becomes `a/Note-phone-conflict-2026-10-31.md`, then `...-2.md` if that is taken.
    private func conflictPath(_ path: String, day: String) -> String {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        let dot = name.dropFirst().firstIndex(of: ".") ?? name.endIndex
        let (stem, suffix) = (name[..<dot], name[dot...])
        var candidate = "\(folder)\(stem)-phone-conflict-\(day)\(suffix)"
        var n = 2
        while mirror.exists(candidate) {
            candidate = "\(folder)\(stem)-phone-conflict-\(day)-\(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    /// The title is the first line, so the copy gets its own and the Mac never folds it into the
    /// original. A note that opens with a front matter block keeps its text.
    static func conflictText(_ text: String, day: String) -> String {
        guard !text.hasPrefix("---") else { return text }
        let end = text.firstIndex(of: "\n") ?? text.endIndex
        return text[..<end] + " (phone conflict \(day))" + text[end...]
    }

    private static func stamp(_ format: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}
