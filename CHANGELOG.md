# Changelog

User-visible changes, newest first. Every change adds a line under Unreleased in the
same commit. Releases before 2.13.2 are on the GitHub Releases page.

## Unreleased

### Changed

- A new app icon: the Markdown hash next to the screen edge, on the Mac and the iPhone.

### Added

- An iPhone app opens your notes, edits them and keeps them in sync with the Mac through GitHub.
  Its files are encrypted while the phone is locked, and stay out of device backups.
- The iPhone app keeps a journal: capture a meal, idea or todo in seconds, into one Markdown file
  per day in the Journal folder.
- Dictate on the iPhone with Apple's on-device transcription, in Spanish or English. No audio is
  kept.
- The iPhone app records where you finish a note, rounded to about 110 m, and shows it on a map.
  The positions sit in a log of their own, never in the note text.
- A Todos tab on the iPhone lists every open task across your notes, grouped by note, by what changed
  recently or by due date, and searchable.
- An Ideas tab on the iPhone lists your ideas and observations with when and where you wrote them,
  and searches them. Meetings and gists are searchable too.
- A Meetings tab on the iPhone lists upcoming events from your calendars, Google and Proton included
  once iOS has them, and opens a note for each one to collect ideas.
- Todos in the settings menu lists every open task across your notes, soonest first, and checks
  them off; Today opens the journal file of the day.
- Brainstorm with OpenAI from a note on the iPhone, typing or speaking, and save the conversation as
  a note in the Brainstorms folder.
- The iPhone notes list has a sync button, says when it last synced or why it could not, and shows
  the app version.
- Your gists appear in a Gists folder on the iPhone, read-only and available offline.
- Swipe to delete a note or a meeting's note on the iPhone. It goes from both devices, and your
  repository's history keeps a copy. A calendar event stays in its calendar.
- The iPhone app opens on Today, which has an Edit button for the day's file and lists each place once.
- Check off a task on the iPhone right where it sits, in a note or in Today, not only in Todos.
- Meetings on the iPhone are grouped into Today, Tomorrow, This week, Next week and Later.
- Add a meeting on the iPhone in one sentence, typed or spoken, such as "Felipe martes 3pm": it reads
  the name, day and hour, and the Meetings tab says which calendars it can see.
- Add photos or take one with the camera on the iPhone, in a capture or a note. They sync to the Mac
  with the note, and Ideas shows them next to the text.
- Notes on the iPhone render highlighted code, math, Mermaid diagrams and images.
- Notes encrypted on the Mac open on the iPhone after Face ID, can be edited there, and close when
  you leave. Mark a new note or capture as Private to encrypt it, with no position recorded.
- Widgets for the iPhone: add a meal, idea or todo in one tap, or start dictating from the Home
  Screen or Lock Screen. An agenda widget shows the next meeting and top todos, hidden while the
  phone is locked.

## 2.17.0 (2026-10-19)

### Added

- An appearance button in the list footer switches between System, Light and Dark.
- ⇧⌘H highlights the selected text, including inside a table, and removes a highlight it is
  pressed in.
- ⇧⌘F opens the search over all notes from anywhere, an open note included; Escape returns to
  the note.
- A note in a gist has an upload button, with the other icons on the right of its header, that
  pushes the gist right away and shows whether it is synced.

### Changed

- Edits in a gist are pushed 10 seconds after you stop typing, not after the notes delay (2
  minutes by default). Sync settings can change the gist delay or turn automatic gist pushes
  off.
- In Gists, gists with several files and single-file gists sort together by date or name,
  instead of all multi-file gists first.
- Updating Gists pulls several gists at once, so it finishes much sooner. The update button spins
  while it runs, and the message says how many new gists arrived, that there were none, or that
  GitHub could not list them.
- Publishing a note as a gist opens Gists with the note selected, so it is clear where the note
  moved.
