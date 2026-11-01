import SwiftUI

enum Route: Hashable {
    case folder(String)
    case note(String)
    case gists
    case gist(String)
    case gistFile(String)
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
                    case .gists: GistsView()
                    case let .gist(id): GistFilesView(id: id)
                    case let .gistFile(file): GistFileView(path: file)
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
    @State private var deleting: PhoneNote?
    @State private var reminding: PhoneNote?

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
            if let error = model.saveError {
                Text(error).foregroundStyle(.red)
            }
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
                if folder.isEmpty {
                    NavigationLink(value: Route.gists) {
                        Label("Gists", systemImage: "folder")
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
                        HStack(spacing: 4) {
                            Text(note.modified, format: .dateTime.day().month().hour().minute())
                            if model.hasReminder(on: note.path) { Image(systemName: "bell.fill") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = note }
                    Button("Remind Me", systemImage: "bell") { reminding = note }.tint(.orange)
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
        .deleteDialog(for: $deleting)
        .sheet(item: $reminding) { ReminderSheet(note: $0) }
        .sheet(isPresented: $naming) {
            NewNoteSheet(folder: folder) { path.append(.note($0)) }
        }
    }
}

/// Syncs now, and shows at a glance whether sync is working.
struct SyncButton: View {
    private var model: PhoneModel { .shared }

    var body: some View {
        Button("Sync", systemImage: model.syncFailed || !model.held.isEmpty ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath") {
            Task { await model.sync() }
        }
        .symbolEffect(.rotate, isActive: model.syncing)
        .disabled(model.syncing)
    }
}

extension View {
    /// Asks before a note goes, and says where it goes.
    func deleteDialog(for note: Binding<PhoneNote?>) -> some View {
        confirmationDialog(
            "Delete \(note.wrappedValue?.title ?? "note")?",
            isPresented: Binding(get: { note.wrappedValue != nil }, set: { if !$0 { note.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: note.wrappedValue,
        ) { target in
            Button("Delete", role: .destructive) { PhoneModel.shared.delete(target.path) }
        } message: { _ in
            Text("It goes from this iPhone and the Mac. Your repository's history keeps a copy.")
        }
    }
}
