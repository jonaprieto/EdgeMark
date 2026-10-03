import Foundation

/// Decides which files in a note's hidden asset folder can be deleted after a save.
/// Foundation only, so the rules are unit tested by the `EdgeStorageLogic` SPM target.
enum ImageCleanup {
    /// Names produced by `FileStorage.saveImage`: "IMG-<uuid>.<ext>". Anything else in the
    /// folder was put there by the user or another tool and is never touched.
    private static let imageNamePattern = "^IMG-[A-Za-z0-9-]+\\.[A-Za-z0-9]+$"

    static func isEdgeMarkImageName(_ name: String) -> Bool {
        name.range(of: imageNamePattern, options: .regularExpression) != nil
    }

    /// File names from `directoryListing` that are EdgeMark images referenced neither by
    /// `body` nor by any of `otherBodies`. Checking the other notes keeps an image the user
    /// cut from this note and pasted into another one.
    static func orphanedImageNames(in directoryListing: [String], body: String, otherBodies: [String]) -> [String] {
        directoryListing.filter { name in
            isEdgeMarkImageName(name)
                && !body.contains(name)
                && !otherBodies.contains { $0.contains(name) }
        }
    }
}
