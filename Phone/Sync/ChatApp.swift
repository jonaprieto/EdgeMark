import Foundation

/// A chat app that opens from a link with a message already in it. It uses that app's own account
/// and plan, so it costs no API tokens. On a phone without the app, the link opens the website.
public enum ChatApp: String, CaseIterable, Sendable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"

    /// Longest query a link carries, a safe guess: neither app documents theirs.
    static let limit = 2000

    private var base: String {
        switch self {
        case .chatGPT: "https://chatgpt.com/"
        case .claude: "https://claude.ai/new"
        }
    }

    /// ChatGPT sends a `q` the moment it opens. Its `prompt` only writes it, so you can read it first.
    private var parameter: String {
        self == .chatGPT ? "prompt" : "q"
    }

    /// A new chat. ChatGPT's home needs the fragment to open in the app rather than the browser.
    public var home: URL {
        URL(string: self == .chatGPT ? base + "#native" : base)!
    }

    /// A new chat holding `text`, nil when `text` is too long for a link.
    public func link(with text: String) -> URL? {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: safe), query.count <= Self.limit else { return nil }
        return query.isEmpty ? home : URL(string: "\(base)?\(parameter)=\(query)")
    }
}
