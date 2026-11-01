import SwiftUI
import WidgetKit

@main
struct EdgeMarkWidgets: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
        VoiceWidget()
        AgendaWidget()
        RemindersWidget()
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
                button("Sleep", "moon.zzz", "kind=sleep")
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

struct AgendaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// The app is not running when a meeting ends or a reminder rings, so the timeline moves on by itself.
struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry {
        let now = Date()
        return AgendaEntry(date: now, snapshot: WidgetSnapshot(
            date: now,
            events: [.init(title: "Next meeting", start: now, end: now.addingTimeInterval(3600))],
            todos: ["Open todo"],
            openTodos: 1,
            reminders: [.init(title: "Next reminder", start: now, end: now)],
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : AgendaEntry(date: Date(), snapshot: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let changes = (snapshot?.events ?? []).map(\.end) + (snapshot?.reminders ?? []).map(\.start)
        let entries = ([now] + changes.filter { $0 > now }.sorted()).map { AgendaEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EdgeMarkAgenda", provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "edgemark://agenda"))
        }
        .configurationDisplayName("Agenda")
        .description("Your next meeting and top todos.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct AgendaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    private var next: WidgetSnapshot.Event? {
        entry.snapshot?.events.first { $0.end > entry.date }
    }

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading) {
                Text(next?.title ?? "No meetings").font(.headline).lineLimit(1).privacySensitive()
                if let next { Text(next.start, style: .time) }
                Text("\(entry.snapshot?.openTodos ?? 0) todos").font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let next {
                    Text(next.title).font(.headline).lineLimit(1).privacySensitive()
                    Text(next.start, style: .time).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No meetings").font(.headline)
                }
                Divider()
                ForEach(todos, id: \.self) { todo in
                    Text(todo).font(.caption).lineLimit(1).privacySensitive()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var todos: [String] {
        Array((entry.snapshot?.todos ?? []).prefix(family == .systemSmall ? 2 : 3))
    }
}

struct RemindersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EdgeMarkReminders", provider: AgendaProvider()) { entry in
            RemindersWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "edgemark://reminders"))
        }
        .configurationDisplayName("Reminders")
        .description("What rings next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct RemindersWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    private var coming: [WidgetSnapshot.Event] {
        (entry.snapshot?.reminders ?? []).filter { $0.start > entry.date }
    }

    private func when(_ reminder: WidgetSnapshot.Event) -> String {
        WidgetSnapshot.when(reminder.start, now: entry.date)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(coming.first.map { "\(when($0)) \($0.title)" } ?? "No reminders", systemImage: "bell").privacySensitive()
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(coming.first?.title ?? "No reminders").font(.headline).lineLimit(1).privacySensitive()
                if let next = coming.first { Text(when(next)).font(.caption) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Reminders", systemImage: "bell").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Spacer()
                    if family == .systemMedium {
                        Link(destination: captureLink("kind=todo&remind=1")) { Image(systemName: "plus") }
                    }
                }
                if coming.isEmpty {
                    Text("No reminders").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(coming.prefix(family == .systemSmall ? 3 : 4), id: \.self) { reminder in
                    HStack {
                        Text(reminder.title).font(.caption).lineLimit(1).privacySensitive()
                        Spacer(minLength: 4)
                        if family == .systemMedium {
                            Text(when(reminder)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
