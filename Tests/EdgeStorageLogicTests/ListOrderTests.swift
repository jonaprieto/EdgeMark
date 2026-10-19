import XCTest
@testable import EdgeStorageLogic

final class ListOrderTests: XCTestCase {
    private let day: TimeInterval = 86400

    private func sorted(_ rows: [(name: String, date: Date?)], byName: Bool = false, ascending: Bool) -> [String] {
        rows.sorted { ListOrder.precedes($0, $1, byName: byName, ascending: ascending) }.map(\.name)
    }

    /// Gists: a folder (newest file 2 days old) sorts between notes 1 and 3 days old.
    func testFoldersAndNotesInterleaveByDate() {
        let rows: [(name: String, date: Date?)] = [
            ("note-old", Date(timeIntervalSince1970: 1 * day)),
            ("folder", Date(timeIntervalSince1970: 2 * day)),
            ("note-new", Date(timeIntervalSince1970: 3 * day)),
        ]
        XCTAssertEqual(sorted(rows, ascending: false), ["note-new", "folder", "note-old"])
        XCTAssertEqual(sorted(rows, ascending: true), ["note-old", "folder", "note-new"])
    }

    func testMissingDateGoesLastInBothDirections() {
        let rows: [(name: String, date: Date?)] = [("empty", nil), ("a", Date(timeIntervalSince1970: day)), ("b", Date(timeIntervalSince1970: 2 * day))]
        XCTAssertEqual(sorted(rows, ascending: false), ["b", "a", "empty"])
        XCTAssertEqual(sorted(rows, ascending: true), ["a", "b", "empty"])
    }

    func testEqualKeysNeverPrecedeEachOther() {
        let date = Date(timeIntervalSince1970: day)
        XCTAssertFalse(ListOrder.precedes(("a", date), ("b", date), byName: false, ascending: false))
        XCTAssertFalse(ListOrder.precedes(("Notes", nil), ("notes", nil), byName: true, ascending: false))
    }

    func testByNameIgnoresCase() {
        let rows: [(name: String, date: Date?)] = [("beta", nil), ("Alpha", nil), ("gamma", nil)]
        XCTAssertEqual(sorted(rows, byName: true, ascending: true), ["Alpha", "beta", "gamma"])
        XCTAssertEqual(sorted(rows, byName: true, ascending: false), ["gamma", "beta", "Alpha"])
    }
}
