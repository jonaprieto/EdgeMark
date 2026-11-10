import EdgeStorageLogic
import EventKit
import SwiftUI

struct SettingsView: View {
    @State private var signingIn = false
    @AppStorage(ThemeSetting.key) private var themeName = ""
    @AppStorage("brainstorm.model") private var modelName = "gpt-6.1-sol"
    @AppStorage("voice.language") private var language = VoiceLanguage.es
    @AppStorage("sleep.bedReminder") private var bedReminder = false
    @AppStorage("sleep.bedReminderTime") private var bedTime = Self.time(hour: 22, minute: 30)
    @AppStorage("sleep.reminder") private var wakeReminder = false
    @AppStorage("sleep.reminderTime") private var wakeTime = Self.time(hour: 8, minute: 0)

    private static func time(hour: Int, minute: Int) -> Double {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())?.timeIntervalSinceReferenceDate ?? 0
    }

    private func date(_ value: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSinceReferenceDate: value.wrappedValue) }, set: { value.wrappedValue = $0.timeIntervalSinceReferenceDate })
    }

    private func updateReminders() async {
        if bedReminder {
            bedReminder = await SleepReminder.schedule(SleepReminder.bedTime, title: "Going to bed?", at: date($bedTime).wrappedValue)
        } else {
            SleepReminder.cancel(SleepReminder.bedTime)
        }
        if wakeReminder {
            wakeReminder = await SleepReminder.schedule(SleepReminder.wakeTime, title: "Are you up?", at: date($wakeTime).wrappedValue)
        } else {
            SleepReminder.cancel(SleepReminder.wakeTime)
        }
        PhoneModel.shared.refresh()
    }

    private var model: PhoneModel { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    LabeledContent("Repository", value: PhoneModel.repository.isEmpty ? "None" : PhoneModel.repository)
                    if let last = model.lastSync {
                        LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if !model.status.isEmpty { Text(model.status).font(.caption) }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync() } }
                        .disabled(model.syncing)
                    Button(model.isSignedIn ? "Change Repository" : "Sign in with GitHub", systemImage: "person.badge.key") { signingIn = true }
                    if model.isSignedIn {
                        Button("Sign Out of GitHub", role: .destructive) { model.signOut() }
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $themeName) {
                        Text("System").tag("")
                        ForEach(ColorTheme.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: PhoneModel.version)
                }
                Section("Sleep") {
                    Toggle("Bedtime reminder", isOn: $bedReminder)
                    if bedReminder {
                        DatePicker("Time", selection: date($bedTime), displayedComponents: .hourAndMinute)
                    }
                    Toggle("Morning reminder", isOn: $wakeReminder)
                    if wakeReminder {
                        DatePicker("Time", selection: date($wakeTime), displayedComponents: .hourAndMinute)
                    }
                }
                .onChange(of: bedReminder) { Task { await updateReminders() } }
                .onChange(of: bedTime) { Task { await updateReminders() } }
                .onChange(of: wakeReminder) { Task { await updateReminders() } }
                .onChange(of: wakeTime) { Task { await updateReminders() } }
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
            .themedBackground()
            .navigationTitle("Settings")
            .sheet(isPresented: $signingIn) { SignInView() }
        }
    }
}
