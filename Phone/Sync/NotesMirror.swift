import Foundation

/// What the last sync agreed on: the commit, and the blob SHA of every path at that commit.
public struct SyncBase: Codable, Equatable, Sendable {
    public var commit = ""
    public var blobs: [String: String] = [:]
    /// Paths deleted here and not yet deleted on GitHub. A file merely missing comes back from
    /// the remote, so a deletion has to be on record to go the other way.
    public var deleted: Set<String> = []

    public init() {}

    /// Base files written before `deleted` existed still load, or every note would look new.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commit = try c.decode(String.self, forKey: .commit)
        blobs = try c.decode([String: String].self, forKey: .blobs)
        deleted = try c.decodeIfPresent(Set<String>.self, forKey: .deleted) ?? []
    }
}

/// The phone's copy of the tracked files. iOS keeps it encrypted while the device is locked,
/// and it stays out of device backups: GitHub is the backup.
public struct NotesMirror: Sendable {
    public let root: URL
    let baseURL: URL

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtection]
        #else
            [.atomic]
        #endif
    }

    public init(root: URL, baseURL: URL) throws {
        self.root = root
        self.baseURL = baseURL
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try excluded.setResourceValues(values)
    }

    /// Every file, as a path relative to the root. FileManager gives the relative paths itself:
    /// a root under a symlink, as `/var` and `/tmp` are, would throw off any prefix math.
    public func paths() throws -> [String] {
        let fm = FileManager.default
        return try fm.subpathsOfDirectory(atPath: root.path).filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
    }

    // ponytail: hashes every file each round, fine for tens of notes; cache by mtime if it grows.
    public func shas() throws -> [String: String] {
        var out: [String: String] = [:]
        for path in try paths() { out[path] = GitBlob.sha(try read(path)) }
        return out
    }

    public func exists(_ path: String) -> Bool {
        (try? url(for: path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: url(for: path))
    }

    public func write(_ data: Data, to path: String) throws {
        let target = try url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: Self.writeOptions)
    }

    public func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url(for: path))
    }

    /// Removes a file for good: the next sync deletes it on GitHub too.
    public func delete(_ path: String) throws {
        var base = loadBase()
        base.deleted.insert(path)
        try saveBase(base)
        try remove(path)
    }

    /// Empties the copy and forgets the last sync: for another repository, which must not get
    /// these files as new ones. GitHub keeps them.
    public func clear() throws {
        for path in try paths() {
            try remove(path)
        }
        try saveBase(SyncBase())
    }

    public func modified(_ path: String) -> Date? {
        (try? url(for: path)).flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    }

    public func loadBase() -> SyncBase {
        (try? Data(contentsOf: baseURL)).flatMap { try? JSONDecoder().decode(SyncBase.self, from: $0) } ?? SyncBase()
    }

    public func saveBase(_ base: SyncBase) throws {
        try JSONEncoder().encode(base).write(to: baseURL, options: Self.writeOptions)
    }

    /// Tree paths come from the network, so none may leave the root.
    private func url(for path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(""), !parts.contains(".") else {
            throw SyncError.badPath(path)
        }
        return root.appendingPathComponent(path)
    }
}
