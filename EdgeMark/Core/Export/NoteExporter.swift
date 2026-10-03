import AppKit
import OSLog
import UniformTypeIdentifiers

/// "Export as Markdown" for a single note. Writes a copy chosen through a save panel and
/// never touches the note itself or its asset folder.
@MainActor
enum NoteExporter {
    private static let lastDirectoryKey = "export.lastDirectory"

    // MARK: - Markdown

    /// Save the note's text as a standalone `.md`. Images from the note's asset folder are
    /// copied next to it into `<exported stem>-images/` and the links rewritten to match.
    static func exportMarkdown(note: Note, noteStore: NoteStore) {
        let current = currentNote(note, noteStore: noteStore)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = savedFilename(of: current)
        panel.directoryURL = lastDirectory
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                rememberDirectory(of: url)
                do {
                    try writeMarkdown(current, to: url)
                    Log.storage.info("[Export] wrote Markdown to \(url.path, privacy: .public)")
                } catch {
                    fail("Markdown", error)
                }
            }
        }
    }

    private static func writeMarkdown(_ note: Note, to url: URL) throws {
        let fm = FileManager.default
        let stem = (savedFilename(of: note) as NSString).deletingPathExtension
        let exportedStem = url.deletingPathExtension().lastPathComponent
        let rewritten = ExportLinks.rewriteImageLinks(in: note.content, stem: stem, exportedStem: exportedStem)

        // Copy the images first so a failure leaves no .md pointing at missing files.
        if !rewritten.imageNames.isEmpty {
            let source = FileStorage.assetDirURL(stem: stem, folder: note.folder)
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("\(exportedStem)-images", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in rewritten.imageNames {
                let from = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else {
                    Log.storage.error("[Export] referenced image missing: \(name, privacy: .public)")
                    continue
                }
                let to = target.appendingPathComponent(name)
                if fm.fileExists(atPath: to.path) {
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
            }
        }
        try rewritten.text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// The note as the store holds it after flushing pending edits to disk.
    private static func currentNote(_ note: Note, noteStore: NoteStore) -> Note {
        noteStore.saveDirtyNotes()
        return noteStore.notes.first { $0.id == note.id } ?? note
    }

    /// File name on disk ("Title.md"); the asset folder is named after it, not the title.
    private static func savedFilename(of note: Note) -> String {
        note.savedFilename ?? note.filename
    }

    private static var lastDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: lastDirectoryKey),
           FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func rememberDirectory(of url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastDirectoryKey)
    }

    /// No alert: a beep and a log line, so a failed export never blocks the panel.
    private static func fail(_ kind: String, _ error: Error) {
        NSSound.beep()
        Log.storage.error("[Export] \(L10n.shared["export.failed"], privacy: .public) (\(kind, privacy: .public)): \(error)")
    }
}
