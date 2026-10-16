import SwiftUI

/// Shown in place of the editor for an encrypted note whose text is not in memory. Asks
/// for the key once when it appears; after a refusal the Unlock button asks again.
struct LockedNoteView: View {
    let note: Note

    @Environment(NoteStore.self) private var noteStore
    @Environment(L10n.self) private var l10n
    @State private var message: String?
    @State private var offersSetup = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.panel(.largeTitle))
                .foregroundStyle(.secondary)
            Text(l10n["encryption.locked.title"])
                .font(.panel(.headline))
            if let text = message ?? note.lockError.map({ l10n["encryption.error.\($0)"] }) {
                Text(text)
                    .font(.panel(.caption1))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            Button(l10n["encryption.unlock"]) { unlock() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            if offersSetup {
                Button(l10n["encryption.runSetupAgain"]) {
                    SettingsRouter.shared.openEncryptionWizard()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { unlock() }
    }

    private func unlock() {
        guard !busy else { return }
        busy = true
        Task {
            let error = await noteStore.unlock()
            busy = false
            message = error.flatMap { EncryptionMessages.text(for: $0, l10n: l10n) }
            offersSetup = error.map(EncryptionMessages.needsSetup) ?? false
        }
    }
}

/// Lock and title for a locked note in a read-only preview (hover peek, Trash). It never
/// asks for the key.
struct LockedNotePlaceholder: View {
    @Environment(L10n.self) private var l10n

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.panel(.largeTitle))
                .foregroundStyle(.secondary)
            Text(l10n["encryption.locked.title"])
                .font(.panel(.headline))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
