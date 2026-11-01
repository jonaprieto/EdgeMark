import XCTest
@testable import EdgePhoneSync

/// Serves a gist list and the gists behind it, and counts the downloads.
final class FakeGists: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var listing: [[String: Any]] = []
    nonisolated(unsafe) private static var details: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var raw: [String: String] = [:]
    nonisolated(unsafe) private static var downloads = 0

    static func set(listing: [[String: Any]], details: [String: [String: Any]], raw: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        (self.listing, self.details, self.raw, downloads) = (listing, details, raw, 0)
    }

    static var downloaded: Int {
        lock.lock()
        defer { lock.unlock() }
        return downloads
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let url = request.url!
        var body = Data()
        var status = 200
        if url.path == "/gists" {
            body = try! JSONSerialization.data(withJSONObject: Self.listing)
        } else if url.path.hasPrefix("/gists/"), let detail = Self.details[String(url.path.dropFirst(7))] {
            Self.downloads += 1
            body = try! JSONSerialization.data(withJSONObject: detail)
        } else if let text = Self.raw[url.absoluteString] {
            body = Data(text.utf8)
        } else {
            status = 404
        }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class GistLibraryTests: XCTestCase {
    private var dir: URL!
    private var library: GistLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = try NotesMirror(root: dir.appendingPathComponent("gists"), baseURL: dir.appendingPathComponent("unused.json"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGists.self]
        library = GistLibrary(token: "t", cache: cache, session: URLSession(configuration: config))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ id: String, updated: String, description: String? = nil, files: [String] = ["a.md"], isPublic: Bool = false) -> [String: Any] {
        var out: [String: Any] = ["id": id, "updated_at": updated, "public": isPublic, "files": Dictionary(uniqueKeysWithValues: files.map { ($0, [String: Any]()) })]
        if let description { out["description"] = description }
        return out
    }

    private func text(_ path: String) throws -> String {
        try String(decoding: library.cache.read(path), as: UTF8.self)
    }

    func testDownloadsAndSortsNewestFirst() async throws {
        FakeGists.set(
            listing: [item("old", updated: "2026-01-01T00:00:00Z", description: "Old one"), item("new", updated: "2026-02-01T00:00:00Z", isPublic: true)],
            details: ["old": ["files": ["a.md": ["content": "old\n"]]], "new": ["files": ["a.md": ["content": "new\n"]]]],
        )
        let gists = try await library.refresh()
        XCTAssertEqual(gists.map(\.id), ["new", "old"])
        XCTAssertEqual(gists.map(\.title), ["a.md", "Old one"])
        XCTAssertEqual(gists.map(\.isPublic), [true, false])
        XCTAssertEqual(try text("old/a.md"), "old\n")
        XCTAssertEqual(library.cached(), gists)
    }

    func testOnlyChangedGistsDownloadAgain() async throws {
        let listing = [item("g", updated: "1")]
        let details: [String: [String: Any]] = ["g": ["files": ["a.md": ["content": "one\n"]]]]
        FakeGists.set(listing: listing, details: details)
        _ = try await library.refresh()
        XCTAssertEqual(FakeGists.downloaded, 1)

        FakeGists.set(listing: listing, details: details)
        _ = try await library.refresh()
        XCTAssertEqual(FakeGists.downloaded, 0)

        FakeGists.set(listing: [item("g", updated: "2", files: ["b.md"])], details: ["g": ["files": ["b.md": ["content": "two\n"]]]])
        _ = try await library.refresh()
        XCTAssertEqual(try text("g/b.md"), "two\n")
        XCTAssertFalse(library.cache.exists("g/a.md"))
    }

    func testTheListIsThereBeforeTheFilesAndAFailedDownloadRetries() async throws {
        FakeGists.set(listing: [item("g", updated: "1")], details: [:])
        do {
            try await library.refresh()
            XCTFail("expected the download to fail")
        } catch {
            XCTAssertEqual(library.cached().map(\.id), ["g"])
        }
        FakeGists.set(listing: [item("g", updated: "1")], details: ["g": ["files": ["a.md": ["content": "ok"]]]])
        try await library.refresh()
        XCTAssertEqual(try text("g/a.md"), "ok")
    }

    func testListedRunsBeforeAnyDownload() async throws {
        FakeGists.set(listing: [item("g", updated: "1")], details: ["g": ["files": ["a.md": ["content": "ok"]]]])
        try await library.refresh(listed: { gists in
            XCTAssertEqual(gists.map(\.id), ["g"])
            XCTAssertEqual(FakeGists.downloaded, 0)
        })
        XCTAssertEqual(FakeGists.downloaded, 1)
    }

    func testADeletedGistLeavesTheCache() async throws {
        FakeGists.set(listing: [item("g", updated: "1")], details: ["g": ["files": ["a.md": ["content": "x"]]]])
        _ = try await library.refresh()
        FakeGists.set(listing: [], details: [:])
        let gists = try await library.refresh()
        XCTAssertEqual(gists, [])
        XCTAssertFalse(library.cache.exists("g/a.md"))
    }

    func testTruncatedFileComesFromItsRawURL() async throws {
        let raw = "https://gist.githubusercontent.com/raw/a.md"
        FakeGists.set(
            listing: [item("g", updated: "1")],
            details: ["g": ["files": ["a.md": ["content": "cut", "truncated": true, "raw_url": raw]]]],
            raw: [raw: "the whole file\n"],
        )
        _ = try await library.refresh()
        XCTAssertEqual(try text("g/a.md"), "the whole file\n")
    }

    func testAFileNameThatLeavesTheCacheIsSkipped() async throws {
        FakeGists.set(listing: [item("g", updated: "1")], details: ["g": ["files": ["../evil": ["content": "x"], "a.md": ["content": "ok"]]]])
        _ = try await library.refresh()
        XCTAssertEqual(try text("g/a.md"), "ok")
    }
}
