import EventKit
import SwiftUI

struct SettingsView: View {
    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    LabeledContent("Repository", value: PhoneModel.repository)
                    if let last = model.lastSync {
                        LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if !model.status.isEmpty { Text(model.status).font(.caption) }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync() } }
                        .disabled(model.syncing)
                }
                if !model.calendars.all.isEmpty {
                    Section("Calendars") {
                        ForEach(model.calendars.all, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: Binding(
                                get: { !model.calendars.hidden.contains(calendar.calendarIdentifier) },
                                set: { on in Task { await model.calendars.setShown(on, calendar) } },
                            )) {
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                    Text(calendar.source.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !model.held.isEmpty {
                    Section("Held on this phone") {
                        ForEach(model.held.keys.sorted(), id: \.self) { path in
                            VStack(alignment: .leading) {
                                Text(path)
                                Text(model.held[path]?.joined(separator: ", ") ?? "").font(.caption).foregroundStyle(.secondary)
                                Button("Send Anyway") { model.allow(path) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
