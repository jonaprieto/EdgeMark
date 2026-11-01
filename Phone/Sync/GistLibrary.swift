import Foundation

/// One gist in the phone's copy.
public struct Gist: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: String
    public let isPublic: Bool
    public let files: [String]
}

/// A read-only copy of your gists. On the Mac each gist is a git clone; here the gist API fills
/// a cache of its own, apart from the notes mirror, so nothing in it can ever be uploaded.
/// Gists are edited on the Mac: a change to a public one is visible to everyone at once.
public struct GistLibrary: Sendable {
    static let indexPath = "index.json"

    let token: String
    let cache: NotesMirror
    let session: URLSession

    public init(token: String, cache: NotesMirror, session: URLSession = .shared) {
        self.token = token
        self.cache = cache
        self.session = session
    }

    /// What the last refresh saved, newest first. Works offline.
    public func cached() -> [Gist] {
        (try? cache.read(Self.indexPath)).flatMap { try? JSONDecoder().decode([Gist].self, from: $0) } ?? []
    }

    /// Lists every gist and downloads the ones that changed. The index is written last, so a
    /// refresh cut short picks up where it stopped.
    public func refresh() async throws -> [Gist] {
        var listed: [[String: Any]] = []
        var page = 1
        while true {
            let batch = try await array("gists?per_page=100&page=\(page)")
            listed += batch
            if batch.count < 100 { break }
            page += 1
        }

        let known = Dictionary(cached().map { ($0.id, $0) }) { first, _ in first }
        var gists: [Gist] = []
        for item in listed {
            guard let id = item["id"] as? String, let updated = item["updated_at"] as? String else { continue }
            let files = (item["files"] as? [String: Any] ?? [:]).keys.sorted()
            let description = (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if known[id]?.updatedAt != updated { try await download(id) }
            gists.append(Gist(id: id, title: description.isEmpty ? files.first ?? id : description, updatedAt: updated, isPublic: item["public"] as? Bool ?? false, files: files))
        }
        for gone in Set(known.keys).subtracting(gists.map(\.id)) {
            try? cache.remove(gone)
        }
        gists.sort { $0.updatedAt > $1.updatedAt }
        try cache.write(JSONEncoder().encode(gists), to: Self.indexPath)
        return gists
    }

    private func download(_ id: String) async throws {
        try? cache.remove(id)
        let (data, status) = try await get("https://api.github.com/gists/\(id)")
        guard status == 200 else { throw failure(data, status) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = json["files"] as? [String: [String: Any]] else { throw SyncError.github(status: 200, message: "unreadable response") }
        for (name, file) in files {
            var body = (file["content"] as? String).map { Data($0.utf8) }
            // The API cuts content at 1 MB; the raw URL has it all.
            if file["truncated"] as? Bool == true || body == nil, let raw = file["raw_url"] as? String {
                body = try await get(raw).0
            }
            // A name the mirror refuses is skipped, not fatal: the rest of the gist still shows.
            if let body { try? cache.write(body, to: "\(id)/\(name)") }
        }
    }

    private func array(_ path: String) async throws -> [[String: Any]] {
        let (data, status) = try await get("https://api.github.com/\(path)")
        guard status == 200 else { throw failure(data, status) }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SyncError.github(status: 200, message: "unreadable response")
        }
        return list
    }

    private func get(_ url: String) async throws -> (Data, Int) {
        guard let url = URL(string: url) else { throw SyncError.badPath(url) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func failure(_ data: Data, _ status: Int) -> SyncError {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
        return .github(status: status, message: message ?? "")
    }
}
