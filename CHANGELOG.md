# Changelog

User-visible changes, newest first. Every change adds a line under Unreleased in the
same commit. Releases before 2.13.2 are on the GitHub Releases page.

## Unreleased

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
