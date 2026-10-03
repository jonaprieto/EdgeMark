import XCTest
@testable import EdgeStorageLogic

final class FileTypeStyleTests: XCTestCase {
    func testKnownLabels() {
        let expected = [
            "rs": "RS", "agda": "AGDA", "lean": "LEAN", "ex": "EX", "exs": "EX", "sol": "SOL", "py": "PY",
            "swift": "SWIFT", "json": "JSON", "txt": "TXT", "sh": "SH", "js": "JS", "ts": "TS", "c": "C",
            "cpp": "CPP", "go": "GO", "hs": "HS", "ml": "ML", "nix": "NIX", "yaml": "YAML", "yml": "YAML",
            "toml": "TOML", "html": "HTML", "css": "CSS",
        ]
        for (ext, label) in expected {
            XCTAssertEqual(FileTypeStyle.style(forExtension: ext).label, label, ext)
            XCTAssertEqual(FileTypeStyle.style(forExtension: ext.uppercased()).label, label, ext)
        }
    }

    func testKnownColoursAreNotNeutralAndDarkEnoughForWhiteText() {
        for ext in ["rs", "agda", "lean", "ex", "sol", "py", "swift", "json", "sh", "js", "ts", "cpp", "go", "hs", "ml", "nix", "yaml", "toml", "html", "css"] {
            let rgb = FileTypeStyle.style(forExtension: ext).rgb
            XCTAssertFalse(rgb == FileTypeStyle.neutral, ext)
            // Relative luminance (sRGB approximation) low enough for white text to read.
            let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
            XCTAssertLessThan(luminance, 0.6, ext)
        }
    }

    func testUnknownExtensionIsGreyAndShort() {
        let style = FileTypeStyle.style(forExtension: "whatever")
        XCTAssertEqual(style.label, "WHAT")
        XCTAssertTrue(style.rgb == FileTypeStyle.neutral)
        XCTAssertEqual(FileTypeStyle.style(forExtension: "zig").label, "ZIG")
        XCTAssertEqual(FileTypeStyle.style(forExtension: "").label, "TXT")
    }
}
