import Foundation
import OSLog

enum FileStorage {
    /// Storage root — reads from ShortcutSettings so the user can configure a custom directory.
    static var rootURL: URL {
        StorageSettings.shared.resolvedStorageDirectory
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Directory Management

    /// Hidden `.trash/` directory at the storage root.
    static var trashURL: URL {
        rootURL.appendingPathComponent(".trash", isDirectory: true)
    }

    static func ensureRootExists() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Create the directory structure for a storage root: the root dir itself plus the
    /// `.edgemark/` (sidecar) and `.trash/` subdirs. Used when adding a new location
    /// (commit 3). Safe to call on an existing root — `withIntermediateDirectories`
    /// and the trash creation are no-ops if present.
    static func ensureRootStructure(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent(".edgemark", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent(".trash", isDirectory: true), withIntermediateDirectories: true)
    }

    static func ensureTrashExists() throws {
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
    }

    static func ensureFolderExists(_ folderName: String) throws {
        guard !folderName.isEmpty else { return }
        let url = rootURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func renameFolder(_ oldName: String, to newName: String) throws {
        guard !oldName.isEmpty, !newName.isEmpty else { return }
        let oldURL = rootURL.appendingPathComponent(oldName, isDirectory: true)
        let newURL = rootURL.appendingPathComponent(newName, isDirectory: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    static func deleteFolder(_ name: String) throws {
        guard !name.isEmpty else { return }
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.removeItem(at: url)
    }

    static func discoverFolders() throws -> [String] {
        let fm = FileManager.default
        try ensureRootExists()
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }

        var folders: [String] = []
        let rootPath = rootURL.path
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let fullPath = url.path
                if fullPath.count > rootPath.count, fullPath.hasPrefix(rootPath) {
                    let relative = String(fullPath.dropFirst(rootPath.count + 1))
                    if !relative.isEmpty {
                        folders.append(relative)
                    }
                }
            }
        }
        let count = folders.count
        Log.storage.debug("[FileStorage] discovered \(count) folders")
        return folders.sorted()
    }

    // MARK: - External Change Detection

    /// Resolves the actual path of a note on disk, preferring `savedFilename` over the
    /// title-derived `filename` to handle any sanitization edge cases.
    private static func diskRelativePath(for note: Note) -> String {
        let filename = note.savedFilename ?? note.filename
        return note.folder.isEmpty ? filename : "\(note.folder)/\(filename)"
    }

    /// Returns the filesystem modification date of a note's file, or nil if the file doesn't exist.
    static func modificationDate(for note: Note) -> Date? {
        let url = rootURL.appendingPathComponent(diskRelativePath(for: note))
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Reloads a note's content + tags from disk after an external change is detected.
    static func reloadContent(for note: Note) -> (content: String, modifiedAt: Date, savedAt: Date, tags: [TagColor])? {
        let url = rootURL.appendingPathComponent(diskRelativePath(for: note))
        // A locked note has nothing to compare or reload; it is read when it is unlocked.
        let text: String
        var payloadTags: [TagColor] = []
        if note.isEncrypted {
            let body = decryptedText(at: url)
            guard !note.isLocked, let plain = body.text else { return nil }
            text = plain
            payloadTags = body.tags
        } else {
            guard let plain = readText(at: url, folder: note.folder) else { return nil }
            text = plain
        }
        let diskDate = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()

        // Body may still have EdgeMark's YAML if this note wasn't migrated yet: strip it.
        // Any other leading `---` block is the user's and stays in the content. Gist files
        // are never stripped (see `readNote`).
        let legacy = isGistFolder(note.folder) ? nil : NoteText.legacyFrontMatter(text)
        let content = legacy?.body ?? text

        let tags: [TagColor] = if note.isEncrypted {
            payloadTags
        } else if let entry = SidecarStore.shared.noteEntry(for: note.id) {
            entry.tags.compactMap { TagColor(rawValue: $0) }
        } else {
            parseTagList(legacy?.metadata["tags"] ?? "")
        }
        // After an external edit, savedAt should advance to the new disk date so the
        // watcher doesn't fire again for the same change.
        return (content: content, modifiedAt: diskDate, savedAt: diskDate, tags: tags)
    }

    // MARK: - Asset Directory

    /// Hidden dot-prefix asset directory co-located with a note file.
    /// e.g. "My-Note.md" → ".My-Note/" in the same parent directory.
    /// stem = sanitized filename WITHOUT the .md extension.
    static func assetDirURL(stem: String, folder: String, inTrash: Bool = false) -> URL {
        let base = inTrash ? trashURL : rootURL
        let dirName = "." + stem
        if !inTrash, !folder.isEmpty {
            return base.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(dirName, isDirectory: true)
        }
        return base.appendingPathComponent(dirName, isDirectory: true)
    }

    /// Stem of the note's asset dir: the file name on disk without ".md", made safe for the
    /// editor's link patterns (`NoteText.safeAssetStem`). It differs from the sanitized title
    /// for duplicate titles ("Title 2"), externally renamed files and gist notes, so the
    /// title is only used before the note's first save.
    static func assetStem(for note: Note) -> String {
        NoteText.safeAssetStem(fileStem(for: note))
    }

    /// Every asset dir stem the note may have on disk: `assetStem`, then the plain file
    /// stem that images were stored under before stems were made safe (when different).
    static func assetStems(for note: Note) -> [String] {
        let stems = [assetStem(for: note), fileStem(for: note)]
        return stems[0] == stems[1] ? [stems[0]] : stems
    }

    private static func fileStem(for note: Note) -> String {
        EncryptedFileName.stem(note.savedFilename ?? note.filename)
    }

    /// Asset dirs to rename when a note's file stem changes from `oldStem` to `newStem`:
    /// the safe-stem dir, plus a dir from before stems were safe, which is folded into the
    /// new safe-stem dir (its references are rewritten with it).
    private static func assetStemRenames(from oldStem: String, to newStem: String) -> [(old: String, new: String)] {
        let newSafe = NoteText.safeAssetStem(newStem)
        var pairs = [(old: NoteText.safeAssetStem(oldStem), new: newSafe)]
        if oldStem != pairs[0].old {
            pairs.append((old: oldStem, new: newSafe))
        }
        return pairs.filter { $0.old != $0.new }
    }

    /// Move `source` to `destination`, or move its files into `destination` when that
    /// already exists. Image names are UUIDs, so merged files never collide.
    private static func moveOrMergeDirectory(_ source: URL, into destination: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try? fm.moveItem(at: source, to: destination)
            return
        }
        let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            try? fm.moveItem(at: f, to: destination.appendingPathComponent(f.lastPathComponent))
        }
        if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fm.removeItem(at: source)
        }
    }

    /// Save image data to the note's asset directory.
    /// Returns both the on-disk storage markdown `![](path)` and the embed syntax `![[path]]`
    /// used by the editor's display layer.
    static func saveImage(data: Data, ext: String, forNote note: Note) throws -> (markdown: String, embedMarkdown: String, src: String) {
        let stem = assetStem(for: note)
        let assetDir = assetDirURL(stem: stem, folder: note.folder)
        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
        let imageFilename = "IMG-\(UUID().uuidString).\(ext)"
        let destURL = assetDir.appendingPathComponent(imageFilename)
        try data.write(to: destURL, options: .atomic)
        Log.storage.info("[Image] saved \(imageFilename, privacy: .public) (\(data.count) bytes) for '\(note.title, privacy: .public)'")
        let path = "." + stem + "/" + imageFilename
        return (
            markdown: "![](\(path))",
            embedMarkdown: "![[\(path)]]",
            src: destURL.absoluteString,
        )
    }

    /// Remove EdgeMark image files ("IMG-<uuid>.<ext>") in the note's asset dir that neither
    /// the note body nor any of `otherBodies` references. Other files are never touched.
    /// Removes the asset dir itself only when it is empty afterwards.
    static func cleanOrphanedImages(forNote note: Note, body: String, otherBodies: [String]) {
        for stem in assetStems(for: note) {
            cleanOrphanedImages(in: assetDirURL(stem: stem, folder: note.folder), note: note, body: body, otherBodies: otherBodies)
        }
    }

    private static func cleanOrphanedImages(in assetDir: URL, note: Note, body: String, otherBodies: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: assetDir.path) else { return }
        let orphans = ImageCleanup.orphanedImageNames(in: names, body: body, otherBodies: otherBodies)
        var removed = 0
        for name in orphans {
            do {
                try FileManager.default.removeItem(at: assetDir.appendingPathComponent(name))
                removed += 1
            } catch {
                Log.storage.error("[Image] failed to remove orphaned \(name, privacy: .public): \(error)")
            }
        }
        if removed > 0 {
            Log.storage.info("[Image] cleaned \(removed) orphaned image(s) from '\(note.title, privacy: .public)'")
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: assetDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: assetDir)
            Log.storage.debug("[Image] removed empty asset dir for '\(note.title, privacy: .public)'")
        }
    }

    // MARK: - Filename Helpers

    static func sanitizeForFilename(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }

        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        let cleaned = trimmed.unicodeScalars
            .map { illegal.contains($0) ? "-" : String($0) }
            .joined()

        let hyphenated = cleaned.replacingOccurrences(of: " ", with: "-")
        let collapsed = hyphenated.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        var result = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Truncate to stay within APFS 255-byte filename limit (.md = 3 bytes + margin).
        // Every Character is at least one byte, so cut to that many Characters first: the
        // loop below copies the string per step, which never ends for a megabyte title.
        let maxBytes = 248
        result = String(result.prefix(maxBytes))
        while result.utf8.count > maxBytes {
            result = String(result.dropLast())
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return result.isEmpty ? "Untitled" : result
    }

    // MARK: - Note I/O

    static func loadAllNotes() throws -> [Note] {
        try ensureRootExists()
        var notes = try loadNotes(in: rootURL, folder: "")
        for folderName in try discoverFolders() {
            let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
            notes += try loadNotes(in: folderURL, folder: folderName)
        }
        let resolved = try resolveDuplicateFilenames(notes)
        let count = resolved.count
        Log.storage.info("[FileStorage] loaded \(count) notes from disk")
        return resolved
    }

    /// Whether `folder` is the `Gists` folder or a gist clone inside it.
    /// A note there is the file itself: its title is the file name, content edits never
    /// rename it, and renaming it renames the file (`renameGistFile`).
    static func isGistFolder(_ folder: String) -> Bool {
        folder == "Gists" || folder.hasPrefix("Gists/")
    }

    /// Writes the note to disk. If the title changed since last save, renames the old file
    /// to preserve macOS file metadata (creation date, Finder tags, extended attributes).
    /// Also renames the co-located asset directory and rewrites image paths in the body.
    /// Returns the new filename and, if image paths were rewritten, the updated content.
    @discardableResult
    static func writeNote(_ note: Note) throws -> (filename: String, updatedContent: String?, savedAt: Date) {
        try ensureRootExists()
        if !note.folder.isEmpty {
            try ensureFolderExists(note.folder)
        }

        // Gist clones: write the text as is under the file's name (the title for a new file),
        // never rename.
        if isGistFolder(note.folder) {
            let name = note.savedFilename ?? note.filename
            let currentURL = rootURL.appendingPathComponent("\(note.folder)/\(name)")
            try writeBody(note.content, of: note, to: currentURL)
            Task { @MainActor in GitSync.shared.noteActivity(at: currentURL) }
            upsertSidecarEntry(for: note, filename: name)
            let savedAt = (try? FileManager.default.attributesOfItem(atPath: currentURL.path))?[.modificationDate] as? Date
            return (filename: name, updatedContent: nil, savedAt: savedAt ?? Date())
        }

        let newFilename = note.filename
        let newURL = rootURL.appendingPathComponent(note.relativePath)

        // Safety: if target file exists and isn't our own file, skip to avoid overwriting
        if let savedFilename = note.savedFilename,
           savedFilename != newFilename,
           FileManager.default.fileExists(atPath: newURL.path)
        {
            Log.storage.info("[FileStorage] filename conflict: \(newFilename, privacy: .public), keeping \(savedFilename, privacy: .public)")
            let currentRelative = note.folder.isEmpty ? savedFilename : "\(note.folder)/\(savedFilename)"
            let currentURL = rootURL.appendingPathComponent(currentRelative)
            try writeBody(note.content, of: note, to: currentURL)
            Task { @MainActor in GitSync.shared.noteActivity(at: currentURL) }
            upsertSidecarEntry(for: note, filename: savedFilename)
            return (filename: savedFilename, updatedContent: nil, savedAt: modificationDate(for: note) ?? Date())
        }

        // Rename old file first if title changed (preserves macOS metadata)
        var updatedContent: String? = nil
        if let oldFilename = note.savedFilename, oldFilename != newFilename {
            let oldRelative = note.folder.isEmpty ? oldFilename : "\(note.folder)/\(oldFilename)"
            let oldURL = rootURL.appendingPathComponent(oldRelative)
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                Log.storage.debug("[FileStorage] renamed \(oldFilename, privacy: .public) → \(newFilename, privacy: .public)")
            }

            // Rename asset dir and rewrite image paths in body
            let oldStem = EncryptedFileName.stem(oldFilename)
            let newStem = EncryptedFileName.stem(newFilename)
            for pair in assetStemRenames(from: oldStem, to: newStem) {
                let oldAsset = assetDirURL(stem: pair.old, folder: note.folder)
                let newAsset = assetDirURL(stem: pair.new, folder: note.folder)
                guard FileManager.default.fileExists(atPath: oldAsset.path) else { continue }
                moveOrMergeDirectory(oldAsset, into: newAsset)
                Log.storage.info("[Image] renamed asset dir .\(pair.old, privacy: .public) → .\(pair.new, privacy: .public)")
                // Rewrite image refs in body — scoped to actual filenames, no false positives
                var body = updatedContent ?? note.content
                let imgs = (try? FileManager.default.contentsOfDirectory(
                    at: newAsset, includingPropertiesForKeys: nil,
                )) ?? []
                for f in imgs {
                    let name = f.lastPathComponent
                    body = body.replacingOccurrences(
                        of: "(." + pair.old + "/" + name + ")",
                        with: "(." + pair.new + "/" + name + ")",
                    )
                }
                updatedContent = body
            }
        }

        // Write body only — no YAML header
        let bodyToWrite = updatedContent ?? note.content
        try writeBody(bodyToWrite, of: note, to: newURL)
        Task { @MainActor in GitSync.shared.noteActivity(at: newURL) }

        // Sync sidecar — use actual disk mtime as savedAt so the external-change
        // detector sees no diff on the next poll cycle.
        var noteForSidecar = note
        if updatedContent != nil {
            noteForSidecar.content = bodyToWrite
        }
        upsertSidecarEntry(for: noteForSidecar, filename: newFilename)

        let savedAt = modificationDate(for: noteForSidecar) ?? Date()
        return (filename: newFilename, updatedContent: updatedContent, savedAt: savedAt)
    }

    // MARK: - Encrypted notes

    /// True for a Markdown note file, plain (`x.md`) or encrypted (`x.md.age`).
    private static func isMarkdownNote(_ url: URL) -> Bool {
        url.pathExtension == "md" || EncryptedFileName.isEncryptedMarkdown(url.lastPathComponent)
    }

    /// Writes a note's body to `url`: plain UTF-8, or an age file for an encrypted note,
    /// whose payload is the body with the note's tag line in front. A locked note has no
    /// text in memory, so its file is left exactly as it is.
    private static func writeBody(_ body: String, of note: Note, to url: URL) throws {
        guard note.isEncrypted else {
            try Data(body.utf8).write(to: url, options: .atomic)
            return
        }
        guard !note.isLocked else { return }
        guard let recipient = EncryptionSettings.shared.ageRecipient else { throw KeySessionError.notConfigured }
        let payload = EncryptedTags.embed(note.tags.map(\.rawValue), in: body)
        // No identity right after a lock: the edit is sealed anyway, see `EncryptedFile.write`.
        if try EncryptedFile.write(payload, to: url, recipient: recipient, identity: KeySession.shared.identity) {
            KeySession.shared.touch()
        }
    }

    /// Text and tags of the encrypted file at `url`. No text while the session is locked;
    /// no text and a reason when the file does not decrypt.
    private static func decryptedText(at url: URL) -> (text: String?, tags: [TagColor], error: String?) {
        guard let identity = KeySession.shared.identity else { return (nil, [], nil) }
        do {
            let payload = try EncryptedFile.read(at: url, identity: identity)
            let parts = EncryptedTags.extract(from: payload)
            return (parts.text, parts.tags.compactMap { TagColor(rawValue: $0) }, nil)
        } catch let error as AgeError {
            return (nil, [], String(describing: error))
        } catch {
            return (nil, [], "unreadable")
        }
    }

    /// `note` with its text and tags loaded, for a session that was just unlocked. It stays
    /// locked, with `lockError` set, when its file does not decrypt.
    static func unlocked(_ note: Note) -> Note {
        var note = note
        // A note in the trash is a file of `.trash/`, not of its original folder.
        let url = note.trashedAt != nil
            ? trashURL.appendingPathComponent(note.savedFilename ?? note.filename)
            : urlForNote(note)
        let body = decryptedText(at: url)
        note.isLocked = body.text == nil
        note.lockError = body.error
        guard let text = body.text else { return note }
        note.content = note.isGistFile ? text : NoteText.strippingLegacyFrontMatter(text)
        note.tags = body.tags
        if !note.isGistFile {
            note.title = extractTitle(from: note.content)
        }
        // A file that arrived by pull while the note was locked is newer than `savedAt`;
        // the text just read is that file's, so it is not an external change.
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            note.savedAt = mtime
        }
        return note
    }

    /// Turns the plaintext note into `<name>.age`, its tags going into the ciphertext and
    /// out of the sidecar. The plaintext file is removed only after the new file decrypted
    /// back to the same payload with `identity`.
    static func encryptNote(_ note: Note, recipient: AgeRecipient, identity: AgeIdentity) throws -> (filename: String, savedAt: Date) {
        // Sealing an encrypted note again would replace its file with what is in memory,
        // which is nothing for a locked one.
        guard !note.isEncrypted else { throw CocoaError(.fileWriteFileExists) }
        let payload = EncryptedTags.embed(note.tags.map(\.rawValue), in: note.content)
        let url = try EncryptedFile.seal(payload, at: urlForNote(note), recipient: recipient, identity: identity)
        return (url.lastPathComponent, noteFileReplaced(note, by: url, tags: []))
    }

    /// The reverse: an unlocked encrypted note becomes a plaintext file again, and its
    /// tags go back into the sidecar.
    static func decryptNote(_ note: Note) throws -> (filename: String, savedAt: Date) {
        // A locked note has no text in memory: unsealing it would write an empty file
        // and delete the real one.
        guard note.isEncrypted, !note.isLocked else { throw KeySessionError.notConfigured }
        let url = try EncryptedFile.unseal(note.content, at: urlForNote(note))
        return (url.lastPathComponent, noteFileReplaced(note, by: url, tags: note.tags.map(\.rawValue)))
    }

    /// Points the note's sidecar entry at its new file, with `tags`, and schedules the
    /// sync. Returns the new file's modification date.
    private static func noteFileReplaced(_ note: Note, by url: URL, tags: [String]) -> Date {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
        if var entry = SidecarStore.shared.noteEntry(for: note.id) {
            entry.path = note.folder.isEmpty ? url.lastPathComponent : "\(note.folder)/\(url.lastPathComponent)"
            entry.savedAt = mtime
            entry.tags = tags
            SidecarStore.shared.upsertNote(entry, for: note.id)
            try? SidecarStore.shared.save()
        }
        Task { @MainActor in GitSync.shared.noteActivity(at: url) }
        return mtime
    }

    /// Name of a note's file in `.trash/`: `<UUID>_<Title>.md`, plus `.age` when encrypted.
    static func trashFilename(for note: Note) -> String {
        let name = "\(note.id.uuidString)_\(sanitizeForFilename(note.title)).md"
        return note.isEncrypted ? name + EncryptedFileName.suffix : name
    }

    /// Update (or insert) the sidecar entry for a note after writing its file.
    private static func upsertSidecarEntry(for note: Note, filename: String) {
        let relativePath = note.folder.isEmpty ? filename : "\(note.folder)/\(filename)"
        let savedAt = (try? FileManager.default.attributesOfItem(
            atPath: rootURL.appendingPathComponent(relativePath).path,
        ))?[.modificationDate] as? Date ?? Date()

        SidecarStore.shared.upsertNote(
            SidecarStore.NoteEntry(
                path: relativePath,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                savedAt: savedAt,
                tags: note.isEncrypted ? [] : note.tags.map(\.rawValue),
            ),
            for: note.id,
        )
        try? SidecarStore.shared.save()
    }

    static func deleteNote(_ note: Note) throws {
        let actualFilename = note.savedFilename ?? note.filename
        let relativePath = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: url)
        if isGistFolder(note.folder) {
            Task { @MainActor in GitSync.shared.noteActivity(at: url) }
        }
        SidecarStore.shared.removeNote(id: note.id)
        try? SidecarStore.shared.save()
    }

    /// Renames a gist file to `newName` in its folder and moves its sidecar entry; the
    /// clone's next commit stages the rename. A case-only rename goes through a temporary
    /// name so it also works on a case-insensitive volume. Returns the file's new mtime.
    static func renameGistFile(_ note: Note, to newName: String) throws -> Date {
        let dir = rootURL.appendingPathComponent(note.folder, isDirectory: true)
        let oldName = note.savedFilename ?? note.filename
        let oldURL = dir.appendingPathComponent(oldName)
        let newURL = dir.appendingPathComponent(newName)
        if oldName.caseInsensitiveCompare(newName) == .orderedSame {
            let temp = dir.appendingPathComponent(".\(UUID().uuidString)")
            try FileManager.default.moveItem(at: oldURL, to: temp)
            try FileManager.default.moveItem(at: temp, to: newURL)
        } else {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        }
        Task { @MainActor in GitSync.shared.noteActivity(at: newURL) }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: newURL.path))?[.modificationDate] as? Date ?? Date()
        if var entry = SidecarStore.shared.noteEntry(for: note.id) {
            entry.path = "\(note.folder)/\(newName)"
            entry.savedAt = mtime
            SidecarStore.shared.upsertNote(entry, for: note.id)
            try? SidecarStore.shared.save()
        }
        return mtime
    }

    /// `name`, or `name` with " 2", " 3"... before its extension, whichever is not taken in `dir`.
    static func unusedFileName(_ name: String, in dir: URL) -> String {
        let encrypted = EncryptedFileName.isEncrypted(name)
        let plain = EncryptedFileName.plainName(name)
        let stem = (plain as NSString).deletingPathExtension
        let ext = (plain as NSString).pathExtension
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if encrypted { candidate += EncryptedFileName.suffix }
            counter += 1
        }
        return candidate
    }

    /// Returns the full file URL for a note (for Finder reveal).
    static func urlForNote(_ note: Note) -> URL {
        let actualFilename = note.savedFilename ?? note.filename
        let relativePath = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
        return rootURL.appendingPathComponent(relativePath)
    }

    /// Returns the full directory URL for a folder (for Finder reveal).
    static func urlForFolder(_ name: String) -> URL {
        if name.isEmpty {
            return rootURL
        }
        return rootURL.appendingPathComponent(name, isDirectory: true)
    }

    static func moveFolder(_ name: String, toParent newParent: String) throws {
        guard !name.isEmpty else { return }
        let displayName = (name as NSString).lastPathComponent
        let oldURL = rootURL.appendingPathComponent(name, isDirectory: true)
        let newFolderPath = newParent.isEmpty ? displayName : "\(newParent)/\(displayName)"
        let newURL = rootURL.appendingPathComponent(newFolderPath, isDirectory: true)
        if !newParent.isEmpty {
            try ensureFolderExists(newParent)
        }
        try FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    /// Move a note to `toFolder`, optionally renaming the on-disk file to `newFilename`.
    /// When `newFilename` is nil, the existing on-disk filename is preserved — caller's
    /// `savedFilename ?? filename`. Pass an explicit name to atomically move + rename
    /// (used by the conflict-resolver's "Keep Both" path).
    @discardableResult
    static func moveNote(_ note: Note, toFolder: String, withFilename newFilename: String? = nil) throws -> Date {
        let actualFilename = note.savedFilename ?? note.filename
        let oldRelative = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
        let oldURL = rootURL.appendingPathComponent(oldRelative)

        if !toFolder.isEmpty {
            try ensureFolderExists(toFolder)
        }
        let destFilename = newFilename ?? actualFilename
        let newRelative = toFolder.isEmpty ? destFilename : "\(toFolder)/\(destFilename)"
        let newURL = rootURL.appendingPathComponent(newRelative)
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        // Move asset dir alongside note — rename stem too if filename changed.
        let oldStem = EncryptedFileName.stem(actualFilename)
        let newStem = EncryptedFileName.stem(destFilename)
        var stemPairs = [(old: NoteText.safeAssetStem(oldStem), new: NoteText.safeAssetStem(newStem))]
        if oldStem != stemPairs[0].old {
            stemPairs.append((old: oldStem, new: newStem))
        }
        for pair in stemPairs {
            let srcAsset = assetDirURL(stem: pair.old, folder: note.folder)
            let dstAsset = assetDirURL(stem: pair.new, folder: toFolder)
            if FileManager.default.fileExists(atPath: srcAsset.path) {
                try? FileManager.default.moveItem(at: srcAsset, to: dstAsset)
                Log.storage.debug("[Image] moved asset dir for '\(note.title, privacy: .public)' to folder '\(toFolder, privacy: .public)'")
            }
        }

        // Update path and savedAt in sidecar — moveItem advances mtime
        let movedMtime = (try? FileManager.default.attributesOfItem(atPath: newURL.path))?[.modificationDate] as? Date ?? Date()
        if var entry = SidecarStore.shared.noteEntry(for: note.id) {
            entry.path = newRelative
            entry.savedAt = movedMtime
            SidecarStore.shared.upsertNote(entry, for: note.id)
            try? SidecarStore.shared.save()
        }
        return movedMtime
    }

    // MARK: - Trash I/O (Individual Notes)

    /// Move a note from its current location to `.trash/<UUID>_<Title>.md`.
    /// Updates YAML to include `folder:` (return address) and `trashed:`.
    /// Also moves the co-located asset directory to `.trash/.<UUID>_<Title>/`.
    static func trashNote(_ note: Note) throws {
        try ensureTrashExists()
        let trashFilename = Self.trashFilename(for: note)
        let destURL = trashURL.appendingPathComponent(trashFilename)
        let actualFilename = note.savedFilename ?? note.filename
        let oldRelative = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
        let originalURL = rootURL.appendingPathComponent(oldRelative)

        if note.isEncrypted {
            // The ciphertext moves as it is, so no key is needed. Edits of an unlocked
            // note that are not on disk yet are sealed first.
            try writeBody(note.content, of: note, to: originalURL)
            try FileManager.default.moveItem(at: originalURL, to: destURL)
        } else {
            // Write body only to .trash/
            try Data(note.content.utf8).write(to: destURL, options: .atomic)
            try? FileManager.default.removeItem(at: originalURL)
        }
        // The copy above lives in the root's `.trash/`, outside the clone, so the gist sees
        // a deletion; schedule its commit and push now rather than at the next edit.
        if isGistFolder(note.folder) {
            let removedURL = rootURL.appendingPathComponent(oldRelative)
            Task { @MainActor in GitSync.shared.noteActivity(at: removedURL) }
        }

        // Move sidecar entry from notes → trash
        SidecarStore.shared.removeNote(id: note.id)
        let originalPath = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
        SidecarStore.shared.upsertTrash(
            SidecarStore.TrashEntry(
                filename: trashFilename,
                originalPath: originalPath,
                trashedAt: note.trashedAt ?? Date(),
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                tags: note.isEncrypted ? [] : note.tags.map(\.rawValue),
            ),
            for: note.id,
        )
        try? SidecarStore.shared.save()

        // Move asset dir to trash: .My-Note/ → .trash/.<UUID>_My-Note/. A note may have
        // both a safe-stem dir and one from before stems were safe; both go to the same place.
        let trashStem = EncryptedFileName.stem(trashFilename)
        let dstAsset = assetDirURL(stem: trashStem, folder: "", inTrash: true)
        var stems = assetStems(for: note)
        let titleStem = sanitizeForFilename(note.title)
        if !stems.contains(titleStem) {
            stems.append(titleStem)
        }
        for stem in stems {
            let srcAsset = assetDirURL(stem: stem, folder: note.folder)
            if FileManager.default.fileExists(atPath: srcAsset.path) {
                moveOrMergeDirectory(srcAsset, into: dstAsset)
                Log.storage.debug("[Image] moved asset dir to trash for '\(note.title, privacy: .public)'")
            }
        }
    }

    /// Restore a note from `.trash/` back to its original folder.
    /// Returns the new `savedFilename`.
    static func restoreNote(_ note: Note) throws -> (filename: String, savedAt: Date) {
        // Recreate original folder if needed
        if !note.folder.isEmpty {
            try ensureFolderExists(note.folder)
        }

        // Build a restored copy (no trashed/folder fields in YAML)
        var restored = note
        restored.trashedAt = nil

        // A gist file comes back under its own name, unless that name was taken meanwhile.
        let newFilename = restored.isGistFile
            ? unusedFileName(restored.filename, in: rootURL.appendingPathComponent(restored.folder, isDirectory: true))
            : restored.filename
        let destRelative = restored.folder.isEmpty ? newFilename : "\(restored.folder)/\(newFilename)"
        let destURL = rootURL.appendingPathComponent(destRelative)

        // Write body only
        if restored.isEncrypted, let savedFilename = note.savedFilename {
            // The ciphertext moves back as it is; a locked note has no text to write.
            try FileManager.default.moveItem(at: trashURL.appendingPathComponent(savedFilename), to: destURL)
        } else if restored.isEncrypted {
            try writeBody(restored.content, of: restored, to: destURL)
        } else {
            try Data(restored.content.utf8).write(to: destURL, options: .atomic)
        }
        if restored.isGistFile {
            Task { @MainActor in GitSync.shared.noteActivity(at: destURL) }
        }

        // Move sidecar entry from trash → notes
        SidecarStore.shared.removeTrash(id: note.id)
        let savedAt = (try? FileManager.default.attributesOfItem(atPath: destURL.path))?[.modificationDate] as? Date ?? Date()
        SidecarStore.shared.upsertNote(
            SidecarStore.NoteEntry(
                path: destRelative,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                savedAt: savedAt,
                tags: note.isEncrypted ? [] : note.tags.map(\.rawValue),
            ),
            for: note.id,
        )
        try? SidecarStore.shared.save()

        let restoredSavedAt = savedAt

        // Remove from .trash/
        if let savedFilename = note.savedFilename {
            try? FileManager.default.removeItem(at: trashURL.appendingPathComponent(savedFilename))

            // Restore asset dir: .trash/.<UUID>_Title/ → <folder>/.Title/
            let trashStem = EncryptedFileName.stem(savedFilename)
            let restoredStem = NoteText.safeAssetStem(sanitizeForFilename(note.title))
            let srcAsset = assetDirURL(stem: trashStem, folder: "", inTrash: true)
            let dstAsset = assetDirURL(stem: restoredStem, folder: note.folder)
            if FileManager.default.fileExists(atPath: srcAsset.path) {
                try? FileManager.default.moveItem(at: srcAsset, to: dstAsset)
                Log.storage.debug("[Image] restored asset dir for '\(note.title, privacy: .public)'")
            }
        }

        return (filename: newFilename, savedAt: restoredSavedAt)
    }

    /// Delete a trashed note from `.trash/`. Also deletes its asset directory.
    static func deleteTrashedNote(_ note: Note) throws {
        if let savedFilename = note.savedFilename {
            try FileManager.default.removeItem(at: trashURL.appendingPathComponent(savedFilename))

            // Delete asset dir: .trash/.<UUID>_Title/
            let trashStem = EncryptedFileName.stem(savedFilename)
            let assetDir = assetDirURL(stem: trashStem, folder: "", inTrash: true)
            if FileManager.default.fileExists(atPath: assetDir.path) {
                try? FileManager.default.removeItem(at: assetDir)
                Log.storage.debug("[Image] deleted asset dir for permanently deleted note '\(note.title, privacy: .public)'")
            }
        }
        SidecarStore.shared.removeTrash(id: note.id)
        try? SidecarStore.shared.save()
    }

    /// Load individually trashed notes from `.trash/` (top-level `.md` files only).
    static func loadTrashedNotes() throws -> [Note] {
        try ensureTrashExists()
        let contents = try FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )
        let notes = contents.compactMap { url -> Note? in
            guard isMarkdownNote(url), !url.hasDirectoryPath else { return nil }
            return readNote(at: url, folder: "")
        }
        let count = notes.count
        Log.storage.debug("[FileStorage] loaded \(count) trashed notes")
        return notes
    }

    // MARK: - Trash I/O (Folders)

    /// Move a folder to `.trash/<UUID>_<DisplayName>/` and create `.folder.md` metadata.
    static func trashFolder(_ name: String, id: UUID, trashedAt: Date) throws {
        guard !name.isEmpty else { return }
        try ensureTrashExists()
        let displayName = (name as NSString).lastPathComponent
        let trashDirname = "\(id.uuidString)_\(displayName)"
        let sourceURL = rootURL.appendingPathComponent(name, isDirectory: true)
        let destURL = trashURL.appendingPathComponent(trashDirname, isDirectory: true)

        try FileManager.default.moveItem(at: sourceURL, to: destURL)

        // Move sidecar note entries → trash entries for every note inside this folder.
        // The trash entry's `filename` is relative to .trash/ (e.g. "UUID_Projects/Note.md")
        // so `readNote` can find it by full relative path on the next launch.
        let folderPrefix = name + "/"
        let noteKeys = SidecarStore.shared.data.notes.compactMap { kv -> String? in
            kv.value.path.hasPrefix(folderPrefix) ? kv.key : nil
        }
        for key in noteKeys {
            if let entry = SidecarStore.shared.data.notes.removeValue(forKey: key),
               let noteID = UUID(uuidString: key)
            {
                let relativeWithinFolder = String(entry.path.dropFirst(folderPrefix.count))
                SidecarStore.shared.upsertTrash(SidecarStore.TrashEntry(
                    filename: "\(trashDirname)/\(relativeWithinFolder)",
                    originalPath: entry.path,
                    trashedAt: trashedAt,
                    createdAt: entry.createdAt,
                    modifiedAt: entry.modifiedAt,
                    tags: entry.tags,
                ), for: noteID)
            }
        }
        try? SidecarStore.shared.save()

        // Write .folder.md metadata
        let folderMeta = """
        ---
        trashedAt: \(dateFormatter.string(from: trashedAt))
        originalPath: \(name)
        ---
        """
        let metaURL = destURL.appendingPathComponent(".folder.md")
        try Data(folderMeta.utf8).write(to: metaURL, options: .atomic)
    }

    /// Restore a trashed folder back to its original path.
    static func restoreFolder(_ folder: TrashedFolder) throws {
        let sourceURL = trashURL.appendingPathComponent(folder.savedDirname, isDirectory: true)

        // Remove .folder.md before moving back
        let metaURL = sourceURL.appendingPathComponent(".folder.md")
        try? FileManager.default.removeItem(at: metaURL)

        // Ensure parent directory exists
        let parentPath = (folder.originalPath as NSString).deletingLastPathComponent
        if parentPath != ".", !parentPath.isEmpty {
            try ensureFolderExists(parentPath)
        }

        let destURL = rootURL.appendingPathComponent(folder.originalPath, isDirectory: true)
        try FileManager.default.moveItem(at: sourceURL, to: destURL)

        // Move sidecar trash entries back to notes for every note in the restored folder
        let trashPrefix = folder.savedDirname + "/"
        let trashKeys = SidecarStore.shared.data.trash.compactMap { kv -> String? in
            kv.value.filename.hasPrefix(trashPrefix) ? kv.key : nil
        }
        for key in trashKeys {
            if let entry = SidecarStore.shared.data.trash.removeValue(forKey: key),
               let noteID = UUID(uuidString: key)
            {
                // Read actual mtime after moveItem so savedAt matches disk reality.
                // moveItem advances mtime to now; using entry.modifiedAt (the old value)
                // would make checkForExternalChanges see file mtime > savedAt immediately.
                let noteURL = rootURL.appendingPathComponent(entry.originalPath)
                let actualMtime = (try? FileManager.default.attributesOfItem(
                    atPath: noteURL.path,
                ))?[.modificationDate] as? Date ?? entry.modifiedAt

                SidecarStore.shared.upsertNote(SidecarStore.NoteEntry(
                    path: entry.originalPath,
                    createdAt: entry.createdAt,
                    modifiedAt: entry.modifiedAt,
                    savedAt: actualMtime,
                    tags: entry.tags,
                ), for: noteID)
            }
        }
        try? SidecarStore.shared.save()
    }

    /// Permanently delete a trashed folder from `.trash/`.
    static func deleteTrashedFolder(_ folder: TrashedFolder) throws {
        let url = trashURL.appendingPathComponent(folder.savedDirname, isDirectory: true)
        try FileManager.default.removeItem(at: url)

        // Remove sidecar trash entries for every note inside this folder
        let trashPrefix = folder.savedDirname + "/"
        let keysToRemove = SidecarStore.shared.data.trash.compactMap { kv -> String? in
            kv.value.filename.hasPrefix(trashPrefix) ? kv.key : nil
        }
        for key in keysToRemove {
            SidecarStore.shared.data.trash.removeValue(forKey: key)
        }
        if !keysToRemove.isEmpty {
            try? SidecarStore.shared.save()
        }
    }

    /// Load trashed folders from `.trash/` (directories with `.folder.md` metadata).
    static func loadTrashedFolders() throws -> [TrashedFolder] {
        try ensureTrashExists()
        let contents = try FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        )

        var folders: [TrashedFolder] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let metaURL = url.appendingPathComponent(".folder.md")
            guard let data = try? Data(contentsOf: metaURL),
                  let text = String(data: data, encoding: .utf8)
            else { continue }

            let (metadata, _) = parseFrontMatter(text)
            guard let trashedStr = metadata["trashedAt"],
                  let trashedAt = dateFormatter.date(from: trashedStr),
                  let originalPath = metadata["originalPath"]
            else { continue }

            let dirname = url.lastPathComponent
            // Parse UUID from dirname prefix (UUID_DisplayName)
            let id: UUID = if let underscoreIdx = dirname.firstIndex(of: "_"),
                              let parsed = UUID(uuidString: String(dirname[dirname.startIndex ..< underscoreIdx]))
            {
                parsed
            } else {
                UUID()
            }

            let displayName = (originalPath as NSString).lastPathComponent

            // Load all notes inside this trashed folder (recursive)
            let notes = loadNotesRecursively(in: url, baseFolder: originalPath)

            folders.append(TrashedFolder(
                id: id,
                displayName: displayName,
                originalPath: originalPath,
                trashedAt: trashedAt,
                notes: notes,
                savedDirname: dirname,
            ))
        }
        let count = folders.count
        Log.storage.debug("[FileStorage] loaded \(count) trashed folders")
        return folders
    }

    /// Recursively load notes from a directory tree (used for trashed folders).
    private static func loadNotesRecursively(in directoryURL: URL, baseFolder: String) -> [Note] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }

        var notes: [Note] = []
        let basePath = directoryURL.path
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir, isMarkdownNote(url) {
                // Compute the folder relative to the trashed folder root
                let parentDir = url.deletingLastPathComponent().path
                let relativePart = if parentDir.count > basePath.count {
                    String(parentDir.dropFirst(basePath.count + 1))
                } else {
                    ""
                }
                let folder = relativePart.isEmpty ? baseFolder : "\(baseFolder)/\(relativePart)"
                if let note = readNote(at: url, folder: folder) {
                    notes.append(note)
                }
            }
        }
        return notes
    }

    // MARK: - Private Helpers

    private static func loadNotes(in directoryURL: URL, folder: String) throws -> [Note] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
        )
        return contents.compactMap { url -> Note? in
            if isMarkdownNote(url) {
                return readNote(at: url, folder: folder)
            }
            // A gist can hold code and data files too; small UTF-8 ones are listed as
            // plain-text notes, and encrypted ones whatever their size.
            guard isGistFolder(folder),
                  EncryptedFileName.isEncrypted(url.lastPathComponent) || GistTextFile.isEditableText(at: url)
            else { return nil }
            return readNote(at: url, folder: folder)
        }
    }

    /// Text of a note file. A file that is not UTF-8 (or UTF-16 with a BOM) is decoded as
    /// Windows-1252, else Latin-1, so it still shows up; saving it writes UTF-8.
    /// Text of a file in `folder`. Gist files keep their exact bytes (a byte order mark
    /// included); a non-Markdown gist file that is not UTF-8 gives nil.
    static func readText(at url: URL, folder: String) -> String? {
        guard isGistFolder(folder) else { return readText(at: url) }
        if let data = try? Data(contentsOf: url), let text = GistTextFile.decode(data) {
            return text
        }
        return url.pathExtension == "md" ? readText(at: url) : nil
    }

    static func readText(at url: URL) -> String? {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return text
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        Log.storage.info("[FileStorage] \(url.lastPathComponent, privacy: .public) is not UTF-8, read as Windows-1252")
        return NoteText.decodeLegacyEncoding(data)
    }

    private static func readNote(at url: URL, folder: String) -> Note? {
        let filename = url.lastPathComponent
        guard EncryptedFileName.isEncrypted(filename) else {
            guard let text = readText(at: url, folder: folder) else { return nil }
            return makeNote(at: url, folder: folder, text: text)
        }
        // An encrypted file loads without its text while the session is locked, or when
        // it does not decrypt. Its title then comes from the file name, and it has no
        // tags: those are inside the ciphertext, never in the sidecar.
        let body = decryptedText(at: url)
        var note = makeNote(at: url, folder: folder, text: body.text ?? "")
        note.isEncrypted = true
        note.isLocked = body.text == nil
        note.lockError = body.error
        note.tags = body.tags
        if note.isGistFile {
            note.title = EncryptedFileName.plainName(note.title)
        } else if note.isLocked {
            note.title = EncryptedFileName.lockedTitle(fileName: filename, inTrash: url.path.hasPrefix(trashURL.path))
        }
        return note
    }

    /// Builds the note for the file at `url` whose text is `text`, taking id, dates and
    /// tags from the sidecar, from legacy front matter, or from the file itself. The tags
    /// of an encrypted file are not read here: `readNote` takes them from the ciphertext.
    private static func makeNote(at url: URL, folder: String, text: String) -> Note {
        let filename = url.lastPathComponent
        let encrypted = EncryptedFileName.isEncrypted(filename)

        // Determine relative path for sidecar lookup.
        // Trash files live under trashURL, active notes under rootURL.
        let isTrash = url.path.hasPrefix(trashURL.path)
        // A gist file is shown as it is: its title is the file name and nothing is stripped,
        // so saving it writes the same bytes back.
        let inGist = !isTrash && isGistFolder(folder)
        // Full path relative to its storage root (.trash/ or rootURL) so sidecar
        // lookups work for both bare files ("UUID_Title.md") and folder-nested files
        // ("UUID_Projects/SubFolder/Note.md").
        let relativePath: String
        if isTrash {
            let prefix = trashURL.path
            relativePath = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count + 1))
                : filename
        } else {
            let prefix = rootURL.path
            relativePath = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count + 1))
                : filename
        }

        // --- Sidecar path (preferred) ---
        if isTrash {
            if let (id, entry) = SidecarStore.shared.trashEntry(forFilename: relativePath) {
                let folder = (entry.originalPath as NSString).deletingLastPathComponent
                let resolvedFolder = folder == "." || folder.isEmpty ? "" : folder
                // A trashed gist file keeps its original name as title, so it is restored under it.
                let fromGist = isGistFolder(resolvedFolder)
                let content = fromGist ? text : NoteText.strippingLegacyFrontMatter(text) // strip any residual YAML
                let tags = encrypted ? [] : entry.tags.compactMap { TagColor(rawValue: $0) }
                return Note(
                    id: id,
                    title: fromGist ? (entry.originalPath as NSString).lastPathComponent : extractTitle(from: content),
                    content: content,
                    createdAt: entry.createdAt,
                    modifiedAt: entry.modifiedAt,
                    savedAt: entry.modifiedAt,
                    folder: resolvedFolder,
                    tags: tags,
                    trashedAt: entry.trashedAt,
                    savedFilename: filename,
                )
            }
        } else {
            if let (id, entry) = SidecarStore.shared.noteEntry(forPath: relativePath) {
                let content = inGist ? text : NoteText.strippingLegacyFrontMatter(text)
                let tags = encrypted ? [] : entry.tags.compactMap { TagColor(rawValue: $0) }
                return Note(
                    id: id,
                    title: inGist ? filename : extractTitle(from: content),
                    content: content,
                    createdAt: entry.createdAt,
                    modifiedAt: entry.modifiedAt,
                    savedAt: entry.savedAt,
                    folder: folder,
                    tags: tags,
                    savedFilename: filename,
                )
            }
        }

        // --- YAML fallback (unmigrated EdgeMark file or sidecar entry missing) ---
        // Only EdgeMark's own block (with an `id:` UUID) is metadata; user YAML stays content.
        if !inGist, case let (metadata, body)? = NoteText.legacyFrontMatter(text) {
            let id = metadata["id"].flatMap { UUID(uuidString: $0) } ?? UUID()
            let title = metadata["title"] ?? extractTitle(from: body)
            let created = metadata["created"].flatMap { dateFormatter.date(from: $0) } ?? Date()
            let modified = metadata["modified"].flatMap { dateFormatter.date(from: $0) } ?? Date()
            let trashed = metadata["trashed"].flatMap { dateFormatter.date(from: $0) }
            let tags = encrypted ? [] : parseTagList(metadata["tags"] ?? "")
            // `folder:` is the return address EdgeMark wrote for trashed notes only; an
            // active note stays in the folder its file is in.
            let resolvedFolder = isTrash ? (metadata["folder"] ?? folder) : folder

            // Inject into sidecar so future reads don't need to parse YAML
            if isTrash {
                let originalPath = resolvedFolder.isEmpty ? "\(title).md" : "\(resolvedFolder)/\(title).md"
                SidecarStore.shared.upsertTrash(SidecarStore.TrashEntry(
                    filename: relativePath,
                    originalPath: originalPath,
                    trashedAt: trashed ?? modified,
                    createdAt: created,
                    modifiedAt: modified,
                    tags: tags.map(\.rawValue),
                ), for: id)
            } else {
                SidecarStore.shared.upsertNote(SidecarStore.NoteEntry(
                    path: relativePath,
                    createdAt: created,
                    modifiedAt: modified,
                    savedAt: modified,
                    tags: tags.map(\.rawValue),
                ), for: id)
            }
            try? SidecarStore.shared.save()

            return Note(
                id: id,
                title: title,
                content: body,
                createdAt: created,
                modifiedAt: modified,
                savedAt: modified,
                folder: resolvedFolder,
                tags: tags,
                trashedAt: trashed,
                savedFilename: filename,
            )
        }

        // --- External file: no sidecar entry, no YAML ---
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = resourceValues?.creationDate ?? Date()
        let modified = resourceValues?.contentModificationDate ?? Date()
        let id = UUID()

        if isTrash {
            SidecarStore.shared.upsertTrash(SidecarStore.TrashEntry(
                filename: relativePath,
                originalPath: "\(folder.isEmpty ? "" : folder + "/")\(filename)",
                trashedAt: modified,
                createdAt: created,
                modifiedAt: modified,
                tags: [],
            ), for: id)
        } else {
            SidecarStore.shared.upsertNote(SidecarStore.NoteEntry(
                path: relativePath,
                createdAt: created,
                modifiedAt: modified,
                savedAt: modified,
                tags: [],
            ), for: id)
        }
        try? SidecarStore.shared.save()

        return Note(
            id: id,
            title: inGist ? filename : extractTitle(from: text),
            content: text,
            createdAt: created,
            modifiedAt: modified,
            savedAt: modified,
            folder: folder,
            savedFilename: filename,
        )
    }

    /// Parses `[red, blue]` (with or without surrounding brackets / quotes / spaces)
    /// into a list of valid TagColors. Unknown names are silently dropped.
    private static func parseTagList(_ raw: String) -> [TagColor] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let stripped = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return stripped.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .compactMap { TagColor(rawValue: $0.lowercased()) }
    }

    // MARK: - Front Matter

    /// Any leading `---` block. Only for EdgeMark's own files such as `.folder.md`; note
    /// files go through `NoteText.legacyFrontMatter` so user YAML is never stripped.
    static func parseFrontMatter(_ text: String) -> (metadata: [String: String], body: String) {
        NoteText.frontMatter(text) ?? ([:], text)
    }

    static func serializeFrontMatter(note: Note) -> String {
        var lines = ["---"]
        lines.append("id: \(note.id.uuidString)")
        lines.append("title: \(note.title)")
        lines.append("created: \(dateFormatter.string(from: note.createdAt))")
        lines.append("modified: \(dateFormatter.string(from: note.modifiedAt))")
        if !note.tags.isEmpty {
            let names = note.tags.map(\.rawValue).joined(separator: ", ")
            lines.append("tags: [\(names)]")
        }
        if let trashedAt = note.trashedAt {
            lines.append("trashed: \(dateFormatter.string(from: trashedAt))")
            // Persist original folder as return address while in .trash/
            if !note.folder.isEmpty {
                lines.append("folder: \(note.folder)")
            }
        }
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Resolve duplicate filenames after loading. Oldest note (by createdAt) keeps its name;
    /// newer duplicates get a number suffix ("Title 2", "Title 3", etc.).
    private static func resolveDuplicateFilenames(_ notes: [Note]) throws -> [Note] {
        var groups: [String: [Int]] = [:]
        // Gist files keep their names (see `isGistFolder`), so they are never renamed here.
        for (i, note) in notes.enumerated() where !isGistFolder(note.folder) && !note.isEncrypted {
            let key = "\(note.folder)/\(note.filename.lowercased())"
            groups[key, default: []].append(i)
        }

        var result = notes
        for (_, indices) in groups where indices.count > 1 {
            let sorted = indices.sorted { result[$0].createdAt < result[$1].createdAt }
            for duplicateIndex in sorted.dropFirst() {
                var note = result[duplicateIndex]
                let baseTitle = note.title
                var counter = 2
                var newTitle = "\(baseTitle) \(counter)"
                while result.contains(where: {
                    $0.folder == note.folder
                        && sanitizeForFilename($0.title).caseInsensitiveCompare(sanitizeForFilename(newTitle)) == .orderedSame
                }) {
                    counter += 1
                    newTitle = "\(baseTitle) \(counter)"
                }

                let oldURL = rootURL.appendingPathComponent(note.relativePath)
                Log.storage.info("[FileStorage] resolved duplicate: \(baseTitle, privacy: .public) → \(newTitle, privacy: .public)")
                note.title = newTitle
                // Update # heading in content
                var lines = note.content.components(separatedBy: "\n")
                if let headingIdx = lines.firstIndex(where: { $0.hasPrefix("#") }) {
                    let prefix = String(lines[headingIdx].prefix(while: { $0 == "#" }))
                    lines[headingIdx] = "\(prefix) \(newTitle)"
                    note.content = lines.joined(separator: "\n")
                }
                let newURL = rootURL.appendingPathComponent(note.relativePath)
                try Data(note.content.utf8).write(to: newURL, options: .atomic)
                if oldURL != newURL {
                    try? FileManager.default.removeItem(at: oldURL)
                }
                note.savedFilename = note.filename
                // Update sidecar path for the renamed note
                if var entry = SidecarStore.shared.noteEntry(for: note.id) {
                    entry.path = note.relativePath
                    SidecarStore.shared.upsertNote(entry, for: note.id)
                }
                result[duplicateIndex] = note
            }
        }
        try? SidecarStore.shared.save()
        return result
    }

    private static func extractTitle(from content: String) -> String {
        NoteText.title(from: content)
    }

    // MARK: - Sync helpers

    /// True when the note has a co-located image directory. Gists cannot hold directories.
    static func hasAssetDirectory(for note: Note) -> Bool {
        assetStems(for: note).contains {
            FileManager.default.fileExists(atPath: assetDirURL(stem: $0, folder: note.folder).path)
        }
    }
}
