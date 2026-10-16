import AppKit
import SwiftUI

// MARK: - FindBarView

/// Overlay bar that slides down from the top of the editor to provide Find and
/// Replace. It drives the engine through the MarkdownEditorBus notification
/// names defined in MarkdownEditorView.swift:
///
///   `.editorFindQuery`           — search, highlight, scroll to the current match
///   `.editorFindResults`         — the engine's reply: how many matches
///   `.editorReplaceCurrent/All`  — replace in place, as one undo step
///   `.editorFindClearHighlights` — clear highlights
///
/// The engine searches the text it shows and edits it in place; the bar keeps
/// only the query, the count and which match is current.
struct FindBarView: View {
    /// Controls visibility. Set to false to dismiss.
    var isPresented: Binding<Bool>
    /// The editor's live text, watched so the count follows edits made while the bar is open.
    let editorText: String

    @State private var query = ""
    @State private var replaceQuery = ""
    @State private var matchCount = 0
    @State private var currentIndex = 0
    @State private var caseSensitive = false
    /// Searches once typing pauses; each search highlights every match, so
    /// running it per keystroke made typing a query lag in long notes.
    @State private var searchDebouncer = Debouncer(delay: 0.08)

    @FocusState private var isSearchFocused: Bool

    @Environment(L10n.self) private var l10n

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                // Row 1: search field + navigation + options + close
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)

                    TextField(l10n["find.placeholder"], text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onSubmit { navigateForward() }
                        .onKeyPress(.escape) {
                            dismiss()
                            return .handled
                        }

                    // Match counter / no-results indicator
                    Group {
                        if !isSearchable {
                            EmptyView()
                        } else if matchCount == 0 {
                            Text(l10n["find.noResults"])
                                .foregroundStyle(.secondary)
                                .font(.panel(.caption1))
                        } else {
                            Text(l10n.t(
                                "find.matchCount",
                                "\(currentIndex + 1)",
                                "\(matchCount)",
                            ))
                            .foregroundStyle(.secondary)
                            .font(.panel(.caption1))
                            .monospacedDigit()
                        }
                    }
                    .frame(minWidth: 48, alignment: .trailing)

                    Divider().frame(height: 14)

                    // Previous match
                    Button { navigateBackward() } label: {
                        Image(systemName: "chevron.up")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("\(l10n["tooltip.find.previous"]) (⇧↩)")

                    // Next match
                    Button { navigateForward() } label: {
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("\(l10n["tooltip.find.next"]) (↩)")

                    Divider().frame(height: 14)

                    // Case-sensitive toggle
                    Button {
                        caseSensitive.toggle()
                    } label: {
                        Text("Aa")
                            .font(.system(size: 11, weight: caseSensitive ? .bold : .regular))
                            .foregroundStyle(caseSensitive ? .primary : .secondary)
                            .frame(width: 22, height: 18)
                            .background(
                                caseSensitive
                                    ? AnyView(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                                    : AnyView(EmptyView()),
                            )
                    }
                    .buttonStyle(.plain)
                    .help(l10n["tooltip.find.matchCase"])

                    Divider().frame(height: 14)

                    // Close button
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help(l10n["find.close"])
                }

                // Row 2: replace field + buttons
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)

                    TextField(l10n["find.replace.placeholder"], text: $replaceQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { replaceCurrent() }

                    Divider().frame(height: 14)

                    Button(l10n["find.replace"]) { replaceCurrent() }
                        .buttonStyle(.plain)
                        .help(l10n["tooltip.find.replace"])
                        .disabled(matchCount == 0 || !isSearchable)
                        .foregroundStyle(matchCount == 0 || !isSearchable ? .tertiary : .primary)

                    Button(l10n["find.replaceAll"]) { replaceAll() }
                        .buttonStyle(.plain)
                        .help(l10n["tooltip.find.replaceAll"])
                        .disabled(matchCount == 0 || !isSearchable)
                        .foregroundStyle(matchCount == 0 || !isSearchable ? .tertiary : .primary)

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            Divider()
        }
        .onAppear {
            isSearchFocused = true
        }
        .onDisappear {
            searchDebouncer.cancel()
            postClearHighlights()
        }
        .onChange(of: query) { _, _ in
            currentIndex = 0
            searchDebouncer.call { search() }
        }
        .onChange(of: caseSensitive) { _, _ in search() }
        .onChange(of: editorText) { _, _ in
            // Keep the count right while the note is edited with the bar open.
            searchDebouncer.call { search() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorFindResults)) { note in
            matchCount = note.userInfo?["count"] as? Int ?? 0
            currentIndex = matchCount == 0 ? 0 : min(currentIndex, matchCount - 1)
        }
    }

    // MARK: - Search

    /// Fewer than two characters match nearly everywhere, so nothing is searched.
    private var isSearchable: Bool {
        query.count >= 2
    }

    /// Searches now. The engine highlights the matches, scrolls to the current one
    /// and posts the count back (`.editorFindResults`).
    private func search() {
        searchDebouncer.cancel()
        guard isSearchable else {
            matchCount = 0
            currentIndex = 0
            postClearHighlights()
            return
        }
        post(.editorFindQuery, ["query": query, "currentIndex": currentIndex, "caseSensitive": caseSensitive])
    }

    // MARK: - Navigation

    private func navigateForward() {
        step(by: 1)
    }

    private func navigateBackward() {
        step(by: -1)
    }

    /// A search still waiting on the debounce runs first, so ↩ right after typing
    /// steps through the new query's matches.
    private func step(by delta: Int) {
        if searchDebouncer.isPending { search() }
        guard matchCount > 0 else { return }
        currentIndex = (currentIndex + delta + matchCount) % matchCount
        search()
    }

    // MARK: - Replace

    private func replaceCurrent() {
        guard matchCount > 0, isSearchable else { return }
        searchDebouncer.cancel()
        post(.editorReplaceCurrent, [
            "query": query, "replacement": replaceQuery,
            "currentIndex": currentIndex, "caseSensitive": caseSensitive,
        ])
    }

    private func replaceAll() {
        guard matchCount > 0, isSearchable else { return }
        searchDebouncer.cancel()
        post(.editorReplaceAll, ["query": query, "replacement": replaceQuery, "caseSensitive": caseSensitive])
    }

    // MARK: - Bus notifications

    private func post(_ name: Notification.Name, _ userInfo: [String: Any]) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    private func postClearHighlights() {
        NotificationCenter.default.post(name: .editorFindClearHighlights, object: nil)
    }

    // MARK: - Dismiss

    private func dismiss() {
        // onDisappear handles the bus cleanup; just flip the binding.
        isPresented.wrappedValue = false
    }
}
