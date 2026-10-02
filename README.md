# Markdown Viewer

A Go macOS application with a native AppKit window and an embedded WebKit reading surface. No local server, Electron, Node runtime, or hosted frontend. The application core is Go; the macOS bridge is Objective-C and the embedded UI is HTML/CSS/JavaScript.

## Run

Requires macOS 12+, Go 1.25+, and Xcode Command Line Tools.

```sh
./scripts/build.sh
open "dist/Markdown Viewer.app"
open -a "$PWD/dist/Markdown Viewer.app" examples/Welcome.md
```

The build creates an ad-hoc signed app for the current Mac architecture. It is not notarized for distribution to other Macs. If the environment restricts the shared Go cache, set `GOCACHE` to a writable directory before building.

## Install and associate Markdown files

```sh
./scripts/install.sh
```

This builds, copies the app into `~/Applications`, and registers it with Launch Services. It refuses to replace an existing installation. An optional argument selects a different installation directory.

To make it the default: select a `.md` file in Finder → **Get Info** → **Open with** → **Markdown Viewer** → **Change All…**. Repeat for `.markdown` or `.mdown` if needed. The app declares its Markdown document types and receives Finder open-file events, including when already running. Installing does not change your existing defaults automatically.

## Use

- **Preview is the default.** Toggle to the raw editor using the toolbar or **⌘E**.
- **Live saving:** each text input is queued in order and written atomically to disk. Save errors stay visible, preserve the draft, and prevent opening another document or quitting until resolved. **Save Copy** writes the draft under a new filename; **Reload** explicitly discards it after confirmation.
- **Undo / redo:** **⌘Z / ⇧⌘Z** work across preview/editor toggles and write the result to disk. History is in memory for the current document, bounded to 500 snapshots or roughly 32 MiB (at least one undo step retained). Opening another file or reloading resets it.
- **Appearance:** choose Paper, Night, Sepia, or System and serif, sans serif, or monospace reading typography. Preferences persist between launches.
- **Recent files:** use Recents or **⇧⌘O**. The most recent 15 paths persist.
- **Open folders:** **⌘O** accepts a file or folder. Only opening a folder shows the sidebar. It lists Markdown files recursively, skips hidden directories, and supports up to 5,000 files. Close the sidebar with its × button.
- **New file:** **⌘N**. **Save Copy:** **⇧⌘S**. Both require a new filename to avoid accidental replacement.
- CommonMark plus tables, strikethrough, task lists, and fenced code. Local PNG/JPEG/GIF/WebP images inside the document directory are embedded. Web links open in the default browser. Relative document links open in the app.

## Persistence and limits

Settings live in the platform user-config directory under `Markdown Viewer/settings.json`. On macOS this is normally `~/Library/Application Support/Markdown Viewer/`. Set `MARKDOWN_VIEWER_CONFIG` to an alternate config root for isolated runs.

Files must be regular UTF-8 text, at most 16 MiB. Symlinks are resolved on open. Saves preserve POSIX permission bits and replace the file using a temporary sibling and rename; extended attributes, hard-link identity, and ACL preservation are not implemented. Disk content is compared with the last saved version before writing; external edits cause a conflict instead of a blind overwrite. This is not a cross-process lock: another writer can still race the final check and rename. External changes are not automatically reloaded.

Markdown is untrusted input. Raw HTML is omitted, output passes through a tag/attribute/URL allowlist, and a Content Security Policy blocks network content and embedded frames. Remote images and SVG are intentionally not loaded. There is no arbitrary custom CSS loading, syntax coloring, PDF export, or split-pane editing in this initial version.

## Development and verification

```sh
go test ./...
go vet ./...
node --check cmd/markdown-viewer/ui/app.js # optional development check
./scripts/build.sh
```

`internal/app` exposes the same JSON command contract used by WebKit. Tests drive it against actual temporary files to check preview output, live saving, durable undo/redo, permissions, recent files, themes, folders, unsafe Markdown, and preservation of unsaved drafts on conflicts. Native UI acceptance must be performed separately; Go tests do not prove AppKit/WebKit behavior.

Structure: `internal/document` owns file persistence and safe rendering; `internal/app` owns session commands and preferences; `cmd/markdown-viewer` contains the macOS shell and embedded UI; `scripts` packages the app.

The renderer uses [Goldmark](https://github.com/yuin/goldmark), with a separate application-level HTML allowlist. The macOS shell implements Apple's [open-file delegate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:openfiles:)). Dependencies are pinned in `go.mod`/`go.sum`; this environment built from its offline cache.
