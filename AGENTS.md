# Markdown Viewer

Go owns document state, rendering and persistence. AppKit/WebKit is a thin macOS shell; HTML/CSS/JavaScript owns presentation.

Product test seams: the app's JSON command dispatcher (the same commands sent by WebKit), observable response HTML and state, and actual files in a temporary directory. Native UI acceptance uses the bundled application via Finder/open and keyboard actions. Tests should catch lost edits, stale writes, failed-save navigation, undo persistence, and unsafe rendered content.

Verify with `go test ./...`, `go vet ./...`, and `./scripts/build.sh`. Never label native behavior verified from Go tests alone.
