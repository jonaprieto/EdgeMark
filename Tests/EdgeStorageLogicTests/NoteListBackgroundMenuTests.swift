import XCTest
@testable import EdgeStorageLogic

final class NoteListBackgroundMenuTests: XCTestCase {
    func testHomeWithoutSyncOrText() {
        XCTAssertEqual(
            NoteListBackgroundMenu.groups(folder: "", syncActive: false, pasteboardText: nil),
            [[.newNote, .newFolder], [.sortBy], [.showInFinder, .trash, .settings]],
        )
    }

    func testFolderWithSyncAndText() {
        XCTAssertEqual(
            NoteListBackgroundMenu.groups(folder: "Work/Ideas", syncActive: true, pasteboardText: "Hello\nworld"),
            [[.newNote, .newFolder], [.sortBy, .pasteAsNewNote], [.showInFinder, .syncNow, .trash, .settings]],
        )
    }

    func testBlankPasteboardTextOffersNoPaste() {
        let groups = NoteListBackgroundMenu.groups(folder: "", syncActive: false, pasteboardText: " \n\t ")
        XCTAssertFalse(groups.joined().contains(.pasteAsNewNote))
    }

    func testInsideAGistThereIsNoNewFolder() {
        let groups = NoteListBackgroundMenu.groups(folder: "Gists/abc123", syncActive: true, pasteboardText: nil)
        XCTAssertEqual(groups.first, [.newNote])
    }

    func testGistsFolderItselfAndLookalikesKeepNewFolder() {
        for folder in ["Gists", "GistsArchive", "Notes/Gists/x"] {
            let groups = NoteListBackgroundMenu.groups(folder: folder, syncActive: false, pasteboardText: nil)
            XCTAssertEqual(groups.first, [.newNote, .newFolder], folder)
        }
    }
}
