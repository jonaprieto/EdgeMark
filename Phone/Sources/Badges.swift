import EdgeJournalLogic
import EdgeStorageLogic
import SwiftUI

/// A run of text drawn on a rounded badge by `PillRenderer`.
enum Pill: TextAttribute {
    case tag, code, meal
}

/// Draws a badge behind every run marked with `Pill`, then the text over it.
struct PillRenderer: TextRenderer {
    let code: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let pill = run[Pill.self] {
                    let rect = run.typographicBounds.rect.insetBy(dx: -4, dy: -1)
                    let shape: AnyShape = pill == .code ? AnyShape(RoundedRectangle(cornerRadius: 4)) : AnyShape(Capsule())
                    let fill: AnyShapeStyle = switch pill {
                    case .tag: AnyShapeStyle(.tint.opacity(0.16))
                    case .code: AnyShapeStyle(code.opacity(0.14))
                    case .meal: AnyShapeStyle(.orange.opacity(0.18))
                    }
                    context.fill(shape.path(in: rect), with: .style(fill))
                }
                context.draw(run)
            }
        }
    }
}

extension NoteMarkdown {
    /// `verbatim` in a color that stands out from the prose.
    static func codeColor(_ theme: ColorTheme?) -> Color {
        theme.map { Color(hex: $0.palette.keyword) } ?? Color(.systemPink)
    }
}

/// One line of a journal entry: its inline Markdown, with the meal, tags and `code` on badges.
struct RichLine: View {
    let words: String
    var meal: String?

    @Environment(\.colorTheme) private var theme

    var body: some View {
        pieces.reduce(Text("")) { Text("\($0)\($1)") }
            .textRenderer(PillRenderer(code: NoteMarkdown.codeColor(theme)))
            .padding(.horizontal, 4)
    }

    private var pieces: [Text] {
        var out: [Text] = []
        if let meal {
            out += [Text(meal).foregroundStyle(.orange).customAttribute(Pill.meal), Text("  ")]
        }
        let parsed = (try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(words)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                out.append(Text(piece).monospaced().foregroundStyle(NoteMarkdown.codeColor(theme)).customAttribute(Pill.code))
                continue
            }
            for span in Journal.tagSpans(piece) {
                let text = Text(AttributedString(span.text, attributes: run.attributes))
                out.append(span.isTag ? text.foregroundStyle(.tint).customAttribute(Pill.tag) : text)
            }
        }
        return out
    }
}

/// A time on a badge, in the accent or another tint.
struct TimeBadge: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(.tint.opacity(0.14)), in: Capsule())
    }
}

/// A timed line of a day file: its time on a badge, the line, its photos, and a pin that opens
/// where it was written in Maps.
struct EntryRow: View {
    let entry: Journal.Entry
    let place: PlaceLine?
    var imageBase: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TimeBadge(text: entry.time)
            VStack(alignment: .leading, spacing: 6) {
                if !entry.words.isEmpty || entry.meal != nil {
                    RichLine(words: entry.words, meal: entry.meal?.rawValue)
                }
                if !entry.images.isEmpty {
                    NoteMarkdown(entry.images.map { "![](\($0))" }.joined(separator: " "), imageBase: imageBase)
                }
            }
            Spacer(minLength: 0)
            if let place, let url = Self.maps(place) {
                Button("Show \(place.place ?? "the place") on the map", systemImage: "mappin.circle") { openURL(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func maps(_ place: PlaceLine) -> URL? {
        var url = URLComponents(string: "https://maps.apple.com/")
        url?.queryItems = [URLQueryItem(name: "ll", value: "\(place.lat),\(place.lon)"), URLQueryItem(name: "q", value: place.place ?? "")]
        return url?.url
    }
}

/// A night under `## Sleep`: bed and wake on a badge, then how long, then the note.
struct SleepRow: View {
    let sleep: Sleep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TimeBadge(text: sleep.bed.flatMap { bed in sleep.wake.map { "\(bed) → \($0)" } } ?? "Sleep", tint: .indigo)
            Text(Sleep.duration(sleep.minutes)).font(.body.monospacedDigit().weight(.semibold))
            if !sleep.note.isEmpty {
                Text(sleep.note).foregroundStyle(.secondary)
            }
        }
    }
}
