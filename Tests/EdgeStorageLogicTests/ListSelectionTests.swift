import XCTest
@testable import EdgeStorageLogic

final class ListSelectionTests: XCTestCase {
    private func action(
        onIcon: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        hasSelection: Bool = false,
        singleClick: Bool = true,
    ) -> ListSelection.ClickAction {
        ListSelection.clickAction(
            onIcon: onIcon,
            isShift: shift,
            isCommand: command,
            hasSelection: hasSelection,
            openOnSingleClick: singleClick,
        )
    }

    // MARK: - Toggle vs open

    func testPlainClickWithoutSelectionOpens() {
        XCTAssertEqual(action(), .open)
    }

    func testPlainClickWithSelectionToggles() {
        XCTAssertEqual(action(hasSelection: true), .toggle)
    }

    func testIconClickTogglesWithOrWithoutSelection() {
        XCTAssertEqual(action(onIcon: true), .toggle)
        XCTAssertEqual(action(onIcon: true, hasSelection: true), .toggle)
        XCTAssertEqual(action(onIcon: true, singleClick: false), .toggle)
    }

    func testCommandClickToggles() {
        XCTAssertEqual(action(command: true), .toggle)
    }

    func testShiftClickExtendsAnywhere() {
        XCTAssertEqual(action(shift: true), .extend)
        XCTAssertEqual(action(onIcon: true, shift: true), .extend)
        XCTAssertEqual(action(shift: true, hasSelection: true, singleClick: false), .extend)
    }

    func testDoubleClickModePlainClickSelects() {
        XCTAssertEqual(action(singleClick: false), .select)
        XCTAssertEqual(action(hasSelection: true, singleClick: false), .select)
    }

    // MARK: - Shift range

    func testRangeDownward() {
        XCTAssertEqual(ListSelection.range(from: 1, to: 3, in: [0, 1, 2, 3, 4]), [1, 2, 3])
    }

    func testRangeUpward() {
        XCTAssertEqual(ListSelection.range(from: 3, to: 1, in: [0, 1, 2, 3, 4]), [1, 2, 3])
    }

    func testRangeOfOneRow() {
        XCTAssertEqual(ListSelection.range(from: 2, to: 2, in: [0, 1, 2]), [2])
    }

    func testRangeWithoutAnchorOrHiddenRowIsNil() {
        XCTAssertNil(ListSelection.range(from: nil, to: 1, in: [0, 1]))
        XCTAssertNil(ListSelection.range(from: 9, to: 1, in: [0, 1]))
        XCTAssertNil(ListSelection.range(from: 0, to: 9, in: [0, 1]))
    }

    // MARK: - Extend by one row

    func testStepMovesOneRow() {
        XCTAssertEqual(ListSelection.step(from: 1, direction: 1, count: 3), 2)
        XCTAssertEqual(ListSelection.step(from: 1, direction: -1, count: 3), 0)
    }

    func testStepClampsAtListEnds() {
        XCTAssertEqual(ListSelection.step(from: 2, direction: 1, count: 3), 2)
        XCTAssertEqual(ListSelection.step(from: 0, direction: -1, count: 3), 0)
    }

    func testStepWithoutCurrentRowLandsOnAnEnd() {
        XCTAssertEqual(ListSelection.step(from: nil, direction: 1, count: 3), 0)
        XCTAssertEqual(ListSelection.step(from: nil, direction: -1, count: 3), 2)
    }

    func testStepInEmptyListIsNil() {
        XCTAssertNil(ListSelection.step(from: nil, direction: 1, count: 0))
        XCTAssertNil(ListSelection.step(from: 0, direction: -1, count: 0))
    }

    // MARK: - Select all

    func testSelectAllTakesEveryRow() {
        XCTAssertEqual(ListSelection.all([3, 1, 2]), [1, 2, 3])
    }

    func testSelectAllInEmptyListIsEmpty() {
        XCTAssertEqual(ListSelection.all([Int]()), [])
    }

    func testOnlyToggleAndRangeMakeAnExplicitSelection() {
        XCTAssertTrue(ListSelection.isExplicit(.toggle))
        XCTAssertTrue(ListSelection.isExplicit(.extend))
        XCTAssertFalse(ListSelection.isExplicit(.select))
        XCTAssertFalse(ListSelection.isExplicit(.open))
        // A plain click on a row selected without intent (no explicit selection) opens it.
        let plain = action(hasSelection: false)
        XCTAssertEqual(plain, .open)
        XCTAssertFalse(ListSelection.isExplicit(plain))
        // Icon and command clicks make the selection explicit; then plain clicks toggle.
        XCTAssertTrue(ListSelection.isExplicit(action(onIcon: true)))
        XCTAssertTrue(ListSelection.isExplicit(action(command: true)))
        XCTAssertTrue(ListSelection.isExplicit(action(hasSelection: true)))
    }
}
