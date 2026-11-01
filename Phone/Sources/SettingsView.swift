import EventKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("brainstorm.model") private var modelName = "gpt-6.1-sol"
    @AppStorage("voice.language") private var language = VoiceLanguage.es

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
                Section("About") {
                    LabeledContent("Version", value: PhoneModel.version)
                }
                Section("Dictation") {
                    Picker("Language", selection: $language) {
                        Text("Spanish").tag(VoiceLanguage.es)
                        Text("English").tag(VoiceLanguage.en)
                    }
                }
                Section("Brainstorm") {
                    TextField("OpenAI model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
