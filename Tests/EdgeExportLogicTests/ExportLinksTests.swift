import XCTest
@testable import EdgeExportLogic

final class ExportLinksTests: XCTestCase {
    func testRewritesOwnImageLinks() {
        let md = "# Trip\n\n![](.Trip/IMG-AB12-CD34.png)\ntext\n![](.Trip/IMG-EF56.jpg)\n"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip", exportedStem: "trip-export")
        XCTAssertEqual(
            r.text,
            "# Trip\n\n![](trip-export-images/IMG-AB12-CD34.png)\ntext\n![](trip-export-images/IMG-EF56.jpg)\n",
        )
        XCTAssertEqual(r.imageNames, ["IMG-AB12-CD34.png", "IMG-EF56.jpg"])
    }

    func testRepeatedImageListedOnce() {
        let md = "![](.Trip/IMG-1.png) ![](.Trip/IMG-1.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip", exportedStem: "Trip")
        XCTAssertEqual(r.text, "![](Trip-images/IMG-1.png) ![](Trip-images/IMG-1.png)")
        XCTAssertEqual(r.imageNames, ["IMG-1.png"])
    }

    func testNonImageLinksUntouched() {
        let md = "[site](https://example.com) [file](.Trip/IMG-1.png) ![remote](https://x.y/IMG-1.png) ![](.Trip/photo.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip", exportedStem: "out")
        XCTAssertEqual(r.text, md)
        XCTAssertEqual(r.imageNames, [])
    }

    func testAltTextPreserved() {
        let md = "![A view of the lake](.Trip/IMG-9.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip", exportedStem: "out")
        XCTAssertEqual(r.text, "![A view of the lake](out-images/IMG-9.png)")
        XCTAssertEqual(r.imageNames, ["IMG-9.png"])
    }

    func testStemsWithSpaces() {
        let md = "![](<.My Trip/IMG-9.png>) ![](.My Trip/IMG-8.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "My Trip", exportedStem: "My Export")
        XCTAssertEqual(r.text, "![](<My Export-images/IMG-9.png>) ![](<My Export-images/IMG-8.png>)")
        XCTAssertEqual(r.imageNames, ["IMG-9.png", "IMG-8.png"])
    }

    func testStemIsMatchedLiterally() {
        let md = "![](.Trip.v2/IMG-1.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip.v2", exportedStem: "out")
        XCTAssertEqual(r.text, "![](out-images/IMG-1.png)")
        let other = ExportLinks.rewriteImageLinks(in: "![](.TripXv2/IMG-1.png)", stem: "Trip.v2", exportedStem: "out")
        XCTAssertEqual(other.imageNames, [])
    }

    func testOtherStemUntouched() {
        let md = "![](.Other-Note/IMG-1.png) ![](.Trip-2/IMG-2.png)"
        let r = ExportLinks.rewriteImageLinks(in: md, stem: "Trip", exportedStem: "out")
        XCTAssertEqual(r.text, md)
        XCTAssertEqual(r.imageNames, [])
    }

    func testEmptyNote() {
        let r = ExportLinks.rewriteImageLinks(in: "", stem: "Trip", exportedStem: "out")
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.imageNames, [])
    }
}
