import Foundation

/// A color theme both apps can wear: Dracula and the four Catppuccin flavors. Colors are
/// 0xRRGGBB values from draculatheme.com/spec and catppuccin/palette, so the Mac and the
/// iPhone each turn them into their own color types.
public nonisolated enum ColorTheme: String, CaseIterable, Sendable {
    case dracula, latte, frappe, macchiato, mocha

    public struct Palette: Equatable, Sendable {
        public let background, surface, text, muted, accent, link: UInt32
        public let comment, string, number, keyword, type, function: UInt32
    }

    public var name: String {
        switch self {
        case .dracula: "Dracula"
        case .latte: "Catppuccin Latte"
        case .frappe: "Catppuccin Frappé"
        case .macchiato: "Catppuccin Macchiato"
        case .mocha: "Catppuccin Mocha"
        }
    }

    /// Latte is the one light theme.
    public var isDark: Bool {
        self != .latte
    }

    public var palette: Palette {
        switch self {
        case .dracula:
            Palette(background: 0x282A36, surface: 0x44475A, text: 0xF8F8F2, muted: 0x6272A4, accent: 0xBD93F9, link: 0x8BE9FD,
                    comment: 0x6272A4, string: 0xF1FA8C, number: 0xBD93F9, keyword: 0xFF79C6, type: 0x8BE9FD, function: 0x50FA7B)
        case .latte:
            Palette(background: 0xEFF1F5, surface: 0xCCD0DA, text: 0x4C4F69, muted: 0x6C6F85, accent: 0x8839EF, link: 0x1E66F5,
                    comment: 0x8C8FA1, string: 0x40A02B, number: 0xFE640B, keyword: 0x8839EF, type: 0xDF8E1D, function: 0x1E66F5)
        case .frappe:
            Palette(background: 0x303446, surface: 0x414559, text: 0xC6D0F5, muted: 0xA5ADCE, accent: 0xCA9EE6, link: 0x8CAAEE,
                    comment: 0x838BA7, string: 0xA6D189, number: 0xEF9F76, keyword: 0xCA9EE6, type: 0xE5C890, function: 0x8CAAEE)
        case .macchiato:
            Palette(background: 0x24273A, surface: 0x363A4F, text: 0xCAD3F5, muted: 0xA5ADCB, accent: 0xC6A0F6, link: 0x8AADF4,
                    comment: 0x8087A2, string: 0xA6DA95, number: 0xF5A97F, keyword: 0xC6A0F6, type: 0xEED49F, function: 0x8AADF4)
        case .mocha:
            Palette(background: 0x1E1E2E, surface: 0x313244, text: 0xCDD6F4, muted: 0xA6ADC8, accent: 0xCBA6F7, link: 0x89B4FA,
                    comment: 0x7F849C, string: 0xA6E3A1, number: 0xFAB387, keyword: 0xCBA6F7, type: 0xF9E2AF, function: 0x89B4FA)
        }
    }

    /// Red, green and blue of `hex`, each from 0 to 1.
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
