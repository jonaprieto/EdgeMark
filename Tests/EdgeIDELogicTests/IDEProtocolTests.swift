@testable import EdgeIDELogic
import XCTest

final class IDEProtocolTests: XCTestCase {
    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func reply(_ request: String) throws -> [String: Any] {
        try object(IDEProtocol.reply(to: Data(request.utf8), version: "1.0"))
    }

    func testInitializeNamesTheServer() throws {
        let result = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "edgemark")
    }

    func testNoToolsListedButDiagnosticsAnswerEmpty() throws {
        let list = try reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        let call = try reply(#"{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"getDiagnostics","arguments":{}}}"#)
        XCTAssertEqual(call["id"] as? String, "3")
        let content = try XCTUnwrap((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "[]")
    }

    func testOtherRequestsAreErrors() throws {
        let diff = try reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"openDiff"}}"#)
        XCTAssertEqual((diff["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNil(diff["result"])
    }

    func testNotificationsAndGarbageGetNoReply() {
        XCTAssertNil(IDEProtocol.reply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), version: "1"))
        XCTAssertNil(IDEProtocol.reply(to: Data("not json".utf8), version: "1"))
    }

    func testSelectionCountsTheHiddenHeading() throws {
        let text = "one\ntwo\nthree"
        let data = IDEProtocol.selectionChanged(
            text: text, range: NSRange(location: 4, length: 6), hiddenPrefix: "# Title\r\n\n", filePath: "/notes/a b.md",
        )
        let message = try object(data)
        XCTAssertEqual(message["method"] as? String, "selection_changed")
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        XCTAssertEqual(params["text"] as? String, "two\nth")
        XCTAssertEqual(params["fileUrl"] as? String, "file:///notes/a%20b.md")
        let selection = try XCTUnwrap(params["selection"] as? [String: Any])
        XCTAssertEqual(selection["start"] as? [String: Int], ["line": 3, "character": 0])
        XCTAssertEqual(selection["end"] as? [String: Int], ["line": 4, "character": 2])
        XCTAssertEqual(selection["isEmpty"] as? Bool, false)
    }

    func testCaretPastTheEndIsClampedAndEmpty() throws {
        let data = IDEProtocol.selectionChanged(text: "ab", range: NSRange(location: 9, length: 0), hiddenPrefix: "", filePath: "/n.md")
        let params = try XCTUnwrap(object(data)["params"] as? [String: Any])
        let selection = try XCTUnwrap(params["selection"] as? [String: Any])
        XCTAssertEqual(selection["start"] as? [String: Int], ["line": 0, "character": 2])
        XCTAssertEqual(selection["isEmpty"] as? Bool, true)
        XCTAssertEqual(params["text"] as? String, "")
    }

    func testMentionGivesLinesInTheFile() throws {
        let text = "one\ntwo\nthree\n"
        let lines = { (range: NSRange) throws -> [String: Any] in
            try XCTUnwrap(self.object(IDEProtocol.atMentioned(
                text: text, range: range, hiddenPrefix: "# T\n\n", filePath: "/n.md",
            ))["params"] as? [String: Any])
        }
        // "two\nth": lines 1-2 of the body, 3-4 of the file.
        let partial = try lines(NSRange(location: 4, length: 6))
        XCTAssertEqual(partial["lineStart"] as? Int, 3)
        XCTAssertEqual(partial["lineEnd"] as? Int, 4)
        // "two\n" ends at the start of line 2, which is not part of it.
        let wholeLine = try lines(NSRange(location: 4, length: 4))
        XCTAssertEqual(wholeLine["lineStart"] as? Int, 3)
        XCTAssertEqual(wholeLine["lineEnd"] as? Int, 3)
        // No selection: the whole file.
        let file = try lines(NSRange(location: 2, length: 0))
        XCTAssertEqual(file["filePath"] as? String, "/n.md")
        XCTAssertNil(file["lineStart"])
    }

    func testLockFileAndToken() throws {
        let token = try XCTUnwrap(IDEProtocol.token())
        XCTAssertNotNil(token.wholeMatch(of: #/[0-9a-f]{32}/#))
        let lock = try object(IDEProtocol.lockFile(pid: 42, workspace: "/notes", token: token))
        XCTAssertEqual(lock["workspaceFolders"] as? [String], ["/notes"])
        XCTAssertEqual(lock["transport"] as? String, "ws")
        XCTAssertEqual(lock["authToken"] as? String, token)
        XCTAssertEqual(lock["pid"] as? Int, 42)
    }
}
