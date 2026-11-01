import MarkdownUI
import SwiftUI

/// A note as it reads: highlighted code, math, Mermaid diagrams and images.
struct NoteMarkdown: View {
    let text: String
    var imageBase: URL?

    @ScaledMetric(relativeTo: .body) private var mathSize: CGFloat = 17

    init(_ text: String, imageBase: URL? = nil) {
        self.text = text
        self.imageBase = imageBase
    }

    var body: some View {
        Markdown(MathMarkdown.rewrite(text), imageBaseURL: imageBase)
            .markdownTheme(Theme.gitHub.text { BackgroundColor(nil) }.code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(Color.primary.opacity(0.08))
            }.codeBlock { block in
                CodeBlock(code: block.content.trimmingCharacters(in: .newlines), language: block.language ?? "")
                    .markdownMargin(top: 8, bottom: 12)
            })
            .markdownInlineImageProvider(InlineImages(mathSize: mathSize))
            .markdownImageProvider(BlockImages(mathSize: mathSize))
    }
}

/// Highlighted code, wrapping long lines, or the diagram a Mermaid block draws.
struct CodeBlock: View {
    let code: String
    let language: String

    private func color(_ role: TokenRole) -> Color {
        switch role {
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
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
