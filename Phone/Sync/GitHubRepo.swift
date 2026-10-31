import Foundation

/// The Git Data API, for iOS where git cannot run. Blob, tree and commit stay unreferenced until
/// `moveHead`, which GitHub refuses unless it fast-forwards.
public struct GitHubRepo: Sendable {
    public static let branch = "main"
    public let repository: String
    let token: String
    let session: URLSession

    /// `repository` is "owner/name".
    public init(repository: String, token: String, session: URLSession = .shared) {
        self.repository = repository
        self.token = token
        self.session = session
    }

    func head() async throws -> (commit: String, tree: String) {
        let ref = try await json("GET", "ref/heads/\(Self.branch)")
        guard let commit = (ref["object"] as? [String: Any])?["sha"] as? String else { throw unreadable() }
        let body = try await json("GET", "commits/\(commit)")
        guard let tree = (body["tree"] as? [String: Any])?["sha"] as? String else { throw unreadable() }
        return (commit, tree)
    }

    /// Path to blob SHA of every file in the tree.
    func tree(_ sha: String) async throws -> [String: String] {
        let body = try await json("GET", "trees/\(sha)?recursive=1")
        guard body["truncated"] as? Bool != true else { throw SyncError.truncatedTree }
        guard let entries = body["tree"] as? [[String: Any]] else { throw unreadable() }
        var out: [String: String] = [:]
        for entry in entries where entry["type"] as? String == "blob" && entry["mode"] as? String != "120000" {
            if let path = entry["path"] as? String, let blob = entry["sha"] as? String { out[path] = blob }
        }
        return out
    }

    func blob(_ sha: String) async throws -> Data {
        let (data, status) = try await send("GET", "blobs/\(sha)", accept: "application/vnd.github.raw+json")
        guard status == 200 else { throw failure(data, status) }
        return data
    }

    /// Creates a commit on top of `parent` holding `files`. Moves nothing yet.
    func commit(files: [String: Data], parent: String, baseTree: String, message: String) async throws -> (commit: String, blobs: [String: String]) {
        var blobs: [String: String] = [:]
        var entries: [[String: Any]] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let made = try await json("POST", "blobs", body: ["content": data.base64EncodedString(), "encoding": "base64"], expect: 201)
            guard let sha = made["sha"] as? String else { throw unreadable() }
            blobs[path] = sha
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": sha])
        }
        let tree = try await json("POST", "trees", body: ["base_tree": baseTree, "tree": entries], expect: 201)
        guard let treeSHA = tree["sha"] as? String else { throw unreadable() }
        let commit = try await json("POST", "commits", body: ["message": message, "tree": treeSHA, "parents": [parent]], expect: 201)
        guard let commitSHA = commit["sha"] as? String else { throw unreadable() }
        return (commitSHA, blobs)
    }

    /// False when `sha` does not fast-forward the branch: another device pushed first.
    func moveHead(to sha: String) async throws -> Bool {
        let (data, status) = try await send("PATCH", "refs/heads/\(Self.branch)", body: ["sha": sha, "force": false])
        if status == 422 { return false }
        guard status == 200 else { throw failure(data, status) }
        return true
    }

    // MARK: REST

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, accept: String = "application/vnd.github+json") async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/git/\(path)")!, timeoutInterval: 30)
        r.httpMethod = method
        // GitHub marks responses cacheable for a minute; a cached ref would carry a stale head.
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: r)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func json(_ method: String, _ path: String, body: [String: Any]? = nil, expect: Int = 200) async throws -> [String: Any] {
        let (data, status) = try await send(method, path, body: body)
        guard status == expect else { throw failure(data, status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw unreadable() }
        return object
    }

    private func failure(_ data: Data, _ status: Int) -> SyncError {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
        return .github(status: status, message: message ?? "")
    }

    private func unreadable() -> SyncError {
        .github(status: 200, message: "unreadable response")
    }
}
