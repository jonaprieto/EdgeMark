@testable import EdgePhoneSync
import XCTest

final class ChatAppTests: XCTestCase {
    func testALinkCarriesTheNoteIntact() throws {
        let text = "Café & #plan + 100%?\nsegunda línea"
        let url = try XCTUnwrap(ChatApp.claude.link(with: text))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://claude.ai/new?q="))
        let query = String(url.absoluteString.dropFirst("https://claude.ai/new?q=".count))
        XCTAssertFalse(query.contains { "&#+% \n".contains($0) && $0 != "%" })
        XCTAssertEqual(query.removingPercentEncoding, text)
    }

    func testChatGPTOpensItsAppFromTheQueryOrTheFragment() throws {
        XCTAssertEqual(ChatApp.chatGPT.link(with: "hola")?.absoluteString, "https://chatgpt.com/?prompt=hola")
        XCTAssertEqual(ChatApp.chatGPT.home.absoluteString, "https://chatgpt.com/#native")
    }

    func testAnEmptyNoteOpensANewChat() {
        XCTAssertEqual(ChatApp.claude.link(with: ""), ChatApp.claude.home)
    }

    func testANoteTooLongForALinkHasNone() {
        XCTAssertNotNil(ChatApp.chatGPT.link(with: String(repeating: "a", count: ChatApp.limit)))
        XCTAssertNil(ChatApp.chatGPT.link(with: String(repeating: "a", count: ChatApp.limit + 1)))
        XCTAssertNil(ChatApp.chatGPT.link(with: String(repeating: "á", count: ChatApp.limit / 5)))
    }
}
