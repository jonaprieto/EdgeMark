import EdgePhoneSync
import SwiftUI

/// Your gists, read-only: they are edited on the Mac.
struct GistsView: View {
    @State private var query = ""

    private var model: PhoneModel { .shared }

    private var shown: [Gist] {
        query.isEmpty ? model.gists : model.gists.filter { model.gist($0, matches: query) }
    }

    var body: some View {
        List(shown) { gist in
            NavigationLink(value: gist.files.count == 1 ? Route.gistFile("\(gist.id)/\(gist.files[0])") : Route.gist(gist.id)) {
                VStack(alignment: .leading) {
                    Label {
                        Text(gist.title).lineLimit(2)
                    } icon: {
                        if gist.isPublic { Image(systemName: "globe") }
                    }
                    Text("\(gist.updatedAt.prefix(10)) · \(gist.files.count) \(gist.files.count == 1 ? "file" : "files")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.gists.isEmpty {
                if model.refreshingGists {
                    ProgressView("Loading your gists")
                } else {
                    ContentUnavailableView("No gists", systemImage: "doc.on.doc", description: Text(model.gistError ?? "Pull down to refresh."))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.gists.isEmpty, let error = model.gistError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .navigationTitle("Gists")
        .searchable(text: $query)
        .refreshable { await model.refreshGists() }
        .task { await model.refreshGists() }
    }
}

struct GistFilesView: View {
    let id: String

    private var gist: Gist? { PhoneModel.shared.gists.first { $0.id == id } }

    var body: some View {
        List(gist?.files ?? [], id: \.self) { name in
            NavigationLink(name, value: Route.gistFile("\(id)/\(name)"))
        }
        .navigationTitle(gist?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GistFileView: View {
    let path: String

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            if name.hasSuffix(".age") {
                ContentUnavailableView("Encrypted gist", systemImage: "lock", description: Text("Open it on the Mac."))
            } else {
                let text = PhoneModel.shared.gistText(of: path)
                if text.isEmpty, PhoneModel.shared.refreshingGists {
                    ProgressView("Downloading")
                }
                ScrollView {
                    Group {
                        if name.hasSuffix(".md") {
                            NoteMarkdown(text)
                        } else {
                            Text(text).font(.system(.footnote, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
