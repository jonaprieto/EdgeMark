import XCTest
@testable import EdgeStorageLogic

final class ImageCleanupTests: XCTestCase {
    private let image = "IMG-4F1C2A3B-0D9E-4A7B-8C6D-112233445566.png"

    func testUnreferencedImageIsReturned() {
        let orphans = ImageCleanup.orphanedImageNames(in: [image], body: "# Note\n\nno images", otherBodies: [])
        XCTAssertEqual(orphans, [image])
    }

    func testReferencedImageIsKept() {
        let body = "# Note\n\n![](.Note/\(image))\n"
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: [image], body: body, otherBodies: []), [])
    }

    func testNonImageFilesAreNeverReturned() {
        let listing = [".DS_Store", "notes.txt", "photo.png", "IMG-.png", "IMG-abc", "img-abc.png", "IMG-abc.png.bak"]
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: listing, body: "", otherBodies: []), [])
    }

    func testImageReferencedByAnotherNoteIsKept() {
        let other = "# Other\n\n![](.Note/\(image))\n"
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: [image], body: "# Note\n", otherBodies: ["# Third\n", other]), [])
    }

    func testRegexSpecialCharactersInNames() {
        // Names with regex metacharacters do not match the IMG pattern and are kept.
        let special = ["IMG-(1).png", "IMG-a+b.png", "IMG-a.b.png", "IMG-[x].jpg", "IMG-a*.png", "IMG-a$.png"]
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: special, body: "", otherBodies: []), [])
        // A reference is matched literally, so a "." in the name does not act as a wildcard.
        let name = "IMG-abc.png"
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: [name], body: "![](.N/IMG-abcxpng)", otherBodies: []), [name])
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: [name], body: "![](.N/IMG-abc.png)", otherBodies: []), [])
    }

    func testEmptyFolder() {
        XCTAssertEqual(ImageCleanup.orphanedImageNames(in: [], body: "anything", otherBodies: ["more"]), [])
    }

    func testOnlyOrphansAreReturnedFromMixedListing() {
        let kept = "IMG-1111.jpg"
        let orphan = "IMG-2222.jpeg"
        let listing = [kept, orphan, "readme.md"]
        let orphans = ImageCleanup.orphanedImageNames(in: listing, body: "![](.N/\(kept))", otherBodies: [])
        XCTAssertEqual(orphans, [orphan])
    }
}
