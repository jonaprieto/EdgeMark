import XCTest
@testable import EdgeSync

final class SyncSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "edgesync-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaults() {
        let s = SyncSettings(defaults: freshDefaults())
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.debounceSeconds, 120)
        XCTAssertEqual(s.pullIntervalSeconds, 60)
        XCTAssertEqual(s.commitTemplate, "notes: {date}")
        XCTAssertTrue(s.pushOnQuit)
        XCTAssertTrue(s.syncGists)
        XCTAssertEqual(s.account, "")
        XCTAssertTrue(s.guardEnabled)
        XCTAssertEqual(s.allowedHashes, [])
        XCTAssertEqual(s.ignoredGistIDs, [])
    }

    func testIgnoredGistIDsPersistAsAJSONArray() throws {
        let d = freshDefaults()
        let a = SyncSettings(defaults: d)
        a.ignoredGistIDs = ["b2", "a1"]
        let data = try XCTUnwrap(d.data(forKey: "sync.ignoredGistIDs"))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), ["a1", "b2"])
        XCTAssertEqual(SyncSettings(defaults: d).ignoredGistIDs, ["a1", "b2"])
        a.ignoredGistIDs.remove("a1")
        XCTAssertEqual(SyncSettings(defaults: d).ignoredGistIDs, ["b2"])
    }

    func testPersistsAcrossInstances() {
        let d = freshDefaults()
        let a = SyncSettings(defaults: d)
        a.debounceSeconds = 45
        a.account = "jonaprieto"
        a.enabled = false
        a.guardEnabled = false
        a.allowedHashes = ["abc", "def"]
        let b = SyncSettings(defaults: d)
        XCTAssertFalse(b.guardEnabled)
        XCTAssertEqual(b.allowedHashes, ["abc", "def"])
        XCTAssertEqual(b.debounceSeconds, 45)
        XCTAssertEqual(b.account, "jonaprieto")
        XCTAssertFalse(b.enabled)
    }

    func testRenderCommitMessage() {
        let s = SyncSettings(defaults: freshDefaults())
        let date = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 08:53:20 UTC
        s.commitTemplate = "notes: {date} from {host}"
        let rendered = s.renderCommitMessage(date: date, host: "mbp")
        XCTAssertTrue(rendered.hasPrefix("notes: 2025-10-09 "), rendered)
        XCTAssertTrue(rendered.hasSuffix(" from mbp"), rendered)
        s.commitTemplate = ""
        XCTAssertEqual(s.renderCommitMessage(date: date, host: "mbp").isEmpty, false, "empty template falls back")
        s.commitTemplate = " \n\t"
        XCTAssertTrue(s.renderCommitMessage(date: date, host: "mbp").hasPrefix("notes: 2025-10-09 "), "blank template falls back")
    }
}
