import XCTest
@testable import EdgePhoneSync

final class OpenAIChatTests: XCTestCase {
    func testRequestPutsTheSystemPromptFirst() throws {
        let body = try OpenAIChat.requestBody(model: "m", system: "s", messages: [.init(role: .user, content: "hi")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "m")
        XCTAssertEqual(json["messages"] as? [[String: String]], [
            ["role": "system", "content": "s"], ["role": "user", "content": "hi"],
        ])
    }

    func testParsesTheReply() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"yes"}}]}"#.utf8)
        XCTAssertEqual(try OpenAIChat.parse(data), "yes")
    }

    func testAnAPIErrorSurfacesItsMessage() {
        let data = Data(#"{"error":{"message":"bad key"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIChat.parse(data)) {
            XCTAssertEqual($0 as? OpenAIChat.Failure, .init(description: "bad key"))
        }
        XCTAssertThrowsError(try OpenAIChat.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try OpenAIChat.parse(Data(#"{"choices":[]}"#.utf8)))
    }

    func testTranscriptLinksBackToItsNote() {
        let text = OpenAIChat.transcript(
            [.init(role: .user, content: "q"), .init(role: .assistant, content: "a")],
            source: (title: "Note", path: "Folder/Note.md"),
        )
        XCTAssertEqual(text, "From [Note](../Folder/Note.md)\n\n**You:** q\n\n**OpenAI:** a\n")
    }
}
