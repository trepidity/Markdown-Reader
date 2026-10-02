# Verification — 2026-10-02

## Executed checks

- `go test -race ./...`: six app command-interface tests passed against real temporary files. The tests cover live edit/undo/redo persistence, permission bits, recent files, external-change conflicts and recovery copies, folder behavior, durable appearance settings, safe rendering, heading/control ID isolation, and retained oversized drafts.
- Initial behavior tests were run against an empty dispatcher and failed for missing behavior before implementation. Heading-ID collision and oversized-draft regressions were separately observed red before their fixes.
- `go vet ./...`, JavaScript syntax checking, shell syntax checking, and `plutil -lint Info.plist`: passed.
- `scripts/build.sh`: built the arm64 macOS app. Ad-hoc signature verification passed.

The Go commands used `GOCACHE=/private/tmp/markdown-viewer-go-cache` because the default shared cache was restricted in this environment.

## Native AppKit/WebKit checks

Performed in the actual bundled app with disposable Markdown content:

- Welcome page and default rendered file view displayed; Paper and Night were visually inspected.
- Native Open dialog opened a file; headings, tables, task lists, and code rendered.
- Raw editing wrote the exact expected content to disk; Cmd-Z wrote the preceding content to disk; redo returned it in preview.
- Theme and recent-file settings survived quit/relaunch; a recent file reopened in preview.
- An external file edit caused a visible save conflict. The draft remained in the editor and Cmd-Q was blocked. Explicit Reload displayed native confirmation and recovered the external version.
- Opening the examples folder displayed the sidebar; selecting Welcome.md displayed the rendered document.
- A clean Cmd-Q exited the app.

## Remaining qualification limits

- Command-line `open -a` returned Launch Services error -10827 despite a valid executable/signature; explicit `lsregister -f` scanning returned -10822. The same bundle launched successfully via the native application interface. The root cause of the command-line registration failure is not established.
- Installation and changing Finder's default application were not performed. The app bundle declares Markdown document associations; `scripts/install.sh` and README provide registration/default-selection steps. Finder-delivered open-file Apple events remain unverified.
- Save Copy recovery is tested through the actual Go command/disk seam; its native save panel was not exercised.
- No notarization, distribution signing, performance qualification, crash-durability guarantees, or concurrent external-writer locking.
