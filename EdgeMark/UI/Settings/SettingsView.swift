import SwiftUI

enum SettingsTab: Hashable {
    case general, behavior, tags, keyboard, sync, security, about
}

/// Lets other UI (the footer dot) ask the Settings window to open on a given tab.
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var tab: SettingsTab = .general
    /// True while the encryption setup wizard is presented on the Security tab.
    var showEncryptionWizard = false
    /// Note to encrypt when the wizard finishes, set when an Encrypt action opened it.
    var encryptAfterSetup: UUID?

    /// Opens Settings on the Security tab with the setup wizard presented.
    func openEncryptionWizard(thenEncrypt noteID: UUID? = nil) {
        tab = .security
        encryptAfterSetup = noteID
        showEncryptionWizard = true
        AppDelegate.shared?.openSettings()
    }
}

struct SettingsView: View {
    @Environment(L10n.self) var l10n
    @Bindable private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.general"], systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            BehaviorSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.behavior"], systemImage: "macwindow.on.rectangle")
                }
                .tag(SettingsTab.behavior)

            TagsSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.tags"], systemImage: "tag")
                }
                .tag(SettingsTab.tags)

            KeyboardSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.keyboard"], systemImage: "keyboard")
                }
                .tag(SettingsTab.keyboard)

            SyncSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.sync"], systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .tag(SettingsTab.sync)

            SecuritySettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.security"], systemImage: "lock")
                }
                .tag(SettingsTab.security)

            AboutSettingsTab()
                .tabItem {
                    Label(l10n["settings.tab.about"], systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .background(FixedWindowTitle(title: l10n["settings.windowTitle"]))
        .frame(width: 520, height: 460)
    }
}

// MARK: - Window title override

/// Forces a fixed window title via KVO, overriding the TabView's default
/// behavior of changing the title to match the selected tab name.
private struct FixedWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> TitleFixView {
        TitleFixView(fixedTitle: title)
    }

    func updateNSView(_ nsView: TitleFixView, context _: Context) {
        nsView.fixedTitle = title
        nsView.applyTitle()
    }

    final class TitleFixView: NSView {
        var fixedTitle: String
        private var observation: NSKeyValueObservation?

        init(fixedTitle: String) {
            self.fixedTitle = fixedTitle
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.title, options: [.new]) { [weak self] window, _ in
                guard let self, window.title != self.fixedTitle else { return }
                window.title = fixedTitle
            }
            applyTitle()
        }

        func applyTitle() {
            guard let window, window.title != fixedTitle else { return }
            window.title = fixedTitle
        }
    }
}
