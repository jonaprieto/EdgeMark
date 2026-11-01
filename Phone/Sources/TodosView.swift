import EdgeJournalLogic
import SwiftUI

enum TodoOrder: String, CaseIterable {
    case note, recent, due

    var title: String {
        switch self {
        case .note: "Note"
        case .recent: "Recent"
        case .due: "Due"
        }
    }
}

struct TodosView: View {
    @AppStorage("todos.order") private var order = TodoOrder.note
    @State private var query = ""
    @State private var dating: Todo?
    @State private var due = Date()

    private var model: PhoneModel { .shared }

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
        case .due:
            let groups = Dictionary(grouping: todos) { TodoScan.group($0, today: Journal.day(Date())) }
            return TodoScan.Group.allCases.compactMap { group in groups[group].map { (title(group), $0) } }
        }
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
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.todos) { todo in row(todo) }
                    }
                }
            }
            .overlay {
                if model.todos.isEmpty { ContentUnavailableView("No open todos", systemImage: "checkmark.circle") }
            }
            .navigationTitle("Todos")
            .searchable(text: $query)
            .refreshable { await model.sync() }
            .navigationDestination(for: Route.self) { route in
                if case let .note(note) = route { NoteView(path: note) }
            }
            .sheet(item: $dating) { todo in dueSheet(todo) }
        }
    }

    private func row(_ todo: Todo) -> some View {
        HStack {
            Button("Done", systemImage: "circle") { model.toggle(todo) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            NavigationLink(value: Route.note(todo.path)) {
                VStack(alignment: .leading) {
                    Text(todo.text)
                    let detail = [todo.due, order == .note ? nil : model.note(todo.path)?.title].compactMap(\.self)
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .swipeActions {
            Button("Date", systemImage: "calendar") {
                due = Date()
                dating = todo
            }
        }
    }

    private func dueSheet(_ todo: Todo) -> some View {
        NavigationStack {
            Form {
                DatePicker("Due", selection: $due, displayedComponents: .date).datePickerStyle(.graphical)
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
                        model.setDue(Journal.day(due), on: todo)
                        dating = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
