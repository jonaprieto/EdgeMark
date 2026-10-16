# Changelog

User-visible changes, newest first. Every change adds a line under Unreleased in the
same commit. Releases before 2.13.2 are on the GitHub Releases page.

## Unreleased

### Added

- Encrypted notes (age, X25519): encrypt, decrypt, lock and unlock from the list or the
  editor. The key lives in the login Keychain; `.age` files sync as opaque blobs.
- Encryption setup wizard and a Security tab in Settings.
- Lock button in the editor. An encrypted note locks when you leave it.
- The panel opens from both edges, including edges between displays.
- Button to update gists from GitHub now.
- Click a folder or note in a folder preview to open it.

### Changed

- Light appearance by default.
- A gist with one file shows as that file in Gists, not as a folder.
- Larger text in the panel.
- Sorting by name lists A to Z and sorting by date lists newest first; the direction can
  still be flipped.

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
