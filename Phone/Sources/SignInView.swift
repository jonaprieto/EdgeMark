import EdgePhoneSync
import SwiftUI
import UIKit

/// Signs in with GitHub's device flow, then picks the private repository that holds the notes.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var code: GitHubLogin.Code?
    @State private var repositories: [String]?
    @State private var problem: String?
    @State private var attempt = 0

    private var model: PhoneModel { .shared }
    private var login: GitHubLogin { GitHubLogin(clientID: PhoneModel.gitHubClientID) }

    var body: some View {
        NavigationStack {
            Form {
                if let repositories {
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
                        Text("Notes repository")
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
                } else if let code {
                    Section {
                        Text(code.user).font(.largeTitle.monospaced().weight(.semibold)).frame(maxWidth: .infinity)
                        Button("Copy Code and Open GitHub", systemImage: "safari") {
                            UIPasteboard.general.string = code.user
                            openURL(code.page)
                        }
                    } footer: {
                        Text("Paste the code on GitHub and approve EdgeMark. This screen moves on by itself.")
                    }
                } else if problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red)
                        Button("Try Again") {
                            self.problem = nil
                            attempt += 1
                        }
                    }
                }
            }
            .themedBackground()
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: attempt) { await start() }
        // Back from github.com, where a repository may have just been created or given access.
        .onChange(of: scenePhase) {
            if scenePhase == .active, repositories != nil { Task { await list() } }
        }
    }

    private func start() async {
        if model.isSignedIn { return await list() }
        do {
            let code = try await login.start()
            self.code = code
            model.keep(try await login.wait(for: code))
            await list()
        } catch is CancellationError {
        } catch {
            code = nil
            problem = "\(error)"
        }
    }

    private func list() async {
        guard let token = await model.gitHubToken() else {
            problem = model.status
            return
        }
        do {
            repositories = try await login.privateRepositories(token: token)
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
