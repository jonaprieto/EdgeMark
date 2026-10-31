import SwiftUI

/// Every open task across the notes, soonest first.
struct TodosView: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(L10n.self) var l10n

    private func title(_ group: TodoScan.Group) -> String {
        switch group {
        case .overdue: l10n["todos.overdue"]
        case .today: l10n["todos.today"]
        case .dated: l10n["todos.upcoming"]
        case .undated: l10n["todos.noDate"]
        }
    }

    var body: some View {
        PageLayout(onSwipeBack: { noteStore.closeTodos() }) {
            HStack {
                HeaderIconButton(systemName: "chevron.left", help: l10n["tooltip.back"]) {
                    noteStore.closeTodos()
                }
                Spacer()
                PinButton()
            }
            .overlay {
                Text(l10n["todos.title"])
                    .font(.panel(.headline))
            }
        } content: {
            let todos = noteStore.pendingTodos
            if todos.isEmpty {
                EmptyStateView(icon: "checkmark.circle", title: l10n["todos.empty"])
            } else {
                let today = Journal.day(Date())
                let groups = Dictionary(grouping: todos) { TodoScan.group($0, today: today) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(TodoScan.Group.allCases.filter { groups[$0] != nil }, id: \.self) { group in
                            Text(title(group))
                                .font(.panel(.caption1).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(groups[group] ?? []) { todo in
                                row(todo)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func row(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                noteStore.complete(todo)
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)
            .help(l10n["tooltip.todo.done"])

            Button {
                noteStore.open(todo)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.text)
                        .font(.panel(.body))
                        .multilineTextAlignment(.leading)
                    Text([todo.due, noteStore.note(at: todo.path)?.title].compactMap(\.self).joined(separator: " · "))
                        .font(.panel(.caption1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}
