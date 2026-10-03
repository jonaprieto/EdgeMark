import Foundation

/// Which gist items a note's export menus offer. Foundation only, so `swift test` builds it
/// standalone (EdgeExportLogic); the app compiles the same file through its group.
nonisolated enum GistExportOffer: Equatable {
    /// Sync is off: no gist items at all.
    case none
    /// An ordinary note: "Export as Private Gist" and "Export as Public Gist...". A note
    /// with images cannot become a gist (gists hold no folders), so the items are shown
    /// disabled with the reason.
    case publish(blockedByImages: Bool)
    /// The note already lives under `Gists/`: link and open items instead, so it is never
    /// published twice.
    case linkToGist

    static func decide(folder: String, hasImages: Bool, syncActive: Bool) -> GistExportOffer {
        guard syncActive else { return .none }
        if isInGists(folder: folder) { return .linkToGist }
        return .publish(blockedByImages: hasImages)
    }

    /// True for `Gists` itself and any folder below it.
    static func isInGists(folder: String) -> Bool {
        folder == "Gists" || folder.hasPrefix("Gists/")
    }
}
