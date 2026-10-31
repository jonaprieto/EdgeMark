import XCTest
@testable import EdgePhoneSync

final class ThreeWayMergeTests: XCTestCase {
    func testOneSidedEditsWin() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\n", mine: "a\n", theirs: "b\n"), "b\n")
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\n", mine: "b\n", theirs: "a\n"), "b\n")
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\n", mine: "b\n", theirs: "b\n"), "b\n")
    }

    func testEditsOnDifferentLinesMerge() {
        let base = "one\ntwo\nthree\nfour\n"
        XCTAssertEqual(
            ThreeWayMerge.merge(base: base, mine: "ONE\ntwo\nthree\nfour\n", theirs: "one\ntwo\nthree\nFOUR\n"),
            "ONE\ntwo\nthree\nFOUR\n",
        )
    }

    func testTwoAppendsKeepBothLines() {
        XCTAssertEqual(
            ThreeWayMerge.merge(base: "# Day\n\n- a\n", mine: "# Day\n\n- a\n- mine\n", theirs: "# Day\n\n- a\n- theirs\n"),
            "# Day\n\n- a\n- theirs\n- mine\n",
        )
    }

    func testSameInsertionOnBothSidesAppearsOnce() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "a\nb\n", mine: "a\nx\nb\nc\n", theirs: "a\nx\nb\n"), "a\nx\nb\nc\n")
    }

    func testOverlappingEditsRefuse() {
        XCTAssertNil(ThreeWayMerge.merge(base: "a\nb\nc\n", mine: "a\nmine\nc\n", theirs: "a\ntheirs\nc\n"))
    }

    func testDeleteAgainstEditRefuses() {
        XCTAssertNil(ThreeWayMerge.merge(base: "a\nb\nc\n", mine: "a\nc\n", theirs: "a\nB\nc\n"))
    }

    func testInsertionInsideRemovedRangeRefuses() {
        XCTAssertNil(ThreeWayMerge.merge(base: "a\nb\nc\nd\n", mine: "a\nd\n", theirs: "a\nb\nnew\nc\nd\n"))
    }

    func testUnionLinesUpHeadingsAndKeepsEveryEntry() {
        XCTAssertEqual(
            ThreeWayMerge.union(mine: "# D\n\n## Meals\n\n- b\n\n## Todos\n\n- [ ] c\n", theirs: "# D\n\n## Meals\n\n- a\n"),
            "# D\n\n## Meals\n\n- a\n- b\n\n## Todos\n\n- [ ] c\n",
        )
    }

    func testEmptyBaseKeepsBothNewFiles() {
        XCTAssertEqual(ThreeWayMerge.merge(base: "", mine: "mine\n", theirs: "theirs\n"), "theirs\nmine\n")
    }
}
