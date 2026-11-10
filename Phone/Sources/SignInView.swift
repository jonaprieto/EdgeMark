import EdgePhoneSync
import SwiftUI
import UIKit

/// Signs in with GitHub's device flow, then picks the private repository that holds the notes.
/// The first launch with no GitHub access opens it full screen; Settings opens it as a sheet.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var code: GitHubLogin.Code?
    @State private var repositories: [String]?
    @State private var problem: String?
    @State private var attempt = 0
    @State private var copied = false

    private var model: PhoneModel { .shared }
    private var login: GitHubLogin { GitHubLogin(clientID: PhoneModel.gitHubClientID) }

    var body: some View {
        NavigationStack {
            Form {
                if let repositories {
                    repositoryList(repositories)
                } else if !model.isSignedIn {
                    welcome
                    codeCard
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red)
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            self.problem = nil
                            attempt += 1
                        }
                    }
                }
            }
            .themedBackground()
            .navigationTitle(repositories == nil ? "Sign In" : "Notes Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isSignedIn ? "Close" : "Not Now") { dismiss() }
                }
            }
        }
        .task(id: attempt) { await start() }
        // Back from github.com, where a repository may have just been created or given access.
        .onChange(of: scenePhase) {
            if scenePhase == .active, repositories != nil { Task { await list() } }
        }
    }

    private var welcome: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "lock.doc").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Sign in with GitHub").font(.title2.weight(.semibold))
                Text("Your notes live in a private GitHub repository that only you can see. EdgeMark has no server and no account of its own.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    /// The code and both buttons stay put until GitHub answers: a trip to Safari and back
    /// changes nothing here.
    @ViewBuilder private var codeCard: some View {
        Section {
            if let code {
                Text(code.user)
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(code) }
                Button("Open GitHub", systemImage: "safari") {
                    copy(code)
                    openURL(code.page)
                }
                .bold()
                if problem == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve on GitHub").foregroundStyle(.secondary)
                    }
                }
            } else if problem == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking GitHub for a code").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Open GitHub, paste the code and approve EdgeMark. Come back here and it moves on by itself.")
        }
    }

    @ViewBuilder private func repositoryList(_ repositories: [String]) -> some View {
        Section {
            ForEach(repositories, id: \.self) { name in
                Button { Task { await pick(name) } } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        if name == PhoneModel.repository { Image(systemName: "checkmark") }
                    }
                }
            }
            if repositories.isEmpty {
                Text("EdgeMark can reach no private repository yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Pick the one with your notes")
        } footer: {
            Text("Your notes live in a private GitHub repository that only you can see. EdgeMark has no server.")
        }
        Section {
            Button("Create a Private Repository", systemImage: "plus") { openURL(URL(string: "https://github.com/new")!) }
            Button("Give EdgeMark Access", systemImage: "key") {
                openURL(URL(string: "https://github.com/apps/\(PhoneModel.gitHubAppSlug)/installations/new")!)
            }
        } footer: {
            Text("Create the repository first, then give EdgeMark access to it alone. Public ones are left out.")
        }
    }

    private func copy(_ code: GitHubLogin.Code) {
        UIPasteboard.general.string = code.user
        copied = true
    }

    /// A code that runs out is replaced without asking; only a refusal or no network stops here.
    private func start() async {
        if model.isSignedIn { return await list() }
        while !Task.isCancelled {
            do {
                let fresh = try await login.start()
                code = fresh
                copied = false
                model.keep(try await login.wait(for: fresh))
                return await list()
            } catch GitHubLogin.Failure.expired {
                continue
            } catch is CancellationError {
                return
            } catch {
                problem = "\(error)"
                return
            }
        }
    }

    private func list() async {
        guard let token = await model.gitHubToken() else {
            problem = model.status
            return
        }
        do {
            repositories = try await login.privateRepositories(token: token)
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    private func pick(_ name: String) async {
        if let error = await model.use(name) {
            problem = error
            return
        }
        dismiss()
        await model.sync()
    }
}
