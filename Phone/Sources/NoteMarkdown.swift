import EdgeJournalLogic
import MarkdownUI
import SwiftUI

/// A note as it reads: highlighted code, math, Mermaid diagrams and images.
struct NoteMarkdown: View {
    let text: String
    var imageBase: URL?

    @ScaledMetric(relativeTo: .body) private var mathSize: CGFloat = 17
    @Environment(\.colorTheme) private var theme

    init(_ text: String, imageBase: URL? = nil) {
        self.text = text
        self.imageBase = imageBase
    }

    /// GitHub's, in the picked theme's ink and links when there is one.
    private var markdownTheme: Theme {
        guard let p = theme?.palette else { return Theme.gitHub.text { BackgroundColor(nil) } }
        return Theme.gitHub.text {
            ForegroundColor(Color(hex: p.text))
            BackgroundColor(nil)
        }.link {
            ForegroundColor(Color(hex: p.link))
        }
    }

    var body: some View {
        Markdown(MathMarkdown.rewrite(text), imageBaseURL: imageBase)
            .markdownTheme(markdownTheme.code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(Self.codeColor(theme))
                BackgroundColor(Self.codeColor(theme).opacity(0.12))
            }.codeBlock { block in
                CodeBlock(code: block.content.trimmingCharacters(in: .newlines), language: block.language ?? "")
                    .markdownMargin(top: 8, bottom: 12)
            })
            .markdownInlineImageProvider(InlineImages(mathSize: mathSize))
            .markdownImageProvider(BlockImages(mathSize: mathSize))
    }
}

/// A note you can act on: its text as Markdown, its tasks as checkboxes that write to the file,
/// and a day file's timed lines as rows with badges.
struct NoteBody: View {
    let text: String
    let path: String
    var imageBase: URL?

    private enum Piece {
        case markdown(String)
        case entry(Journal.Entry)
        case sleep(Sleep)
        case section(String)
    }

    /// `markdown` with each timed line and each night taken out as a row of its own. In a day
    /// file the `# 2026-11-09` title goes, since the screen's title already says the day, and
    /// each `## Meals` is a quiet label rather than a ruled heading over small rows.
    private static func pieces(of markdown: String, entries: [String: Journal.Entry], nights: [String: Sleep], dayFile: Bool) -> [Piece] {
        var out: [Piece] = []
        var pending: [String] = []
        func flush() {
            let chunk = pending.joined(separator: "\n")
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.markdown(chunk)) }
            pending = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let entry = entries[line] {
                flush()
                out.append(.entry(entry))
            } else if let night = nights[line] {
                flush()
                out.append(.sleep(night))
            } else if dayFile, line.hasPrefix("## ") {
                flush()
                out.append(.section(String(line.dropFirst(3))))
            } else if dayFile, line.hasPrefix("# ") {
                continue
            } else {
                pending.append(line)
            }
        }
        flush()
        return out
    }

    var body: some View {
        let entries = Dictionary(Journal.entries(in: text, path: path).map { ("- \($0.time) \($0.text)", $0) }) { first, _ in first }
        let nights = Dictionary(Sleep.entries(in: text).map { ($0.line, $0) }) { first, _ in first }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TodoScan.segments(of: text, path: path).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(markdown):
                    ForEach(Array(Self.pieces(of: markdown, entries: entries, nights: nights, dayFile: path.hasPrefix("\(Journal.folder)/")).enumerated()), id: \.offset) { _, piece in
                        switch piece {
                        case let .markdown(chunk):
                            NoteMarkdown(chunk, imageBase: imageBase)
                        case let .entry(entry):
                            EntryRow(entry: entry, place: PlaceLine.place(of: entry, in: PhoneModel.shared.places), imageBase: imageBase)
                        case let .sleep(night):
                            SleepRow(sleep: night)
                        case let .section(title):
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                case let .task(todo):
                    TaskRow(todo: todo, imageBase: imageBase)
                }
            }
        }
    }
}

