// swift-tools-version: 5.9
import PackageDescription

// Builds EdgeMark/Core/Sync standalone so `swift test` can run against a local git
// remote. EdgeStorageLogic builds the Foundation-only image cleanup and note text rules
// from EdgeMark/Core/Storage, EdgeExportLogic the export link rewriting from
// EdgeMark/Core/Export, EdgeCrypto the age format and key session from
// EdgeMark/Core/Crypto, EdgeIDELogic the Claude Code IDE protocol messages from
// EdgeMark/Core/IDE, and EdgeReminderLogic the reminder times and Jev suggestion from
// EdgeMark/Core/Reminders. The app target compiles the same files through its synchronized group.
let package = Package(
    name: "EdgeSync",
    platforms: [.macOS("15.7")],
    targets: [
        .target(name: "EdgeSync", path: "EdgeMark/Core/Sync"),
        .testTarget(name: "EdgeSyncTests", dependencies: ["EdgeSync"], path: "Tests/EdgeSyncTests"),
        .target(name: "EdgeStorageLogic", path: "EdgeMark/Core/Storage", sources: ["ImageCleanup.swift", "NoteText.swift", "NoteComplexity.swift", "GistTextFile.swift", "FileTypeStyle.swift", "NoteListBackgroundMenu.swift", "MermaidText.swift", "SyntaxLanguage.swift", "ListSelection.swift", "GistTrash.swift", "EncryptedFileName.swift", "EncryptedTags.swift"]),
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
    ]
)
