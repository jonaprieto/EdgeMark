// swift-tools-version: 5.9
import PackageDescription

// Builds EdgeMark/Core/Sync standalone so `swift test` can run against a local git
// remote. EdgeStorageLogic builds the Foundation-only image cleanup and note text rules
// from EdgeMark/Core/Storage, and EdgeExportLogic the export link rewriting from
// EdgeMark/Core/Export. The app target compiles the same files through its synchronized group.
let package = Package(
    name: "EdgeSync",
    platforms: [.macOS("15.7")],
    targets: [
        .target(name: "EdgeSync", path: "EdgeMark/Core/Sync"),
        .testTarget(name: "EdgeSyncTests", dependencies: ["EdgeSync"], path: "Tests/EdgeSyncTests"),
        .target(name: "EdgeStorageLogic", path: "EdgeMark/Core/Storage", sources: ["ImageCleanup.swift", "NoteText.swift", "NoteComplexity.swift", "GistTextFile.swift", "FileTypeStyle.swift", "NoteListBackgroundMenu.swift", "MermaidText.swift"]),
        .testTarget(
            name: "EdgeStorageLogicTests",
            dependencies: ["EdgeStorageLogic"],
            path: "Tests/EdgeStorageLogicTests"
        ),
        .target(name: "EdgeExportLogic", path: "EdgeMark/Core/Export", sources: ["ExportLinks.swift", "GistExportOffer.swift"]),
        .testTarget(
            name: "EdgeExportLogicTests",
            dependencies: ["EdgeExportLogic"],
            path: "Tests/EdgeExportLogicTests"
        ),
    ]
)
