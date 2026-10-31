import Foundation

/// Chat completions, without streaming, as Brainforge calls them.
public enum OpenAIChat {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable {
            case user, assistant
        }

        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func requestBody(model: String, system: String, messages: [Message]) throws -> Data {
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        return try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": system]] + turns,
        ] as [String: Any])
    }

    public static func parse(_ data: Data) throws -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(description: "Unreadable response")
        }
        if let error = json["error"] as? [String: Any] {
            throw Failure(description: error["message"] as? String ?? "API error")
        }
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw Failure(description: "Empty response")
        }
        return text
    }

    public static func reply(key: String, model: String, system: String, messages: [Message]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try requestBody(model: model, system: system, messages: messages)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    /// The conversation as a note body, linking back to the note it started from.
    public static func transcript(_ messages: [Message], source: (title: String, path: String)?) -> String {
        var parts: [String] = []
        if let source {
            let link = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path
            parts.append("From [\(source.title)](../\(link))")
        }
        for message in messages {
            parts.append("\(message.role == .user ? "**You:**" : "**OpenAI:**") \(message.content)")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
