import AppKit
import Security
import SwiftUI

/// Setup sheet for note encryption: choose where the key lives, create or restore it,
/// check that it reads back, then record the recipient. Settings are written only after
/// the check passes, so cancelling at any earlier point changes nothing there.
struct EncryptionWizardView: View {
    private enum Step {
        case choose, restore, recovery, verify
    }

    @Environment(L10n.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var step = Step.choose
    @State private var hasKey = false
    @State private var pastedKey = ""
    @State private var identity: AgeIdentity?
    @State private var savedRecoveryKey = false
    @State private var verified = false
    @State private var error: String?
    @State private var busy = false
    /// The user agreed to replace the key that existing notes are encrypted to.
    @State private var replaceConfirmed = false

    private var store: any KeyStore {
        KeychainKeyStore(reason: l10n["encryption.unlockReason"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n["encryption.wizard.title"])
                .font(.title3.bold())
            switch step {
            case .choose: chooseStep
            case .restore: restoreStep
            case .recovery: recoveryStep
            case .verify: verifyStep
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            // The secret must not outlive the sheet in view state.
            identity = nil
            pastedKey = ""
            // A cancelled run must not encrypt the note that opened it on a later one.
            SettingsRouter.shared.encryptAfterSetup = nil
        }
    }

    // MARK: - Steps

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n["encryption.wizard.choose"])
            Label(l10n["encryption.store.keychain"], systemImage: "key")
            Text(l10n["encryption.wizard.keychainHint"])
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(l10n["encryption.wizard.haveKey"], isOn: $hasKey)
            footer(next: l10n["encryption.wizard.continue"]) {
                if hasKey {
                    step = .restore
                } else {
                    run { try await createKey() }
                }
            }
        }
    }

    private var restoreStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n["encryption.wizard.restore"])
            SecureField("AGE-SECRET-KEY-1...", text: $pastedKey)
                .textFieldStyle(.roundedBorder)
            footer(next: l10n["encryption.wizard.continue"], disabled: pastedKey.isEmpty) {
                run { try await restoreKey() }
            }
        }
    }

    private var recoveryStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n["encryption.wizard.recovery"])
            Text(identity?.string ?? "")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(l10n["encryption.wizard.copyKey"]) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(identity?.string ?? "", forType: .string)
                // Marks the copy as concealed so clipboard managers skip it.
                NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            }
            Toggle(l10n["encryption.wizard.savedIt"], isOn: $savedRecoveryKey)
            footer(next: l10n["encryption.wizard.continue"], disabled: !savedRecoveryKey) {
                step = .verify
            }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if verified {
                Label(l10n["encryption.wizard.verified"], systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(l10n["encryption.wizard.facts.keychain"])
                    .font(.callout)
                Text(l10n["encryption.wizard.facts.format"])
                    .font(.callout)
                HStack {
                    Spacer()
                    Button(l10n["encryption.wizard.done"]) { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(l10n["encryption.wizard.verifying"])
                footer(next: l10n["encryption.wizard.retry"]) {
                    run { try await verify() }
                }
            }
        }
        .task {
            // Restoring verifies by itself, so only start a check nobody has started.
            guard !busy, !verified else { return }
            run { try await verify() }
        }
    }

    /// Cancel on the left, the step's main button on the right.
    private func footer(next: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Button(l10n["common.cancel"]) { dismiss() }
            Spacer()
            Button(next, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || busy)
        }
    }

    // MARK: - Actions

    /// Runs one step's work, showing its error line under the step.
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = EncryptionMessages.text(for: error, l10n: l10n)
            }
            busy = false
        }
    }

    /// A key item left by an earlier, cancelled run is reused, never overwritten: notes
    /// may already be encrypted to it. It is read through the store, so showing it as a
    /// recovery key takes the same presence prompt as in Settings.
    /// A fresh key is made only when the Keychain says the item does not exist; a denied
    /// prompt or a locked Keychain creates nothing, and the fresh key is added, never
    /// written over an item that appeared meanwhile.
    private func createKey() async throws {
        let existing = KeychainKeyStore.item.readWithStatus()
        switch existing.status {
        case errSecItemNotFound:
            let fresh = AgeIdentity.generate()
            let status = KeychainKeyStore.item.add(fresh.string)
            guard status == errSecSuccess else { throw KeyStoreError.unavailable(Self.message(for: status)) }
            identity = fresh
        case errSecSuccess:
            identity = try await store.load()
        default:
            throw KeyStoreError.unavailable(Self.message(for: existing.status))
        }
        step = .recovery
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }

    /// Saves the pasted key, then verifies it right away. Saving replaces the key item
    /// in place, so a different key already stored here is only replaced after the user
    /// confirmed: it may be the only copy of the key some notes are encrypted to.
    private func restoreKey() async throws {
        guard let restored = AgeIdentity(bech32: pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw KeyStoreError.invalid
        }
        let stored = KeychainKeyStore.item.read().flatMap(AgeIdentity.init(bech32:))
        if let stored, stored.recipient != restored.recipient {
            guard confirmReplacingKey() else { throw KeyStoreError.cancelled }
        }
        let session = KeySession.shared
        let settings = EncryptionSettings.shared
        let changes = session.identity.map { $0.recipient != restored.recipient } ?? false
            || (settings.isSetUp && settings.recipient != restored.recipient.string)
        try await store.save(restored)
        if changes {
            // The running session would keep sealing edits to the old recipient.
            session.lock()
            // The replacement is confirmed and stored, so settings follow it now: closing
            // the sheet before Done must not leave them naming a key that is gone.
            if settings.isSetUp {
                settings.recipient = restored.recipient.string
            }
        }
        identity = restored
        pastedKey = ""
        step = .verify
        try await verify()
    }

    /// True when the notes encrypted so far use another key than `recipient`.
    private func replacesCurrentKey(_ recipient: AgeRecipient) -> Bool {
        let settings = EncryptionSettings.shared
        return settings.isSetUp && settings.recipient != recipient.string
    }

    /// Asks before the key in use is replaced by a different one. Asked once per run.
    private func confirmReplacingKey() -> Bool {
        guard !replaceConfirmed else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = l10n["encryption.replaceKey.title"]
        alert.informativeText = l10n["encryption.replaceKey.message"]
        alert.addButton(withTitle: l10n["common.cancel"])
        alert.addButton(withTitle: l10n["encryption.replaceKey.confirm"])
        replaceConfirmed = alert.runModal() == .alertSecondButtonReturn
        return replaceConfirmed
    }

    /// Reads the identity back through the store and proves that it opens what its
    /// recipient seals.
    private func verify() async throws {
        let loaded = try await store.load()
        if let identity, identity.recipient != loaded.recipient { throw KeySessionError.recipientMismatch }
        let probe = Data("EdgeMark".utf8)
        guard try Age.decrypt(Age.encrypt(probe, to: loaded.recipient), with: loaded) == probe else {
            throw AgeError.corruptPayload
        }
        identity = loaded
        verified = true
    }

    /// Records the setup, starts a session with the key just checked, and encrypts the
    /// note that opened the wizard, if one did.
    private func finish() {
        guard let identity else { return }
        // Also reached with a fresh key when the old item is gone from the Keychain.
        if replacesCurrentKey(identity.recipient), !confirmReplacingKey() {
            return
        }
        let settings = EncryptionSettings.shared
        settings.store = .keychain
        settings.keyURI = ""
        settings.recipient = identity.recipient.string
        KeySession.shared.lock()
        KeySession.shared.begin(with: identity)
        let router = SettingsRouter.shared
        if let noteID = router.encryptAfterSetup,
           let noteStore = AppDelegate.shared?.panelController?.noteStore,
           let note = noteStore.notes.first(where: { $0.id == noteID })
        {
            noteStore.requestEncrypt(note)
        }
        router.encryptAfterSetup = nil
        dismiss()
    }
}
