// swift-tools-version: 5.9
import PackageDescription

// Builds EdgeMark/Core/Sync standalone so `swift test` can run against a local git
// remote. EdgePhoneSync is the iPhone's sync over the GitHub API, from Phone/Sync. EdgeStorageLogic builds the Foundation-only image cleanup and note text rules
// from EdgeMark/Core/Storage, EdgeExportLogic the export link rewriting from
// EdgeMark/Core/Export, EdgeCrypto the age format and key session from
// EdgeMark/Core/Crypto, EdgeIDELogic the Claude Code IDE protocol messages from
// EdgeMark/Core/IDE, EdgeReminderLogic the reminder times and Jev suggestion from
// EdgeMark/Core/Reminders, and EdgeJournalLogic the journal files, todos and meetings from
// EdgeMark/Core/Journal. The app target compiles the same files through its synchronized group.
// The phone build leaves out the files that run git, which iOS cannot do.
let phone = Context.environment["EDGEMARK_PHONE"] == "1"
let gitOnly = ["Shell.swift", "GitRepo.swift", "GitSync.swift", "GitSync+GitHub.swift", "GistCatalog.swift"]

let package = Package(
    name: "EdgeSync",
    platforms: [.macOS("15.7"), .iOS("26.0")],
    targets: [
        .target(name: "EdgeSync", path: "EdgeMark/Core/Sync", exclude: phone ? gitOnly : []),
        .testTarget(name: "EdgeSyncTests", dependencies: ["EdgeSync"], path: "Tests/EdgeSyncTests"),
        .target(name: "EdgeStorageLogic", path: "EdgeMark/Core/Storage", sources: ["ImageCleanup.swift", "NoteText.swift", "NoteComplexity.swift", "GistTextFile.swift", "FileTypeStyle.swift", "NoteListBackgroundMenu.swift", "MermaidText.swift", "SyntaxLanguage.swift", "ListSelection.swift", "ListOrder.swift", "GistTrash.swift", "EncryptedFileName.swift", "EncryptedTags.swift"]),
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
        .target(name: "EdgeCrypto", path: "EdgeMark/Core/Crypto", sources: ["Bech32.swift", "AgeKeys.swift", "Age.swift", "KeyStore.swift", "EncryptionSettings.swift", "KeySession.swift", "EncryptedFile.swift"]),
        .testTarget(
            name: "EdgeCryptoTests",
            dependencies: ["EdgeCrypto"],
            path: "Tests/EdgeCryptoTests",
            exclude: ["Fixtures"]
        ),
        .target(name: "EdgeIDELogic", path: "EdgeMark/Core/IDE", sources: ["IDEProtocol.swift"]),
        .testTarget(name: "EdgeIDELogicTests", dependencies: ["EdgeIDELogic"], path: "Tests/EdgeIDELogicTests"),
        .target(name: "EdgeReminderLogic", path: "EdgeMark/Core/Reminders", sources: ["ReminderTimes.swift", "ReminderSuggestion.swift"]),
        .testTarget(name: "EdgeReminderLogicTests", dependencies: ["EdgeReminderLogic"], path: "Tests/EdgeReminderLogicTests"),
        .target(name: "EdgeJournalLogic", path: "EdgeMark/Core/Journal"),
        .testTarget(name: "EdgeJournalLogicTests", dependencies: ["EdgeJournalLogic"], path: "Tests/EdgeJournalLogicTests"),
        .target(name: "EdgePhoneSync", path: "Phone/Sync"),
        .testTarget(name: "EdgePhoneSyncTests", dependencies: ["EdgePhoneSync"], path: "Tests/EdgePhoneSyncTests"),
    ]
)

// The iPhone app, built only by scripts/phone.sh: its SwiftUI code is iOS-only, so a plain
// `swift build` on macOS leaves it and MarkdownUI out.
if phone {
    package.dependencies.append(.package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"))
    package.targets.append(.executableTarget(
        name: "EdgeMarkPhone",
        dependencies: ["EdgeJournalLogic", "EdgePhoneSync", "EdgeSync", "EdgeStorageLogic", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
        path: "Phone/Sources"
    ))
}
