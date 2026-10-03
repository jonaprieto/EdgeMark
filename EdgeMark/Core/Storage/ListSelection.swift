import Foundation

/// Foundation-only rules for selecting rows in the note list, shared by the app and the
/// SPM test target. Row identity is generic so tests can use plain integers.
nonisolated enum ListSelection {
    /// What a left click on a row does.
    enum ClickAction: Equatable {
        /// Flip the row in or out of the selection and make it the anchor.
        case toggle
        /// Select the range from the anchor to the row.
        case extend
        /// Replace the selection with the row (double-click opens it).
        case select
        /// Select the row and open it.
        case open
    }

    /// Decide what a click does. A click on the leading icon, or on any row while a
    /// selection exists in single-click mode, toggles instead of opening, so a selection
    /// can be built without modifier keys. Shift always extends from the anchor.
    static func clickAction(
        onIcon: Bool,
        isShift: Bool,
        isCommand: Bool,
        hasSelection: Bool,
        openOnSingleClick: Bool,
    ) -> ClickAction {
        if isShift {
            return .extend
        }
        if isCommand || onIcon {
            return .toggle
        }
        guard openOnSingleClick else { return .select }
        return hasSelection ? .toggle : .open
    }

    /// Every row from `anchor` to `item` inclusive, in either direction. Nil when either
    /// end is not in `order`.
    static func range<ID: Hashable>(from anchor: ID?, to item: ID, in order: [ID]) -> Set<ID>? {
        guard let anchor,
              let a = order.firstIndex(of: anchor),
              let b = order.firstIndex(of: item)
        else { return nil }
        return Set(order[min(a, b) ... max(a, b)])
    }

    /// Index one row up (negative `direction`) or down from `index`, clamped to the list.
    /// With no current row it lands on the first row going down, the last going up.
    /// Nil for an empty list.
    static func step(from index: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return direction > 0 ? 0 : count - 1 }
        return max(0, min(count - 1, index + direction))
    }

    /// Selection for Select All: every visible row.
    static func all<ID: Hashable>(_ order: [ID]) -> Set<ID> {
        Set(order)
    }
}
