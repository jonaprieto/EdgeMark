import AppKit
import Foundation

/// Encrypting, decrypting, unlocking and locking notes.
extension NoteStore {
    // MARK: - Session

    /// Unlocks the key session if needed, then loads the text and tags of every encrypted
    /// note. Returns nil on success, else the error that kept the session locked.
    func unlock() async -> Error? {
        do {
            try await KeySession.shared.unlock()
        } catch {
            return error
        }
        // ponytail: decrypts every encrypted note on the main actor in one go; load on
        // open instead if someone keeps hundreds of them.
        for i in notes.indices where notes[i].isEncrypted && notes[i].isLocked {
            notes[i] = FileStorage.unlocked(notes[i])
        }
        if let open = selectedNote, let fresh = notes.first(where: { $0.id == open.id }) {
            selectedNote = fresh
            // An editor mounted while the note was locked holds an empty buffer; typing
            // into it would save that over the real text.
            if open.isLocked, !fresh.isLocked {
                onNeedEditorReload?(fresh.content)
            }
        }
        recomputeAllUsedTags()
        return nil
    }

    /// Drops the text and tags of every encrypted note from memory. Called when the key
    /// session locks. Pending edits are sealed first, which needs only the recipient; a
    /// note whose save failed keeps its text, since dropping it would lose the edit.
    func lockEncryptedNotes() {
        isLockingEncryptedNotes = true
        defer { isLockingEncryptedNotes = false }
        onFlushEditor?()
        saveDirtyNotes()
        if selectedNote?.isEncrypted == true {
            closeNote()
        }
        // The edit was just saved over the disk version, so the prompt has nothing left to ask.
        if let pending = pendingExternalChange, notes.first(where: { $0.id == pending.noteID })?.isEncrypted == true {
            pendingExternalChange = nil
        }
        for i in notes.indices where notes[i].isEncrypted && !dirtyNoteIDs.contains(notes[i].id) {
            Self.drop(&notes[i])
        }
        for i in trashedNotes.indices where trashedNotes[i].isEncrypted {
            Self.drop(&trashedNotes[i])
        }
        for f in trashedFolders.indices {
            for i in trashedFolders[f].notes.indices where trashedFolders[f].notes[i].isEncrypted {
                Self.drop(&trashedFolders[f].notes[i])
            }
        }
        recomputeAllUsedTags()
    }

    private static func drop(_ note: inout Note) {
        note.content = ""
        note.tags = []
        note.isLocked = true
    }

    // MARK: - Encrypt and decrypt

    /// The context menu's Encrypt. Opens the setup wizard when encryption is not set up;
    /// otherwise warns once about plaintext already in git history, then seals the note.
    func requestEncrypt(_ note: Note) {
        let settings = EncryptionSettings.shared
        guard settings.isSetUp else {
            SettingsRouter.shared.openEncryptionWizard(thenEncrypt: note.id)
            return
        }
        guard settings.historyWarningShown || confirmHistoryWarning() else { return }
        settings.historyWarningShown = true
        Task { await encrypt(noteID: note.id) }
    }

    /// The context menu's Decrypt Permanently: the note becomes a plaintext file again, and
    /// its tags go back into the sidecar.
    func decryptPermanently(_ note: Note) {
        Task {
            guard await unlockOrReport() else { return }
            saveDirtyNotes()
            guard let index = notes.firstIndex(where: { $0.id == note.id }),
                  notes[index].isEncrypted else { return }
            guard !notes[index].isLocked else {
                // Its file failed to decrypt, so there is no text to write back.
                report(AgeError.corruptPayload)
                return
            }
            do {
                let result = try FileStorage.decryptNote(notes[index])
                notes[index].isEncrypted = false
                noteFileChanged(at: index, filename: result.filename, savedAt: result.savedAt)
            } catch {
                report(error)
            }
        }
    }

    /// Unlocks first, so the new file can be read back before the plaintext is removed. The
    /// note's tags move from the sidecar into the ciphertext in the same step.
    private func encrypt(noteID: UUID) async {
        guard await unlockOrReport() else { return }
        saveDirtyNotes()
        guard let index = notes.firstIndex(where: { $0.id == noteID }), !notes[index].isEncrypted,
              let identity = KeySession.shared.identity,
              let recipient = EncryptionSettings.shared.ageRecipient else { return }
        do {
            let result = try FileStorage.encryptNote(notes[index], recipient: recipient, identity: identity)
            notes[index].isEncrypted = true
            noteFileChanged(at: index, filename: result.filename, savedAt: result.savedAt)
        } catch {
            report(error)
        }
    }

    private func noteFileChanged(at index: Int, filename: String, savedAt: Date) {
        notes[index].savedFilename = filename
        notes[index].savedAt = savedAt
        if selectedNote?.id == notes[index].id {
            selectedNote = notes[index]
        }
    }

    private func unlockOrReport() async -> Bool {
        guard let error = await unlock() else { return true }
        report(error)
        return false
    }

    /// A toast with the reason; nothing for a dismissed presence prompt.
    private func report(_ error: Error) {
        guard let text = EncryptionMessages.text(for: error, l10n: .shared) else { return }
        FeedbackToast.shared.show(L10n.shared.t("encryption.failed", text), isError: true)
    }

    /// Shown once: text that was already pushed stays in git history and gist revisions.
    private func confirmHistoryWarning() -> Bool {
        let l10n = L10n.shared
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n["encryption.historyWarning.title"]
        alert.informativeText = l10n["encryption.historyWarning.message"]
        alert.addButton(withTitle: l10n["encryption.encrypt"])
        alert.addButton(withTitle: l10n["common.cancel"])
        return alert.runModal() == .alertFirstButtonReturn
    }
}
