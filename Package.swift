// swift-tools-version: 5.9
import PackageDescription

// Builds EdgeMark/Core/Sync standalone so `swift test` can run against a local git
// remote. The app target compiles the same files through its synchronized group.
let package = Package(
    name: "EdgeSync",
    platforms: [.macOS("15.7")],
    targets: [
        .target(name: "EdgeSync", path: "EdgeMark/Core/Sync"),
        .testTarget(name: "EdgeSyncTests", dependencies: ["EdgeSync"], path: "Tests/EdgeSyncTests"),
    ]
)
