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
    @State private var apiKey = ""
    @State private var keyStored = false

    private var gitPath: String? { Shell.find("git") }
    private var ghPath: String? { Shell.find("gh") }

    var body: some View {
        Form {
            statusSection
            if sync.rootRepo == nil {
                setupSection
            }
            optionsSection
            guardSection
        }
        .formStyle(.grouped)
        .task {
            keyStored = KeychainStore.read() != nil
            await refreshAccounts()
            await refreshRemote()
        }
        .onChange(of: sync.state) { _, _ in Task { await refreshRemote() } }
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
            if let advice = SyncAdvice.current(sync, l10n: l10n) {
                Text(advice.text).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if case .conflict = sync.state {
                    HStack {
                        Button(l10n["sync.copyFixCommands"]) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(advice.fixCommands, forType: .string)
                        }
                        .help(l10n["tooltip.sync.copyFix"])
                        Button(l10n["common.showInFinder"]) {
                            NSWorkspace.shared.activateFileViewerSelecting([advice.repo])
                        }
                        .help(l10n["tooltip.sync.showRepo"])
                    }
                }
            }
            if let error = sync.lastSetupError {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button(l10n["sync.syncNow"]) { Task { await run { await sync.syncNow() } } }
                    .disabled(!sync.isActive || busy)
                    .help(l10n["tooltip.sync.syncNow"])
                Button(l10n["sync.openOnGitHub"]) { Task { await openOnGitHub() } }
                    .disabled(remote == nil)
                    .help(l10n["tooltip.sync.openOnGitHub"])
                Button(l10n["sync.copyGitStatus"]) { Task { await copyGitStatus() } }
                    .disabled(sync.rootRepo == nil)
                    .help(l10n["tooltip.sync.copyStatus"])
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
                .help(l10n["tooltip.sync.createRepo"])
            }
            HStack {
                TextField(l10n["sync.ownerRepo"], text: $ownerRepo)
                Button(l10n["sync.connectExisting"]) {
                    Task { await run { sync.lastSetupError = await sync.connectExisting(ownerRepo) } }
                }
                .disabled(!ownerRepo.contains("/") || settings.account.isEmpty || busy)
                .help(l10n["tooltip.sync.connect"])
            }
        }
    }

    private var optionsSection: some View {
        Section(l10n["sync.options"]) {
            Toggle(l10n["sync.enabled"], isOn: $settings.enabled)
            LabeledContent(l10n["sync.debounce"]) {
                HStack {
                    Slider(value: $settings.debounceSeconds, in: 30 ... 600, step: 30)
                        .help(l10n["tooltip.sync.debounce"])
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
            if !settings.ignoredGistIDs.isEmpty {
                hiddenGists
            }
        }
    }

    /// Gists removed with "Only Remove Here"; Unhide lets discovery clone them again.
    private var hiddenGists: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n["sync.hiddenGists"])
            ForEach(settings.ignoredGistIDs.sorted(), id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        if let description = sync.gistDescriptions[id] {
                            Text(description).font(.callout)
                        }
                        Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(l10n["sync.unhideGist"]) {
                        sync.unhideGist(id: id)
                        Task { await sync.pullAll(force: true) }
                    }
                    .help(l10n["tooltip.sync.unhideGist"])
                }
            }
        }
    }

    private var keyStatus: String {
        if keyStored { return l10n["sync.guard.keySaved"] }
        if ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?.isEmpty == false { return l10n["sync.guard.envKey"] }
        return l10n["sync.guard.noKey"]
    }

    private var guardSection: some View {
        Section(l10n["sync.guard.section"]) {
            Toggle(l10n["sync.guard.enabled"], isOn: $settings.guardEnabled)
            LabeledContent(l10n["sync.guard.apiKey"]) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack {
                        SecureField("", text: $apiKey).frame(width: 200)
                        Button(l10n["sync.guard.saveKey"]) {
                            keyStored = KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(l10n["tooltip.guard.saveKey"])
                        Button(l10n["sync.guard.removeKey"]) {
                            KeychainStore.delete()
                            keyStored = KeychainStore.read() != nil
                        }
                        .disabled(!keyStored)
                        .help(l10n["tooltip.guard.removeKey"])
                    }
                    Text(keyStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(l10n["sync.guard.disclosure"]).font(.caption).foregroundStyle(.secondary)
            if !sync.guardStatus.isEmpty {
                LabeledContent(l10n["sync.guard.status"]) {
                    Text(sync.guardStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(heldRows, id: \.file) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.display).font(.callout)
                        Text(row.verdict.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button(l10n["sync.guard.allow"]) {
                        sync.allowHeld(path: row.verdict.path, in: GitRepo(url: row.repo))
                    }
                    .help(l10n["tooltip.guard.allow"])
                    Button(l10n["common.showInFinder"]) {
                        NSWorkspace.shared.activateFileViewerSelecting([row.file])
                    }
                    .help(l10n["tooltip.guard.showFile"])
                }
            }
        }
    }

    /// Held files of every repo, with paths shown relative to the notes folder.
    private var heldRows: [(repo: URL, file: URL, display: String, verdict: GuardVerdict)] {
        let prefix = (sync.root?.path ?? "") + "/"
        return sync.heldFiles.sorted { $0.key.path < $1.key.path }.flatMap { repo, verdicts in
            verdicts.map { verdict in
                let file = repo.appendingPathComponent(verdict.path)
                let display = file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
                return (repo, file, display, verdict)
            }
        }
    }

    // MARK: - Actions

    private func refreshAccounts() async {
        accounts = await GistCatalog.accounts()
        if let first = accounts.first, !accounts.contains(settings.account) {
            settings.account = first
        }
    }

    private func refreshRemote() async {
        remote = await sync.rootRepo?.originURL()
        if repoName.isEmpty {
            repoName = sync.root?.lastPathComponent ?? "notes"
        }
    }

    private func run(_ work: () async -> Void) async {
        busy = true
        await work()
        busy = false
        await refreshAccounts()
        await refreshRemote()
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
