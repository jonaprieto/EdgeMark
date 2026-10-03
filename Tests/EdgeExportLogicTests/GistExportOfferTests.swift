import XCTest
@testable import EdgeExportLogic

final class GistExportOfferTests: XCTestCase {
    func testNothingWhenSyncIsOff() {
        XCTAssertEqual(GistExportOffer.decide(folder: "", hasImages: false, syncActive: false), .none)
        XCTAssertEqual(GistExportOffer.decide(folder: "Gists/notes", hasImages: false, syncActive: false), .none)
    }

    func testOrdinaryNoteOffersPublish() {
        XCTAssertEqual(GistExportOffer.decide(folder: "", hasImages: false, syncActive: true), .publish(blockedByImages: false))
        XCTAssertEqual(GistExportOffer.decide(folder: "Work", hasImages: false, syncActive: true), .publish(blockedByImages: false))
    }

    func testImagesBlockPublish() {
        XCTAssertEqual(GistExportOffer.decide(folder: "Work", hasImages: true, syncActive: true), .publish(blockedByImages: true))
    }

    func testGistNoteOffersLinkNotPublish() {
        XCTAssertEqual(GistExportOffer.decide(folder: "Gists/my-gist", hasImages: false, syncActive: true), .linkToGist)
        XCTAssertEqual(GistExportOffer.decide(folder: "Gists", hasImages: true, syncActive: true), .linkToGist)
    }

    func testOnlyTheGistsFolderCounts() {
        XCTAssertFalse(GistExportOffer.isInGists(folder: "GistsArchive"))
        XCTAssertFalse(GistExportOffer.isInGists(folder: "Work/Gists"))
        XCTAssertTrue(GistExportOffer.isInGists(folder: "Gists/a"))
    }
}
