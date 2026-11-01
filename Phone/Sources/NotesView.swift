import SwiftUI

enum Route: Hashable {
    case folder(String)
    case note(String)
}

struct NotesRoot: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            NotesList(folder: "", path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .folder(folder): NotesList(folder: folder, path: $path)
                    case let .note(note): NoteView(path: note)
                    }
                }
        }
    }
}

struct NotesList: View {
    let folder: String
    @Binding var path: [Route]

    @State private var query = ""
    @State private var showSettings = false
    @State private var naming = false
    @State private var title = ""

    private var model: PhoneModel { .shared }

    /// Folders directly inside this one.
    private var folders: [String] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let inside = model.notes.map(\.folder).filter { $0.hasPrefix(prefix) && $0 != folder }
        return Set(inside.compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map { prefix + $0 } }).sorted()
    }

    private var shown: [PhoneNote] {
        guard !query.isEmpty else { return model.notes.filter { $0.folder == folder } }
        return model.notes.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// Where sync stands, and which build this is.
    private var syncFooter: some View {
        VStack(spacing: 4) {
            if model.syncing {
                Text("Syncing…")
            } else if !model.status.isEmpty {
                Text(model.status)
            } else if let last = model.lastSync {
                Text("Synced at \(last.formatted(date: .omitted, time: .shortened))")
            }
            Text("EdgeMark \(PhoneModel.version)")
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        List {
            if query.isEmpty {
                ForEach(folders, id: \.self) { name in
                    NavigationLink(value: Route.folder(name)) {
                        Label((name as NSString).lastPathComponent, systemImage: "folder")
                    }
                }
            }
            ForEach(shown) { note in
                NavigationLink(value: Route.note(note.path)) {
                    VStack(alignment: .leading) {
                        Label {
                            Text(note.title).lineLimit(1)
                        } icon: {
                            if note.isEncrypted { Image(systemName: "lock") }
                        }
                        Text(note.modified, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if folder.isEmpty, query.isEmpty, !model.notes.isEmpty {
                Section {} footer: { syncFooter }
            }
        }
        .overlay {
            if model.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "note.text")
                } description: {
                    syncFooter
                } actions: {
                    Button("Sync Now") { Task { await model.sync() } }
                        .disabled(model.syncing)
                }
            }
        }
        .navigationTitle(folder.isEmpty ? "Notes" : (folder as NSString).lastPathComponent)
        .searchable(text: $query)
        .refreshable { await model.sync() }
        .toolbar {
            if folder.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) { SyncButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Note", systemImage: "square.and.pencil") { naming = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("New Note", isPresented: $naming) {
            TextField("Title", text: $title)
            Button("Create") {
                if let note = model.create(title: title, folder: folder) { path.append(.note(note)) }
                title = ""
            }
            Button("Cancel", role: .cancel) { title = "" }
        }
    }
}

/// Syncs now, and shows at a glance whether sync is working.
struct SyncButton: View {
    private var model: PhoneModel { .shared }

    var body: some View {
        Button("Sync", systemImage: model.syncFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath") {
            Task { await model.sync() }
        }
        .symbolEffect(.rotate, isActive: model.syncing)
        .disabled(model.syncing)
    }
}
