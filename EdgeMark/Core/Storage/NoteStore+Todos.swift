import SwiftUI

/// The Todos screen and the journal's day file. Tasks stay plain lines in their notes.
extension NoteStore {
    func openTodos() {
        navigationDirection = .overlay
        clearSelection()
        withAnimation(.easeInOut(duration: 0.2)) {
            showTodos = true
        }
    }

    func closeTodos() {
        navigationDirection = .overlay
        clearSelection()
        withAnimation(.easeInOut(duration: 0.2)) {
            showTodos = false
        }
    }

    /// Open tasks across notes, soonest first. Encrypted notes and gists are left out: one has
    /// no text while locked, the other is published on its own terms.
    var pendingTodos: [Todo] {
        let open = notes.filter { !$0.isEncrypted && !$0.isGistFile }
            .flatMap { TodoScan.todos(in: $0.content, path: $0.relativePath) }
            .filter { !$0.done }
        return TodoScan.sorted(open, today: Journal.day(Date()))
    }

    func note(at path: String) -> Note? {
        notes.first { $0.relativePath == path }
    }

    /// Checks the task off in its note. A line that changed since the scan is left alone.
    func complete(_ todo: Todo) {
        guard let note = note(at: todo.path), let text = TodoScan.toggled(todo, in: note.content) else { return }
        updateContent(for: note.id, content: text)
        saveDirtyNotes()
    }

    func open(_ todo: Todo) {
        guard let note = note(at: todo.path) else { return }
        showTodos = false
        openNoteFromSearch(note)
    }

    /// Opens today's file in `Journal/`, created on first use.
    func openToday() {
        let now = Date()
        let title = Journal.day(now)
        let existing = notes.first { $0.folder == Journal.folder && $0.title == title }
        openNoteFromSearch(existing ?? createNote(withText: Journal.emptyDay(for: now), in: Journal.folder))
    }
}
