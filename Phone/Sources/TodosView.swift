import EdgeJournalLogic
import EdgePhoneSupport
import SwiftUI

enum TodoOrder: String, CaseIterable {
    case note, recent, due, reminders

    var title: String {
        switch self {
        case .note: "Note"
        case .recent: "Recent"
        case .due: "Due"
        case .reminders: "Reminders"
        }
    }
}

struct TodosView: View {
    @Binding var capture: CaptureRequest?

    @AppStorage("todos.order") private var order = TodoOrder.note
    @State private var query = ""
    @State private var dating: Todo?
    @State private var due = Date()
    @State private var remind = false
    @State private var stopping: Stopping?

    private var model: PhoneModel { .shared }

    /// A reminder that waits for a yes before it stops ringing.
    private struct Stopping {
        let title: String
        let stop: () async -> Void
    }

    private func stopping(_ note: Reminder) -> Stopping {
        Stopping(title: note.title) { await Reminders.cancelNotes { $0 == note.path } }
    }

    private func stopping(_ prompt: SleepPrompt) -> Stopping {
        Stopping(title: prompt.title) { SleepReminder.turnOff(prompt.id) }
    }

    private func modified(_ todo: Todo) -> Date {
        model.note(todo.path)?.modified ?? .distantPast
    }

    private var shown: [Todo] {
        guard !query.isEmpty else { return model.todos }
        return model.todos.filter {
            $0.text.localizedCaseInsensitiveContains(query) || model.note($0.path)?.title.localizedCaseInsensitiveContains(query) == true
        }
    }

    /// The todos as titled sections, in the chosen order.
    private var sections: [(title: String, todos: [Todo])] {
        let todos = shown
        switch order {
        case .note:
            let notes = Dictionary(grouping: todos, by: \.path)
            return notes.values.sorted { modified($0[0]) > modified($1[0]) }.map { (model.note($0[0].path)?.title ?? $0[0].path, $0) }
        case .recent:
            let calendar = Calendar.current
            let week = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let sorted = todos.sorted { modified($0) > modified($1) }
            let today = sorted.filter { calendar.isDateInToday(modified($0)) }
            let thisWeek = sorted.filter { !calendar.isDateInToday(modified($0)) && modified($0) >= week }
            let earlier = sorted.filter { !calendar.isDateInToday(modified($0)) && modified($0) < week }
            return [("Today", today), ("This week", thisWeek), ("Earlier", earlier)].filter { !$0.1.isEmpty }
        case .due, .reminders:
            let groups = Dictionary(grouping: todos) { TodoScan.group($0, today: Journal.day(Date())) }
            return TodoScan.Group.allCases.compactMap { group in groups[group].map { (title(group), $0) } }
        }
    }

    /// What will ring, by day.
    private var reminderSections: [(title: String, reminders: [Reminder])] {
        let calendar = Calendar.current
        let found = model.reminders.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let today = found.filter { calendar.isDateInToday($0.date) }
        let tomorrow = found.filter { calendar.isDateInTomorrow($0.date) }
        let later = found.filter { !calendar.isDateInToday($0.date) && !calendar.isDateInTomorrow($0.date) }
        return [("Today", today), ("Tomorrow", tomorrow), ("Later", later)].filter { !$0.1.isEmpty }
    }

    private func title(_ group: TodoScan.Group) -> String {
        switch group {
        case .overdue: "Overdue"
        case .today: "Today"
        case .dated: "Upcoming"
        case .undated: "No date"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Group by", selection: $order) {
                    ForEach(TodoOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if order == .reminders {
                    if model.notificationsOff {
                        Label("Notifications are off, so reminders will not ring.", systemImage: "bell.slash").foregroundStyle(.red)
                    }
                    ForEach(reminderSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.reminders) { reminder in row(reminder) }
                        }
                    }
                    if !model.sleepPrompts.isEmpty {
                        Section("Every day") {
                            ForEach(model.sleepPrompts) { prompt in
                                VStack(alignment: .leading) {
                                    Text(prompt.title)
                                    Text(prompt.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) { stopping = stopping(prompt) }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.todos) { todo in row(todo) }
                        }
                    }
                }
            }
            .overlay {
                if order == .reminders, model.reminders.isEmpty, model.sleepPrompts.isEmpty {
                    ContentUnavailableView("No reminders", systemImage: "bell", description: Text("Add one here, or with the bell on a note."))
                } else if order != .reminders, model.todos.isEmpty {
                    ContentUnavailableView("No open todos", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Todos")
            .searchable(text: $query)
            .refreshable { await model.sync() }
            .toolbar {
                Button("Remind me", systemImage: "bell") { capture = CaptureRequest(kind: .todo, remind: true) }
            }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
            .sheet(item: $dating) { todo in dueSheet(todo) }
            .confirmationDialog(
                "Delete \"\(stopping?.title ?? "reminder")\"?",
                isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                titleVisibility: .visible,
                presenting: stopping,
            ) { reminder in
                Button("Delete Reminder", role: .destructive) {
                    Task {
                        await reminder.stop()
                        model.refresh()
                    }
                }
            } message: { _ in
                Text("It stops ringing on this iPhone. Your notes stay as they are.")
            }
        }
    }

    private func row(_ todo: Todo) -> some View {
        HStack {
            Button("Done", systemImage: "circle") { model.toggle(todo) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            NavigationLink(value: Route.note(todo.path)) {
                VStack(alignment: .leading) {
                    Text(Journal.withoutImages(todo.text))
                    let detail = [todo.dueLabel, order == .note ? nil : model.note(todo.path)?.title].compactMap(\.self)
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .swipeActions {
            Button("Date", systemImage: "calendar") {
                due = todo.ringsAt() ?? Date()
                remind = todo.time != nil
                dating = todo
            }
        }
    }

    private func row(_ reminder: Reminder) -> some View {
        NavigationLink(value: Route.note(reminder.path)) {
            VStack(alignment: .leading) {
                Text(reminder.title).lineLimit(2)
                let detail = [WidgetSnapshot.when(reminder.date), reminder.repeats ? "Every weekday" : nil, model.note(reminder.path)?.title]
                Text(detail.compactMap(\.self).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .swipeActions {
            if let raw = reminder.raw {
                Button("Done", systemImage: "checkmark") {
                    if let todo = model.todo(at: reminder.path, raw: raw) { model.toggle(todo) }
                }
                .tint(.green)
            } else {
                Button("Delete", systemImage: "trash", role: .destructive) { stopping = stopping(reminder) }
            }
        }
    }

    private func dueSheet(_ todo: Todo) -> some View {
        NavigationStack {
            Form {
                DatePicker("Due", selection: $due, displayedComponents: remind ? [.date, .hourAndMinute] : .date).datePickerStyle(.graphical)
                Toggle("Remind me", isOn: $remind)
                if todo.due != nil {
                    Button("Remove date", role: .destructive) {
                        model.setDue(nil, on: todo)
                        dating = nil
                    }
                }
            }
            .navigationTitle(todo.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dating = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        model.setDue(remind ? Journal.stamp(due) : Journal.day(due), on: todo)
                        dating = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
