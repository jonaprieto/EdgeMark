import SwiftUI
import WidgetKit

@main
struct EdgeMarkWidgets: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
        VoiceWidget()
    }
}

struct PlainEntry: TimelineEntry {
    let date: Date
}

/// Widgets with nothing to update: their buttons never change.
struct PlainProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlainEntry {
        PlainEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PlainEntry) -> Void) {
        completion(PlainEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlainEntry>) -> Void) {
        completion(Timeline(entries: [PlainEntry(date: Date())], policy: .never))
    }
}

private func captureLink(_ query: String) -> URL {
    URL(string: "edgemark://capture?\(query)")!
}

struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EdgeMarkCapture", provider: PlainProvider()) { _ in
            HStack(spacing: 8) {
                button("Meal", "fork.knife", "kind=meal")
                button("Idea", "lightbulb", "kind=idea")
                button("Todo", "checkmark.square", "kind=todo")
                button("Voice", "mic", "kind=idea&voice=1")
            }
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Capture")
        .description("Add a meal, idea or todo in one tap.")
        .supportedFamilies([.systemMedium])
    }

    private func button(_ title: String, _ icon: String, _ query: String) -> some View {
        Link(destination: captureLink(query)) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct VoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EdgeMarkVoice", provider: PlainProvider()) { _ in
            VoiceWidgetView()
                .containerBackground(.background, for: .widget)
                .widgetURL(captureLink("kind=idea&voice=1"))
        }
        .configurationDisplayName("Dictate")
        .description("Speak a note.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic")
            }
        } else {
            Label("Dictate", systemImage: "mic").font(.headline)
        }
    }
}
