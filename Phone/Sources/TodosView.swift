import EdgeJournalLogic
import SwiftUI

struct TodosView: View {
    @State private var dating: Todo?
    @State private var due = Date()

    private var model: PhoneModel { .shared }
    private var today: String { Journal.day(Date()) }

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
            let groups = Dictionary(grouping: model.todos) { TodoScan.group($0, today: today) }
            List {
                ForEach(TodoScan.Group.allCases.filter { groups[$0] != nil }, id: \.self) { group in
                    Section(title(group)) {
                        ForEach(groups[group] ?? []) { todo in row(todo) }
                    }
                }
            }
            .overlay {
                if model.todos.isEmpty { ContentUnavailableView("No open todos", systemImage: "checkmark.circle") }
            }
            .navigationTitle("Todos")
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
                    Text([todo.due, model.note(todo.path)?.title].compactMap(\.self).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
