import SwiftUI

extension L10n {
    /// Tooltip for `key`, with the shortcut in parentheses when one is set. The suffix is
    /// appended here, never translated, so it follows the user's own binding.
    func tooltip(_ key: String, shortcut: KeyboardShortcut? = nil) -> String {
        let text = self[key]
        guard let shortcut, !shortcut.description.isEmpty else { return text }
        return "\(text) (\(shortcut.description))"
    }
}
