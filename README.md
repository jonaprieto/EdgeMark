<img src=".github/assets/EdgeMark.svg" alt="EdgeMark" width="128" align="left" />

# EdgeMark

<br clear="all" />

EdgeMark is a native macOS side-panel Markdown notes app: a panel that slides in from the screen edge, plain `.md` files on disk, a TextKit 2 editor with no web view. This repository is a personal fork by Jonathan Prieto-Cubides ([jonaprieto](https://github.com/jonaprieto)) with GitHub sync built in. It is a fork of [Ender-Wang/EdgeMark](https://github.com/Ender-Wang/EdgeMark), which is where the app and nearly all of its code come from; the fork is based on upstream v2.12.0 and stays under GPL-3.0.

The translated READMEs (`README-de.md`, `README-ES.md`, `README-hi.md`, `README-zh-Hans.md`) describe upstream. The differences listed here apply to this fork only.

## Why this fork exists

I wanted my notes kept in git on GitHub without leaving the app, and a handful of editor and export changes I use every day. I want to ship those at my own pace and decide where the app goes, without coordinating with anyone or waiting on someone else's changes or review. That is a preference about workflow, and says nothing against upstream.

## Why not contribute upstream

For the same reason: a fast cadence on the features I care about, with full control over direction. The code stays GPL-3.0, so upstream is welcome to take any of it. I make no promise to keep the fork in step with upstream releases. If you hit a bug in one of the original features and it also exists upstream, report it there.

## What is different from upstream

| | Upstream | This fork |
|---|---|---|
| Sync | none | git and `gh` sync of the notes folder and your gists |
| Secrets | n/a | regex rules plus the Jev model hold back sensitive files before a push |
| Export | none | Markdown (with images), PDF, or a gist |
| Updates | in-app updater | disabled; "Check for Updates" opens this fork's Releases page |
| Panel width | saved by dragging | default 671 pt, plus a slider in Settings > Behavior |
| Languages | en, de, es, hi, zh-Hans | same, with an English fallback for the new strings |

Sync. The notes folder is committed and pushed to a GitHub repo through `git` and `gh`. Commits are debounced (120 s after the last save by default, configurable from 30 to 600 s), the repo is pulled when the panel opens (throttled to once a minute), and a pending push is flushed on quit with a 20 second limit. A conflict pauses sync, and the footer button (with a status menu) says what to do. Held-back files are reported the same way.

Gists. Your gists are cloned under `Gists/` in the notes folder and kept in sync like the notes repo. Files are listed by file name, non-Markdown gist files can be opened and edited, and non-Markdown files get an extension badge. Any note can be exported or published as a gist, private by default; making one public asks for confirmation. Publishing shows the result.

Secrets guard. Before each commit, the added lines of changed files are checked against regex rules (private key blocks, AWS, GitHub, Slack and `sk-` style keys, JWTs). If a file passes the regex check and a TypeSafe key is configured, the [Jev](https://typesafe.ai) model judges whether it contains a credential or private personal data. Flagged files are not committed; you can allow a specific one from Settings.

Export. A note can be exported as Markdown (images are copied next to it and links rewritten) or as PDF, from the export menu.

Editor and panel. A single click opens notes and folders. A new note takes focus. Code blocks are compact, with line numbers and a copy button. Image files are removed from disk when you delete the image from the text. The editor header moves a note to Trash instead of deleting it. Very large or pathological notes open in a plain-text mode. A first-run hint and a clearer empty state were added. File type badges mark non-Markdown files.

Data-loss and speed fixes. Existing front matter and horizontal rules are kept when saving, image alt text is kept, titles with brackets get safe image folder names, CRLF titles and non-UTF-8 notes load correctly, and git and `gh` run off the main actor so the panel does not stall.

## Install

```bash
brew install --cask jonaprieto/tap/edgemark
```

This conflicts with upstream's cask (`ender-wang/tap/edgemark`); uninstall that one first.

Or download the DMG from the [Releases page](https://github.com/jonaprieto/EdgeMark/releases), drag the app to Applications, and run this once, because the build is ad-hoc signed and not notarized:

```bash
xattr -cr /Applications/EdgeMark.app
```

To build from source you need Xcode 26 and macOS 15.7 or later:

```bash
./scripts/install.sh
```

## Set up sync

1. Install `git` and `gh`, then run `gh auth login`.
2. Open Settings > Sync and pick the GitHub account.
3. Choose Create private repo, or Connect existing if the notes folder already has a remote.
4. Optional: add a TypeSafe (Jev) key under Settings > Sync, where it is stored in the Keychain, or export `TYPESAFE_API_KEY` in your shell profile.
5. Sync runs on its own from then on; the footer button shows the state.

## Known limits

- In the editor, the line numbers and copy button of a code block are not shown for the block the cursor is in; they appear when you move out of it.
- PDF export loses the line-number gutter and the copy button of code blocks.
- When an export fails, EdgeMark only beeps and writes a log line. There is no alert.
- With a Jev key configured, up to 8 KB of the added text of each file that the regex rules did not already flag is sent to api.typesafe.ai before a push. Without a key, only the regex rules run. Settings states this too.
- `gh` and `git` are hard requirements for sync. There is no merge UI: conflicts are resolved by you in the repo.
- The build is ad-hoc signed and not notarized.

## Development

`swift test` runs the `EdgeSync` package: the sync engine (`EdgeMark/Core/Sync`, tested against a local git remote) plus the storage and export logic (`EdgeStorageLogic`, `EdgeExportLogic`). For the app, open `EdgeMark.xcodeproj` in Xcode and build the `EdgeMark` scheme, or run `./scripts/install.sh`.

Layout: `EdgeMark/` holds the app (`Core/` for sync, storage, export and editor pieces, `UI/` for views and settings), `Tests/` the three test targets. [CONTRIBUTING.md](CONTRIBUTING.md) is upstream's architecture guide and still mostly applies. The default branch `main` is this fork's line of development.

## Credits and license

EdgeMark is by [Ender-Wang](https://github.com/Ender-Wang/EdgeMark) and licensed under the [GNU General Public License v3.0](LICENSE); this fork keeps that license. It builds on [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) (Apache 2.0), which bundles [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) for code highlighting and [SwiftMath](https://github.com/mgriebling/SwiftMath) for LaTeX. Secret checks use [TypeSafe Jev](https://typesafe.ai).

Mermaid diagrams are drawn by [Mermaid](https://github.com/mermaid-js/mermaid) (MIT), bundled in the app.
