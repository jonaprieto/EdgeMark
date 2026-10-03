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
}
