import AppKit
import SwiftUI

struct SecuritySettingsTab: View {
    @Environment(L10n.self) private var l10n
    @Bindable private var settings = EncryptionSettings.shared
    @Bindable private var router = SettingsRouter.shared
    private let session = KeySession.shared

    @State private var recoveryKey: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section(l10n["encryption.section"]) {
                if settings.isSetUp {
                    status
                } else {
                    Text(l10n["encryption.intro"])
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(l10n["encryption.setUp"]) { router.showEncryptionWizard = true }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $router.showEncryptionWizard) {
            EncryptionWizardView()
        }
        .onDisappear { recoveryKey = nil }
        .onReceive(NotificationCenter.default.publisher(for: .keySessionDidLock)) { _ in recoveryKey = nil }
    }

    @ViewBuilder
    private var status: some View {
        LabeledContent(l10n["encryption.recipient"]) {
            Text(settings.recipient)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        LabeledContent(l10n["encryption.store"]) {
            Text(l10n[settings.store == .keychain ? "encryption.store.keychain" : "encryption.store.protonPass"])
        }
        LabeledContent(l10n["encryption.status"]) {
            Text(l10n[session.isUnlocked ? "encryption.unlocked" : "encryption.lockedState"])
        }
        HStack {
            Text(l10n["encryption.idleMinutes"])
            Slider(value: $settings.idleMinutes, in: 1 ... 60, step: 1)
            Text("\(Int(settings.idleMinutes)) min")
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
        HStack {
            Button(l10n["encryption.lockNow"]) { session.lock() }
                .disabled(!session.isUnlocked)
            Button(l10n["encryption.runSetupAgain"]) { router.showEncryptionWizard = true }
            if settings.store == .keychain {
                Button(l10n[recoveryKey == nil ? "encryption.showRecoveryKey" : "encryption.hideRecoveryKey"]) {
                    toggleRecoveryKey()
                }
            }
        }
        if let recoveryKey {
            Text(recoveryKey)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    /// Shows the identity after the same presence prompt an unlock uses.
    private func toggleRecoveryKey() {
        guard recoveryKey == nil else {
            recoveryKey = nil
            return
        }
        Task {
            do {
                recoveryKey = try await KeychainKeyStore(reason: l10n["encryption.recoveryReason"]).load().string
                message = nil
            } catch {
                message = EncryptionMessages.text(for: error, l10n: l10n)
            }
        }
    }
}
