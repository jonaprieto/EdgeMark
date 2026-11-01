<img src=".github/assets/EdgeMark.svg" alt="EdgeMark" width="128" align="left" />

# EdgeMark

Your notes, at the edge of your Mac screen and in your pocket.

<br clear="all" />

EdgeMark is a native Markdown notes app. On the Mac, a panel slides in from the screen edge. On the iPhone, a journal captures meals, ideas, todos and meeting thoughts in seconds. Both work on plain `.md` files that sync through your own private GitHub repository, with no account to create, no server and no lock-in.

This is a personal fork by Jonathan Prieto-Cubides ([jonaprieto](https://github.com/jonaprieto)) of [Ender-Wang/EdgeMark](https://github.com/Ender-Wang/EdgeMark), where the app and nearly all of its code come from. It is based on upstream v2.12.0 and stays under GPL-3.0.

## What you get

On the Mac:

- A side panel with a native editor: tables, code blocks, Mermaid diagrams, LaTeX, no web view.
- Sync to GitHub, including your gists, with a guard that holds back secrets before a push.
- Todos across all your notes, and a journal file for each day.
- Export to Markdown, PDF or a gist, and per-note encryption.
- Claude Code sees the note you have open.

On the iPhone:

- Your notes, ready to read and edit, offline too, and your gists to read.
- Quick capture for sleep, a meal, idea, todo or meeting thought, typed, dictated in Spanish or English on the device, or with a photo.
- Notes that render code, math, Mermaid diagrams and images.
- An agenda: upcoming meetings from your calendars, each with a note for its ideas, and any meeting you add in one sentence, such as "Felipe martes 3pm".
- Every open todo from every note, with due dates.
- Reminders: on a note, like the Mac, or typed in one sentence, such as "llamar a mamá mañana a las 3".
- Home Screen and Lock Screen widgets.
- Brainstorming with OpenAI from any note.
- A map of where you finished each note.

Your notes stay readable without EdgeMark: they are Markdown files in a git repository.

## Install on the Mac

```bash
brew install --cask jonaprieto/tap/edgemark
```

This conflicts with upstream's cask (`ender-wang/tap/edgemark`); uninstall that one first.

<details>
<summary>Other ways to install</summary>

Download the DMG from the [Releases page](https://github.com/jonaprieto/EdgeMark/releases), drag the app to Applications, and run this once, because the build is ad-hoc signed and not notarized:

```bash
xattr -cr /Applications/EdgeMark.app
```

To build from source you need Xcode 26 and macOS 15.7 or later:

```bash
./scripts/install.sh
```

</details>

## Set up sync

1. Install `git` and `gh`, then run `gh auth login`.
2. Open Settings > Sync and pick the GitHub account.
3. Choose Create private repo, or Connect existing if the notes folder already has a remote.
4. Optional: add a TypeSafe (Jev) key under Settings > Sync, where it is stored in the Keychain, or export `TYPESAFE_API_KEY` in your shell profile.

Sync runs on its own from then on; the footer button shows the state.

## Run it on your iPhone

The iPhone app is not on the App Store. You build it from this repository and install it from your Mac, with a free Apple account. You need:

- A Mac with Xcode, your Apple ID added under Xcode > Settings > Accounts, and the iOS 26 SDK or later.
- An iPhone on iOS 26 or later, with Developer Mode on (Settings > Privacy & Security).
- Your notes in a private GitHub repository, set up as in [Set up sync](#set-up-sync).

**1. Get the code and point it at your notes.** Set `repository` in `Phone/Sources/PhoneModel.swift` to your notes repository.

```bash
git clone https://github.com/jonaprieto/EdgeMark.git
cd EdgeMark
```

**2. Give it a token.** The quick way uses your `gh` login:

```bash
export EDGEMARK_GITHUB_TOKEN="$(gh auth token)"
```

That token can do anything your `gh` login can. A safer one is a [fine-grained token](https://github.com/settings/personal-access-tokens/new) with Contents read and write on your notes repository alone, plus Gists read if you want your gists. Either way it stays in the phone's Keychain, never in a file.

**3. Plug in the iPhone, unlock it, and install.** Keep it unlocked until the script ends, because keys reach the app only when the script opens it.

```bash
scripts/phone.sh provision
```

The app opens on Today, with your notes in the next tab. If they do not appear, the line under the Notes list says why.

**4. Turn on Face ID.** Touch and hold the EdgeMark icon, then choose Require Face ID. The app cannot do this for you.

**5. Add the rest.** Add the EdgeMark widgets to the Home Screen or Lock Screen. EdgeMark sees only the calendars on your iPhone, so add your Google account under Settings > Apps > Calendar > Calendar Accounts, and subscribe to a Proton Calendar share link in the Calendar app. The Meetings tab lists the accounts it can read.

**Every 7 days**, a free Apple account's signing expires and the app stops opening. Plug in and run `scripts/phone.sh provision` again. Your notes and token stay on the phone, so there is nothing to export this time. A paid Apple Developer account lasts a year.

<details>
<summary>Optional keys</summary>

Export any of these before running `scripts/phone.sh`. The app keeps them in its Keychain after one launch.

| Variable | What it enables |
|---|---|
| `OPENAI_API_KEY` | Brainstorming |
| `TYPESAFE_API_KEY` | The Jev part of the secret guard before a push |
| `EDGEMARK_AGE_IDENTITY` | Opening encrypted notes. Your `AGE-SECRET-KEY-1...`, kept behind Face ID. Unset it after one run. |

</details>

<details>
<summary>Building for your own Apple account</summary>

The project is set up for one developer. For your own account, replace the team and the bundle identifier:

- `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `Phone/provision/P.xcodeproj/project.pbxproj`.
- `ID` in `scripts/phone.sh`.
- The identifiers in `Phone/Info.plist` and `Phone/Widget/Info.plist`.

</details>

<details>
<summary>If something goes wrong</summary>

| What you see | What to do |
|---|---|
| `no iPhone found` | Plug it in, unlock it, and trust this Mac. |
| `Browsing on the local area network` | Wireless failed. Use the cable. |
| `no profile for ...` | Run `scripts/phone.sh provision`, not plain `scripts/phone.sh`. |
| `installed; unlock the phone and open EdgeMark` | The phone was locked, so keys did not arrive. Unlock it and run the script again. |
| No notes, and "Sync is off" | Same cause: export the token, keep the phone unlocked, run the script again. |
| The sync button shows a warning | Read the line under the notes list. Held files are listed in Settings. |
| The app will not open | The 7 days ran out. Run `scripts/phone.sh provision`. |

</details>

## How your notes are protected

- On the iPhone, iOS encrypts the notes with a key tied to your passcode, and they stay out of device backups. Face ID opens the app; the encryption comes from iOS.
- Notes you encrypt on the Mac stay encrypted everywhere. On the iPhone they open with a key that only Face ID releases, and you can edit them there.
- Mark a new note or capture as Private and it is encrypted the same way, on GitHub too, with no position recorded. Its file name stays readable.
- On GitHub, other notes are plain text in your private repository.
- Before a push, EdgeMark looks for keys and passwords and holds back any file that looks wrong, on the Mac and on the iPhone.
- Your position is rounded to about 110 m and kept in its own log, never in a note, so it cannot reach a gist, an export or OpenAI. That log does stay in your repository's history.

## Features in detail

<details>
<summary>iPhone: how the journal, todos and meetings are stored</summary>

Everything is Markdown, so the Mac reads it with no special support.

- Each day is one file, `Journal/2026-10-31.md`, with Meals, Ideas and Todos sections.
- A meeting is one note, `Meetings/2026-11-03-Felipe.md`, with its ideas inside.
- A brainstorm you save is a note in `Brainstorms/` that links back to where it started.
- A todo is any `- [ ]` line in any note, with an optional `due:2026-11-02`, or `due:2026-11-02T15:30` to ring as a reminder. Existing notes work unchanged.
- Positions are lines in `.edgemark/places.jsonl`.

For journals to merge on the Mac too, add this as `.gitattributes` in your notes folder:

```
Journal/*.md merge=union
.edgemark/places.jsonl merge=union
```

</details>

<details>
<summary>iPhone: how sync works</summary>

iOS cannot run git, so the phone talks to the GitHub API. It syncs when the app opens, when you finish a note, when you pull down or tap the sync button, and on its way to the background. Captures work offline and go out on the next sync.

Each sync compares every file with the last commit both sides agreed on, pulls what changed, merges edits line by line, and pushes one commit. The branch only ever fast-forwards, so the phone cannot rewrite history. Edits that cannot merge leave the remote file in place and your text in a `-phone-conflict-` copy, so no text is dropped. The phone never writes the Mac's `.edgemark/meta.json`.

The Mac picks up phone changes when its panel opens, at most once a minute, and pushes 2 minutes after you stop typing.

</details>

<details>
<summary>Sync and gists on the Mac</summary>

The notes folder is committed and pushed to a GitHub repo through `git` and `gh`. Commits are debounced (120 s after the last save by default, configurable from 30 to 600 s), the repo is pulled when the panel opens (throttled to once a minute), and a pending push is flushed on quit with a 20 second limit. A conflict pauses sync, and the footer button (with a status menu) says what to do. Held-back files are reported the same way.

Your gists are cloned under `Gists/` in the notes folder and kept in sync like the notes repo. Files are listed by file name, non-Markdown gist files can be opened and edited, and non-Markdown files get an extension badge. Any note can be exported or published as a gist, private by default; making one public asks for confirmation. Publishing shows the result.

</details>

<details>
<summary>Secrets guard</summary>

Before each commit, the added lines of changed files are checked against regex rules (private key blocks, AWS, GitHub, Slack and `sk-` style keys, JWTs). If a file passes the regex check and a TypeSafe key is configured, the [Jev](https://typesafe.ai) model judges whether it contains a credential or private personal data. Flagged files are not committed; you can allow a specific one from Settings.

</details>

<details>
<summary>Todos and Today on the Mac</summary>

Todos, in the gear menu, lists every open task across your notes, soonest first, and checks them off in place. Today opens the journal file of the day. Encrypted notes and gists are left out of Todos.

</details>

<details>
<summary>Export</summary>

A note can be exported as Markdown (images are copied next to it and links rewritten) or as PDF, from the export menu.

</details>

<details>
<summary>Claude Code</summary>

When `~/.claude` exists, EdgeMark listens on localhost the way the VS Code extension does. Start `claude` inside the notes folder and run `/ide` (or `claude --ide`) to connect; Claude then sees the open note and the selected text. Right-click in a note and choose Send Selection to Claude (or Send Note to Claude) to put `@note.md#L3-5` in Claude's prompt; this also starts the connection, creating `~/.claude/ide` if needed, and a session that connects later still gets it. Encrypted notes are not shared. The protocol is not documented by Anthropic for other editors, so a Claude Code update can break it. EdgeMark has no diff view: if Claude asks before edits, set the diff tool to `terminal` in `/config` to see diffs in the terminal.

</details>

<details>
<summary>Reminders</summary>

Remind Me, in a note's menu in the list or the bell in the editor header, schedules a macOS notification: in 1 or 3 hours, tonight at 20:00, tomorrow at 9:00, every weekday at 9:00, or a custom date and time. Clicking it opens the note; notes with a pending reminder show a bell in the list, and moving a note to Trash cancels its reminder. With a TypeSafe key, opening the bell asks Jev which option fits the note and marks it as Suggested; nothing is sent for encrypted notes. Reminders live in the macOS notification center, so they stay on the Mac that set them.

The iPhone has the same bell on a note, with the same options, and those reminders stay on the iPhone. A todo with a time is different: it is a line of text, so it syncs, and the iPhone rings it wherever it was written, once it has synced. Its notification offers Done and In 1 hour. Todos > Reminders lists all that will ring, and the Reminders widget shows what comes next.

</details>

<details>
<summary>Editor and panel</summary>

A single click opens notes and folders. A new note takes focus. Code blocks are compact, with line numbers and a copy button. Prose and monospace fonts are set separately in Settings. Mermaid diagrams (a fenced block tagged `mermaid`) render as diagrams while the cursor is outside the block, and as source while it is inside; previews and PDF export show the diagram too. YAML front matter at the top of a note shows as a compact metadata block. Image files are removed from disk when you delete the image from the text. The editor header moves a note to Trash instead of deleting it. Very large or pathological notes open in a plain-text mode. Right-clicking the empty space of the list opens a menu with New Note, New Folder, Sort By, Paste as New Note, Sync Now and more. Icon-only controls have tooltips, with the keyboard shortcut where one is set. In a note, ⇧⌘H highlights the selection (in a table too), ⌘F finds within the note and ⇧⌘F searches all notes (Escape comes back), ⌘+ and ⌘- change the text size and ⌘0 resets it; the list and an open note share one panel width. Swiping between pages with two or three fingers moves to the previous or next note (or back, on a header), and pinching closed goes back to the notes home. A first-run hint and a clearer empty state were added. File type badges mark non-Markdown files, and code files in gists are syntax highlighted by file extension.

Data-loss and speed fixes: existing front matter and horizontal rules are kept when saving, image alt text is kept, titles with brackets get safe image folder names, CRLF titles and non-UTF-8 notes load correctly, and git and `gh` run off the main actor so the panel does not stall.

</details>

## Known limits

<details>
<summary>iPhone</summary>

- Notes cannot be renamed on the phone. Deleting one removes it from both devices. It goes to no Trash on the phone, but git history keeps it, and if the Mac edited it first the edit wins.
- Photos are resized to 2048 px and stay in your repository's history for good, deleted or not.
- Gists are read-only on the phone, and encrypted gists do not open there.
- An existing plain note cannot be made private on the phone. Its old text would stay in git history anyway.
- A private capture cannot hold a photo, because photos are plain files.
- iOS gives no dependable background time, so the phone syncs when you use it, not on a schedule.
- A free Apple account means reinstalling every 7 days.
- Commits from the phone show as unsigned on GitHub.
- Calendars are read-only: a meeting you add is a note, not a calendar event. Proton through a share link can lag up to 8 hours, and a Full view link puts event details outside Proton's encryption; a Limited view link shows busy times only.
- A meeting note matches its event by date and title, so a moved or renamed meeting loses the link and the note stays.
- With a Jev key on the phone, the same text as on the Mac is sent to api.typesafe.ai before a push. The position log never is.

</details>

<details>
<summary>Mac</summary>

- In the editor, the line numbers and copy button of a code block are not shown for the block the cursor is in; they appear when you move out of it.
- PDF export loses the line-number gutter and the copy button of code blocks.
- Mermaid: while you edit a diagram block you also see two `$$` marker lines around it, and a diagram you just typed renders after the note is reopened. Blocks that contain `$$` stay plain code.
- Front matter and Mermaid use invisible marker characters in the editor only; the saved file is unchanged, but copying a selection that spans such a block can include them.
- Highlighting uses highlight.js grammars: Solidity is shown with the JavaScript grammar, Agda and Idris with Haskell, TOML with INI; Lean and a few others stay plain.
- When an export fails, EdgeMark only beeps and writes a log line. There is no alert.
- With a Jev key configured, up to 8 KB of the added text of each file that the regex rules did not already flag is sent to api.typesafe.ai before a push. Without a key, only the regex rules run. Settings states this too.
- `gh` and `git` are hard requirements for sync. There is no merge UI: conflicts are resolved by you in the repo.
- The build is ad-hoc signed and not notarized.

</details>

## About this fork

<details>
<summary>Why this fork exists, and what differs from upstream</summary>

I wanted my notes kept in git on GitHub without leaving the app, and a handful of editor and export changes I use every day. I want to ship those at my own pace and decide where the app goes, without coordinating with anyone or waiting on someone else's changes or review. That is a preference about workflow, and says nothing against upstream.

The same reason explains why this is not contributed upstream: a fast cadence on the features I care about, with full control over direction. The code stays GPL-3.0, so upstream is welcome to take any of it. I make no promise to keep the fork in step with upstream releases. If you hit a bug in one of the original features and it also exists upstream, report it there.

| | Upstream | This fork |
|---|---|---|
| Sync | none | git and `gh` sync of the notes folder and your gists |
| Secrets | n/a | regex rules plus the Jev model hold back sensitive files before a push |
| Export | none | Markdown (with images), PDF, or a gist |
| Updates | in-app updater | disabled; "Check for Updates" opens this fork's Releases page |
| Panel width | saved by dragging | default 671 pt, plus a slider in Settings > Behavior |
| Claude Code | none | connects as an IDE and shares the editor's selection |
| Reminders | none | Remind Me on a note as a macOS notification, with a Jev suggestion |
| Todos | none | a list across all notes, plus a journal file for each day |
| iPhone | none | a companion app with journal, meetings, widgets and dictation |
| Languages | en, de, es, hi, zh-Hans | same, with an English fallback for the new strings |

The translated READMEs (`README-de.md`, `README-ES.md`, `README-hi.md`, `README-zh-Hans.md`) describe upstream. The differences listed here apply to this fork only.

</details>

<details>
<summary>Development</summary>

`swift test` runs the `EdgeSync` package: the sync engine (`EdgeMark/Core/Sync`, tested against a local git remote), the storage, export and journal logic, and the iPhone's sync (`Phone/Sync`, tested against a fake GitHub). For the app, open `EdgeMark.xcodeproj` in Xcode and build the `EdgeMark` scheme, or run `./scripts/install.sh`.

Layout: `EdgeMark/` holds the Mac app (`Core/` for sync, storage, export and editor pieces, `UI/` for views and settings), `Phone/` the iPhone app and its widgets, `Tests/` the test targets. [CONTRIBUTING.md](CONTRIBUTING.md) is upstream's architecture guide and still mostly applies. The default branch `main` is this fork's line of development.

`LiveGitHubTests` runs the phone's sync against a real repository, and is skipped unless pointed at one. It pushes to `main`, so only use a throwaway repository: set `EDGEMARK_LIVE_REPO`, `EDGEMARK_LIVE_TOKEN` and `EDGEMARK_LIVE_CLONE`.

</details>

## Credits and license

EdgeMark is by [Ender-Wang](https://github.com/Ender-Wang/EdgeMark) and licensed under the [GNU General Public License v3.0](LICENSE); this fork keeps that license. It builds on [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) (Apache 2.0), which bundles [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) for code highlighting and [SwiftMath](https://github.com/mgriebling/SwiftMath) for LaTeX. Secret checks use [TypeSafe Jev](https://typesafe.ai). The iPhone app reads Markdown with [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) (MIT).

Mermaid diagrams are drawn by [Mermaid](https://github.com/mermaid-js/mermaid) (MIT), bundled in the app.
