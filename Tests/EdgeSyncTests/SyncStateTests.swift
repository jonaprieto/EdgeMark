import XCTest
@testable import EdgeSync

final class SyncStateTests: XCTestCase {
    func testAggregateWorstWins() {
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(SyncState.aggregate([]), .off)
        XCTAssertEqual(SyncState.aggregate([.idle(lastSync: t1), .idle(lastSync: t2)]), .idle(lastSync: t2))
        XCTAssertEqual(SyncState.aggregate([.idle(lastSync: t1), .syncing]), .syncing)
        XCTAssertEqual(SyncState.aggregate([.syncing, .error("boom")]), .error("boom"))
        XCTAssertEqual(SyncState.aggregate([.error("boom"), .conflict(["a.md"])]), .conflict(["a.md"]))
        XCTAssertEqual(SyncState.aggregate([.off, .idle(lastSync: nil)]), .idle(lastSync: nil))
    }

    func testSummary() {
        XCTAssertEqual(SyncState.off.summary, "Sync off")
        XCTAssertEqual(SyncState.syncing.summary, "Syncing")
        XCTAssertEqual(SyncState.conflict(["a.md", "b.md"]).summary, "Conflict: a.md, b.md")
        XCTAssertEqual(SyncState.error("nope").summary, "Error: nope")
        XCTAssertEqual(SyncState.idle(lastSync: nil).summary, "Not synced yet")
        XCTAssertTrue(SyncState.idle(lastSync: Date()).summary.hasPrefix("Synced "))
    }
}
