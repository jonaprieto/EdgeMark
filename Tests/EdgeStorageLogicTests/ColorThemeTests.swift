@testable import EdgeStorageLogic
import XCTest

final class ColorThemeTests: XCTestCase {
    func testComponentsSplitTheHex() {
        let c = ColorTheme.components(0xFF8000)
        XCTAssertEqual(c.red, 1)
        XCTAssertEqual(c.green, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.blue, 0)
    }

    /// A mistyped hex shows up as text that cannot be read on its own background.
    func testEveryThemeKeepsTextReadable() {
        func luminance(_ hex: UInt32) -> Double {
            let c = ColorTheme.components(hex)
            func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        for theme in ColorTheme.allCases {
            let p = theme.palette
            let (a, b) = (luminance(p.text), luminance(p.background))
            XCTAssertGreaterThan((max(a, b) + 0.05) / (min(a, b) + 0.05), 7, theme.name)
            XCTAssertEqual(b < 0.2, theme.isDark, theme.name)
        }
    }
}
