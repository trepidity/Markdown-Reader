# Verification — 2026-10-02

## Executed checks

- `go test -race ./...`: fifteen app command-interface tests passed against real temporary files. The tests cover live edit/undo/redo persistence, permission bits, recent files, external-change conflicts and recovery copies, folder behavior, durable appearance settings, safe rendering, heading/control ID isolation, and retained oversized drafts.
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

## Resizable sidebar and text search

- Native drag widened the sidebar from 235 to 399 px; the saved width was read back from settings and restored after relaunch. Width persistence and rejection of out-of-range values are covered by a command-interface regression test observed red before implementation.
- Search tests were observed red before implementation and cover literal Unicode queries, case matching, source selection offsets, open-document snapshots and retained drafts, undo across document switches, closed-document exclusion, recursive folder rescanning, hidden/non-Markdown exclusions, outside-folder symlink exclusion, unsupported-file warnings, empty/no-match queries, invalid scopes, and the result limit.
- Native Cmd-F highlighted two case-insensitive matches; Match case reduced the count to one. Cmd-Shift-F returned three matches across two folder documents. Selecting a result opened the second document and highlighted its match. Open-documents scope returned the same three matches after both documents were opened. A Markdown-syntax match absent from preview switched to the editor and selected the exact source text.
- Limits: queries are literal single-line text; results are capped at 1,000 matches and 64 MiB searched, with a visible truncation notice. Open documents refresh automatically; unsaved conflicting drafts remain in memory. Native tests do not qualify search performance for very large folders.

## Search modal and control consistency

- Search uses a native WebKit modal dialog with matching files on the left and highlighted source matches plus up to two surrounding lines on the right. Context text and highlight offsets are asserted by the Unicode search test.
- The final native build was visually inspected: search input, scope dropdown, Match case control, Find, close, navigation, and Open match share 36 px sizing, border/radius tokens, and focus treatment. The primary Open match action retains its accent fill.
- Keyboard-only native acceptance: query submission focused the first file; Down selected the second file; Right focused its match; Enter closed the modal, opened the second document, and highlighted the selected word in preview. Escape dismissal was also exercised.
- Final checks: all 11 app tests passed with the race detector; Go vet, JavaScript syntax, application build, and ad-hoc signature verification passed.

## File-only windows and live reload

- A regression test was observed failing before explicit file opens were separated from folder navigation. Cold file opens and explicit file opens after a folder hide the sidebar; selecting a file within a folder preserves it. Failed opens preserve the current context.
- Three live-reload command tests were observed failing before implementation, then passed. They exercise external content and rendered HTML, inactive-document search, atomic replacement with the same size/timestamp, own-save undo retention, conflicting drafts, deleted/recreated files, invalid UTF-8 recovery, and stale-revision edits that must not overwrite external content even on retry.
- Native acceptance: opening a recent file showed no sidebar; opening its folder displayed the sidebar and its saved width; explicitly reopening the file through Recents hid the sidebar again.
- Native acceptance: externally writing a fixture updated its rendered heading and paragraph automatically. A second external write in edit mode updated the textarea while retaining edit mode and focus.
- Final checks: all 15 app tests passed with the race detector; Go vet, JavaScript syntax checking, and the macOS build passed. Automatic refresh uses a 750 ms timer plus application activation. Scroll/selection preservation is implemented but long-document native scroll behavior has not been separately qualified.
