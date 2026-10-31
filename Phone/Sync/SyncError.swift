import Foundation

public enum SyncError: Error, Equatable, CustomStringConvertible {
    case github(status: Int, message: String)
    case truncatedTree
    case badPath(String)
    /// Another device kept pushing during every attempt.
    case busy

    public var description: String {
        switch self {
        case let .github(status, message): "GitHub answered \(status) \(message)".trimmingCharacters(in: .whitespaces)
        case .truncatedTree: "GitHub cut the file list short"
        case let .badPath(path): "Refused the path \(path)"
        case .busy: "The repository kept changing during the sync; try again"
        }
    }
}
