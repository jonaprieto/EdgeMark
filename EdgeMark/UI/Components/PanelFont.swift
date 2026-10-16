import AppKit
import SwiftUI

extension Font {
    /// Panel text: the macOS text style, 2 pt larger. The system sizes (10 pt captions,
    /// 13 pt body) read small in the panel, and macOS has no text size for them to follow.
    static func panel(_ style: NSFont.TextStyle) -> Font {
        let font = NSFont.preferredFont(forTextStyle: style)
        return Font(font.withSize(font.pointSize + 2))
    }
}