struct TaskRow: View {
    let todo: Todo
    var imageBase: URL?

    /// Sub-tasks keep their place under the task above.
    private var indent: CGFloat {
        CGFloat(todo.raw.prefix { $0 == " " || $0 == "\t" }.count) * 8
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(todo.done ? "Mark as not done" : "Mark as done", systemImage: todo.done ? "checkmark.square.fill" : "square") {
                PhoneModel.shared.toggle(todo)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                NoteMarkdown(todo.text, imageBase: imageBase)
                    .opacity(todo.done ? 0.5 : 1)
                if let due = todo.dueLabel {
                    Label(due, systemImage: todo.time == nil ? "calendar" : "bell")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(.leading, indent)
    }
}

/// Highlighted code, wrapping long lines, or the diagram a Mermaid block draws.
struct CodeBlock: View {
    let code: String
    let language: String

    @Environment(\.colorTheme) private var theme

    private func color(_ role: TokenRole) -> Color {
        if let p = theme?.palette {
            let hex = switch role {
            case .comment: p.comment
            case .string: p.string
            case .number: p.number
            case .keyword: p.keyword
            case .type: p.type
            case .function: p.function
            }
            return Color(hex: hex)
        }
        return switch role {
        case .comment: .secondary
        case .string: .red
        case .number: .orange
        case .keyword: .purple
        case .type: .teal
        case .function: .blue
        }
    }

    private var highlighted: AttributedString {
        var out = AttributedString(code)
        for (range, role) in Highlighter.spans(code, lang: language) {
            guard let span = Range(range, in: code), let low = AttributedString.Index(span.lowerBound, within: out),
                  let high = AttributedString.Index(span.upperBound, within: out) else { continue }
            out[low ..< high].foregroundColor = color(role)
        }
        return out
    }

    var body: some View {
        if language.lowercased().hasPrefix("mermaid") {
            Diagram(source: code)
        } else {
            Text(highlighted)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface(), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct Diagram: View {
    let source: String

    @Environment(\.colorScheme) private var scheme
    @State private var outcome: MermaidRenderer.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case let .image(image):
                Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: image.size.width)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Diagram")
            case let .failure(message):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    CodeBlock(code: source, language: "")
                }
            case nil:
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(.vertical, 6)
        .task(id: "\(scheme)|\(source)") {
            outcome = await MermaidRenderer.shared.render(source, dark: scheme == .dark, fontFamily: "-apple-system, sans-serif", fontSize: 15)
        }
    }
}

/// Math and photos within a line of text, such as a journal entry.
struct InlineImages: InlineImageProvider {
    /// Wide enough to read, small enough to stay part of the line.
    static let photoWidth: CGFloat = 280

    let mathSize: CGFloat

    func image(with url: URL, label: String) async throws -> Image {
        if let (latex, display) = MathMarkdown.latex(from: url),
           let image = await MainActor.run(body: { MathMarkdown.image(latex: latex, display: display, size: mathSize) }) {
            return Image(uiImage: image).renderingMode(.template)
        }
        if url.isFileURL, let photo = UIImage(contentsOfFile: url.path) {
            let scale = min(1, Self.photoWidth / max(photo.size.width, 1))
            let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
            return await Image(uiImage: photo.byPreparingThumbnail(ofSize: size) ?? photo)
        }
        return Image(systemName: "photo")
    }
}

/// Math and images on a line of their own.
struct BlockImages: ImageProvider {
    let mathSize: CGFloat

    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let url, let (latex, display) = MathMarkdown.latex(from: url) {
            if let image = MathMarkdown.image(latex: latex, display: display, size: mathSize) {
                Image(uiImage: image).renderingMode(.template).resizable().aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: image.size.width).frame(maxWidth: .infinity)
                    .accessibilityLabel(latex)
            } else {
                Text(latex).font(.system(.body, design: .monospaced))
            }
        } else if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit)
                .frame(maxWidth: image.size.width)
        } else if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
        }
    }
}