- Inline code sits in a rounded gray box, so it stands apart from the text around it.
- A click or drag in a table selects its text to copy with ⌘C; a double click opens the table
  for editing.

### Fixed

- A link far down in a table cell that wraps over several lines opens when clicked, instead of
  putting the table into edit mode.
- Bold, italic, highlight, strikethrough or code on a selection that spans several table cells
  formats each cell and keeps the table intact.
- ⌘+, ⌘- and ⌘0 change the text size in code and other plain-text files (a .patch, say) too.
  Those files now follow the editor text size, like code blocks in notes.
- Empty folders stay at the end of a list sorted by date, newest first included.

## 2.16.0 (2026-10-18)

### Added

- In a note, ⌘+ and ⌘- make the text bigger or smaller, and ⌘0 puts it back to the default
  size.
- Claude Code can connect to EdgeMark as an IDE with `/ide` from the notes folder, and sees
  the open note and the selected text.
- Send Selection to Claude in a note's right-click menu puts the selected lines in Claude
  Code's prompt.
- Pinching closed on the trackpad goes back to the notes home from a note or a folder.
- Remind Me on a note, from the list's menu or the bell in the editor: in 1 or 3 hours,
  tonight, tomorrow morning or every weekday. The reminder opens the note, and with a Jev
  key the bell marks the option that fits the note.
- Notes with a reminder show a bell next to their title in the list.
- Custom date and time for a reminder, from Remind Me > Custom.

### Changed

- The list and an open note share one panel width again, so opening a note no longer
  resizes the panel.

### Fixed

- Swiping between pages with three fingers works like two-finger swipes: in a note it goes
  to the previous or next note, and on a header it goes back.
- The panel stays open while the mouse is over any EdgeMark window, such as an alert, a
  popup or Settings, and hides once it leaves them all.

## 2.15.1 (2026-10-16)

### Fixed

- Find stays fast in long notes: typing a query no longer stalls the editor, and searching
  starts at two characters.
- Replace and Replace All edit the note in place and undo in one step; Match Case applies
  to them too.

## 2.15.0 (2026-10-15)

### Added

- Drag the hover preview's outer edge to change its width; the width is remembered.
- Reference-style links (`[text][label]`, `[label]`) and footnotes (`[^1]`) show as links;
  a footnote jumps to its note and back.

### Fixed

- Links in tables show as links and open when clicked, including `<url>` and bare URLs.
- A link to a heading (`#heading`) scrolls to it instead of opening the browser.
- An escaped pipe (`\|`) stays inside its table cell.
- A note's preview in the list drops `***`, `~~`, `==` and link markup.

## 2.14.0 (2026-10-15)

### Added

- Encrypted notes (age, X25519): encrypt, decrypt, lock and unlock from the list or the
  editor. The key lives in the login Keychain; `.age` files sync as opaque blobs.
- Encryption setup wizard and a Security tab in Settings.
- Lock button in the editor. An encrypted note locks when you leave it.
- The panel opens from both edges, including edges between displays.
- Button to update gists from GitHub now.
- Click a folder or note in a folder preview to open it.

### Changed

- The panel remembers one width for the list and another for an open note.
- Light appearance by default.
- A gist with one file shows as that file in Gists, not as a folder.
- Larger text in the panel.
- Sorting by name lists A to Z and sorting by date lists newest first; the direction can
  still be flipped.
- A note's date in the list is the one the list is sorted by: modified, or created when
  sorting by date created.

### Fixed

- A hover preview closes once the mouse is away from the panel and the preview, and when
  going back.
- The panel hides when the mouse leaves it through a preview, after a preview closed, or
  during its opening animation.
- A note with a very long title can be deleted; it no longer comes back after a reload.
- The preview no longer stays on screen after the panel hides.
- A folder preview lists the notes the folder shows when opened.
- Both edges stay armed unless one was chosen.
- A gist file is dated by its last commit.
- The About tab points at this fork.
- Focus stays in a new note after naming it.
