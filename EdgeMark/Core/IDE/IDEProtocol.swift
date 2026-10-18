import Foundation
import Security

/// The data side of Claude Code's IDE protocol: the lock file, the replies to the CLI's
/// JSON-RPC requests and the `selection_changed` notification. Anthropic documents it only
/// for its own extensions; this follows coder/claudecode.nvim's PROTOCOL.md.
enum IDEProtocol {
    /// 128-bit lowercase hex token from the system CSPRNG; nil if that fails.
    static func token() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Contents of `~/.claude/ide/<port>.lock`. The CLI offers the IDE to sessions whose
    /// working directory is inside `workspace`.
    static func lockFile(pid: Int32, workspace: String, token: String) -> Data {
        json(["pid": pid, "workspaceFolders": [workspace], "ideName": "EdgeMark", "transport": "ws", "authToken": token])
    }

    /// The reply to one message from the CLI; nil for notifications and anything unreadable.
    /// No tools are listed: the CLI still calls `getDiagnostics` on its own, and notes have none.
    static func reply(to message: Data, version: String) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let id = message["id"], let method = message["method"] as? String else { return nil }
        let tool = (message["params"] as? [String: Any])?["name"] as? String
        let result: Any
        switch (method, tool) {
        case ("initialize", _):
            result = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "edgemark", "version": version],
            ]
        case ("tools/list", _):
            result = ["tools": [Any]()]
        case ("tools/call", "getDiagnostics"):
            result = ["content": [["type": "text", "text": "[]"]]]
        case ("ping", _):
            result = [String: Any]()
        default:
            let name = tool.map { "\(method) \($0)" } ?? method
            return json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "EdgeMark does not support \(name)"]])
        }
        return json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// `selection_changed` for `range` of the editor's `text`. Lines are 0-based and count
    /// `hiddenPrefix`, the file's lines the editor does not show (the title heading);
    /// characters are UTF-16 offsets, as in VS Code.
    static func selectionChanged(text: String, range: NSRange, hiddenPrefix: String, filePath: String) -> Data {
        let ns = text as NSString
        let start = min(range.location, ns.length)
        let end = min(NSMaxRange(range), ns.length)
        let offset = hiddenPrefix.utf16.count(where: { $0 == 10 })
        func position(_ index: Int) -> [String: Int] {
            let (line, character) = Self.position(of: index, in: ns)
            return ["line": line + offset, "character": character]
        }
        return json([
            "jsonrpc": "2.0",
            "method": "selection_changed",
            "params": [
                "text": ns.substring(with: NSRange(location: start, length: end - start)),
                "filePath": filePath,
                "fileUrl": URL(fileURLWithPath: filePath).absoluteString,
                "selection": ["start": position(start), "end": position(end), "isEmpty": start == end],
            ],
        ])
    }

    /// `at_mentioned`: the CLI types `@file#Lstart-end` into its prompt. Lines are 0-based
    /// and count `hiddenPrefix`; an empty range mentions the whole file. A selection ending
    /// at the start of a line does not include that line.
    static func atMentioned(text: String, range: NSRange, hiddenPrefix: String, filePath: String) -> Data {
        var params: [String: Any] = ["filePath": filePath]
        if range.length > 0 {
            let ns = text as NSString
            let start = min(range.location, ns.length)
            let end = min(NSMaxRange(range), ns.length)
            let offset = hiddenPrefix.utf16.count(where: { $0 == 10 })
            let first = position(of: start, in: ns).line
            let (last, character) = position(of: end, in: ns)
            params["lineStart"] = first + offset
            params["lineEnd"] = (character == 0 && last > first ? last - 1 : last) + offset
        }
        return json(["jsonrpc": "2.0", "method": "at_mentioned", "params": params])
    }

    /// 0-based line and UTF-16 column of `index`.
    /// ponytail: scans from the top on each call; fine for note sizes.
    private static func position(of index: Int, in ns: NSString) -> (line: Int, character: Int) {
        var line = 0, lineStart = 0
        for i in 0 ..< index where ns.character(at: i) == 10 {
            line += 1
            lineStart = i + 1
        }
        return (line, index - lineStart)
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
