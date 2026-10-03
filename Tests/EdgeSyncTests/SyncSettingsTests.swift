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
    }

    func testPersistsAcrossInstances() {
        let d = freshDefaults()
        let a = SyncSettings(defaults: d)
        a.debounceSeconds = 45
        a.account = "jonaprieto"
        a.enabled = false
        let b = SyncSettings(defaults: d)
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
    }
}
