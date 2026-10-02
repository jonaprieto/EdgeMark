import AppKit
import SwiftUI

struct SyncSettingsTab: View {
    @Environment(L10n.self) private var l10n
    @Bindable private var settings = SyncSettings.shared
    private let sync = GitSync.shared

    @State private var accounts: [String] = []
    @State private var remote: String?
    @State private var repoName = ""
    @State private var ownerRepo = ""
    @State private var busy = false

    private var gitPath: String? { Shell.find("git") }
    private var ghPath: String? { Shell.find("gh") }

    var body: some View {
        Form {
            statusSection
            if sync.rootRepo == nil {
                setupSection
            }
            optionsSection
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: sync.state) { _, _ in Task { await refresh() } }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section(l10n["sync.status"]) {
            LabeledContent(l10n["sync.tools"]) {
                if let gitPath, let ghPath {
                    Text("\(gitPath), \(ghPath)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(l10n["sync.toolsMissing"]).foregroundStyle(.red)
                }
            }
            if accounts.isEmpty {
                LabeledContent(l10n["sync.account"]) {
                    Text(l10n["sync.accountNone"]).foregroundStyle(.secondary)
                }
            } else {
                Picker(l10n["sync.account"], selection: $settings.account) {
                    ForEach(accounts, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent(l10n["sync.root"]) {
                Text(sync.root?.path ?? "-").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent(l10n["sync.remote"]) {
                Text(remote ?? l10n["sync.remoteNone"]).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent(l10n["sync.gists"]) {
                Text("\(sync.gistRepos().count)")
            }
            LabeledContent(l10n["sync.status"]) {
                HStack {
                    SyncStatusDot(state: sync.state)
                    Text(sync.state.summary).textSelection(.enabled)
                }
            }
            if let error = sync.lastSetupError {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button(l10n["sync.syncNow"]) { Task { await run { await sync.syncNow() } } }
                    .disabled(!sync.isActive || busy)
                Button(l10n["sync.openOnGitHub"]) { Task { await openOnGitHub() } }
                    .disabled(remote == nil)
                Button(l10n["sync.copyGitStatus"]) { Task { await copyGitStatus() } }
                    .disabled(sync.rootRepo == nil)
            }
        }
    }

    private var setupSection: some View {
        Section(l10n["sync.setup"]) {
            HStack {
                TextField(l10n["sync.repoName"], text: $repoName)
                Button(l10n["sync.createRepo"]) {
                    Task { await run { sync.lastSetupError = await sync.createPrivateRepo(named: repoName) } }
                }
                .disabled(repoName.isEmpty || settings.account.isEmpty || busy)
            }
            HStack {
                TextField(l10n["sync.ownerRepo"], text: $ownerRepo)
                Button(l10n["sync.connectExisting"]) {
                    Task { await run { sync.lastSetupError = await sync.connectExisting(ownerRepo) } }
                }
                .disabled(!ownerRepo.contains("/") || settings.account.isEmpty || busy)
            }
        }
    }

    private var optionsSection: some View {
        Section(l10n["sync.options"]) {
            Toggle(l10n["sync.enabled"], isOn: $settings.enabled)
            LabeledContent(l10n["sync.debounce"]) {
                HStack {
                    Slider(value: $settings.debounceSeconds, in: 30 ... 600, step: 30)
                    Text(l10n.t("sync.seconds", "\(Int(settings.debounceSeconds))"))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            LabeledContent(l10n["sync.template"]) {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField("", text: $settings.commitTemplate).frame(width: 240)
                    Text(l10n["sync.templateHelp"]).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Toggle(l10n["sync.pushOnQuit"], isOn: $settings.pushOnQuit)
            Toggle(l10n["sync.syncGists"], isOn: $settings.syncGists)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        accounts = await GistCatalog.accounts()
        if settings.account.isEmpty, let first = accounts.first {
            settings.account = first
        }
        remote = await sync.rootRepo?.originURL()
        if repoName.isEmpty {
            repoName = sync.root?.lastPathComponent ?? "notes"
        }
    }

    private func run(_ work: () async -> Void) async {
        busy = true
        await work()
        busy = false
        await refresh()
    }

    private func openOnGitHub() async {
        guard let root = sync.root else { return }
        _ = await Shell.run("gh", ["repo", "view", "--web"], cwd: root)
    }

    private func copyGitStatus() async {
        guard let root = sync.root else { return }
        var text = ""
        for repo in sync.repos() {
            let r = await repo.git("status", "--short", "--branch")
            text += "## \(repo.url.path.replacingOccurrences(of: root.path, with: "."))\n\(r.stdout)\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
