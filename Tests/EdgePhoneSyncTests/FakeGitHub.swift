import Foundation
@testable import EdgePhoneSync

/// An in-memory GitHub behind URLProtocol, so `TreeSync` runs through the real `GitHubRepo`.
final class FakeGitHub: URLProtocol {
    struct State {
        var blobs: [String: Data] = [:]
        var trees: [String: [String: String]] = [:]
        var commits: [String: (tree: String, parent: String?, message: String)] = [:]
        var head = ""
        var truncated = false
        var movesToReject = 0
        var writes = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func with<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    static func reset() {
        with { $0 = State() }
    }

    static var repo: GitHubRepo {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHub.self]
        return GitHubRepo(repository: "o/r", token: "t", session: URLSession(configuration: config))
    }

    /// A push from another device: replaces the files named, deletes those mapped to nil.
    @discardableResult
    static func push(_ files: [String: String?], message: String = "mac") -> String {
        with { s in
            var tree = s.commits[s.head].flatMap { s.trees[$0.tree] } ?? [:]
            for (path, text) in files {
                if let text {
                    let data = Data(text.utf8)
                    let sha = GitBlob.sha(data)
                    s.blobs[sha] = data
                    tree[path] = sha
                } else {
                    tree[path] = nil
                }
            }
            let treeSHA = "tree\(s.trees.count)"
            s.trees[treeSHA] = tree
            let commit = "commit\(s.commits.count)"
            s.commits[commit] = (treeSHA, s.head.isEmpty ? nil : s.head, message)
            s.head = commit
            return commit
        }
    }

    /// The text of every file at the head.
    static var files: [String: String] {
        with { s in
            let tree = s.commits[s.head].flatMap { s.trees[$0.tree] } ?? [:]
            return tree.mapValues { String(decoding: s.blobs[$0] ?? Data(), as: UTF8.self) }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.with { Self.answer(request, body: Self.bodyData(of: request), state: &$0) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a body to URLProtocol as a stream.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            out.append(buffer, count: n)
        }
        return out
    }

    private static func encode(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func answer(_ request: URLRequest, body: Data, state s: inout State) -> (Int, Data) {
        let path = request.url!.path.replacingOccurrences(of: "/repos/o/r/git/", with: "")
        let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "ref/heads/main"):
            return (200, encode(["object": ["sha": s.head]]))
        case let ("GET", p) where p.hasPrefix("commits/"):
            let commit = s.commits[String(p.dropFirst("commits/".count))]!
            return (200, encode(["tree": ["sha": commit.tree]]))
        case let ("GET", p) where p.hasPrefix("trees/"):
            let tree = s.trees[String(p.dropFirst("trees/".count))]!
            let entries = tree.map { ["path": $0.key, "mode": "100644", "type": "blob", "sha": $0.value] }
            return (200, encode(["tree": entries, "truncated": s.truncated]))
        case let ("GET", p) where p.hasPrefix("blobs/"):
            return (200, s.blobs[String(p.dropFirst("blobs/".count))]!)
        case ("POST", "blobs"):
            s.writes += 1
            let data = Data(base64Encoded: sent["content"] as! String)!
            let sha = GitBlob.sha(data)
            s.blobs[sha] = data
            return (201, encode(["sha": sha]))
        case ("POST", "trees"):
            s.writes += 1
            var tree = s.trees[sent["base_tree"] as! String]!
            for entry in sent["tree"] as! [[String: Any]] { tree[entry["path"] as! String] = entry["sha"] as? String }
            let sha = "tree\(s.trees.count)"
            s.trees[sha] = tree
            return (201, encode(["sha": sha]))
        case ("POST", "commits"):
            s.writes += 1
            let sha = "commit\(s.commits.count)"
            s.commits[sha] = (sent["tree"] as! String, (sent["parents"] as! [String]).first, sent["message"] as! String)
            return (201, encode(["sha": sha]))
        case ("PATCH", "refs/heads/main"):
            s.writes += 1
            let target = sent["sha"] as! String
            if s.movesToReject > 0 || s.commits[target]?.parent != s.head {
                s.movesToReject = max(0, s.movesToReject - 1)
                return (422, encode(["message": "Update is not a fast forward"]))
            }
            s.head = target
            return (200, encode([:]))
        default:
            return (404, encode(["message": "Not Found"]))
        }
    }
}
