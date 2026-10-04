# Verification — 2026-10-02

## Executed checks

- `go test -race ./...`: fifteen app command-interface tests passed against real temporary files. The tests cover live edit/undo/redo persistence, permission bits, recent files, external-change conflicts and recovery copies, folder behavior, durable appearance settings, safe rendering, heading/control ID isolation, and retained oversized drafts.
- Initial behavior tests were run against an empty dispatcher and failed for missing behavior before implementation. Heading-ID collision and oversized-draft regressions were separately observed red before their fixes.
- `go vet ./...`, JavaScript syntax checking, shell syntax checking, and `plutil -lint Info.plist`: passed.
- `scripts/build.sh`: built the arm64 macOS app. Ad-hoc signature verification passed.

The Go commands used `GOCACHE=/private/tmp/markdown-reader-go-cache` because the default shared cache was restricted in this environment.

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

## Design review remediation — 2026-10-02

- Document-changing commands synchronously lock the editor before entering the serial RPC queue. Already accepted edits drain first. Overlapping transitions share a counted lock. Failed navigation/close restores editing; successful close remains locked until AppKit hides and resumes the window or terminates.
- Relative document links send a source path and URI reference separately. Go resolves the URI once, preserves literal percent characters in the source directory, rejects stale-source requests, and retains conflicting drafts on failed navigation.
- Sidebar buttons survive ordinary navigation, preserving keyboard focus. Find consistently searches and focuses results; Open match retains its separate opening action.
- Paper/Sepia muted text now exceeds the 4.5:1 contrast target on both backgrounds. Mode/theme buttons expose pressed state; themes form a named group.

Evidence:

- A Go command-interface regression was observed red for the missing link-resolution command, then green for percent-containing directories, escaped target filenames, invalid/external/missing links, stale source identity, and conflicting-draft preservation.
- `tests/ui/regressions.js` runs the real HTML/CSS/JavaScript in WebKit using a controllable IPC peer. The pre-fix run reported 15 failures across the six review findings. The final run completed nine checks with zero failures, including delayed responses, actual WebKit refusal of typing while locked, overlapping transitions, failed-close recovery, retained sidebar focus, Find/Open match separation, accessible states, and computed contrast. This is WebKit/IPC evidence; the bridge peer is simulated.
- In the bundled native app, a link from a literal `100%` directory opened `other note%.md`. Find remained open and focused the file result after automatic search had completed. Edit/Preview were exposed as native accessibility toggle buttons. Paper and Sepia were visually inspected. An edit was confirmed on disk after Close Window; reopening restored editing, and another edit persisted through quit.
- `go test ./...`, `go vet ./...`, JavaScript syntax checks, shell syntax checking, and `./scripts/build.sh` passed using a writable temporary Go cache.
- Native VoiceOver announcements and the exact scheduling race were not independently exercised through manual input. The race is covered by delayed WebKit bridge replies. The computer-use accessibility extractor omitted portions of the native tree after modal interactions; screenshots and disk readback were used where needed.

Reproduce the WebKit regression run on macOS:

```sh
./scripts/build-ui-tests.sh
open -W '/private/tmp/markdown-reader-ui-tests/Markdown Reader UI Tests.app'
cat /private/tmp/markdown-reader-ui-tests/results.json
```

The test bundle exits nonzero on failures and writes an explicit failures array. Launch Services may report only launcher status, so inspect that array. The harness uses disposable state and does not connect to the production Go instance.

## Performance and memory measurements — 2026-10-02

Measured on Apple M2 Ultra (24 logical CPUs), macOS 26.7.1, Go 1.27.1, arm64. Production bundle size: 6,087,232 bytes for the executable. Results describe synthetic fixtures in this session, not general performance qualification. No performance optimizations were applied during this measurement.

### Native physical footprint

One fresh bundled-app session, sampled using `/usr/bin/sample PID 1 -file OUTPUT` for the app, WebContent, GPU, and Networking processes. Helper identities were established by comparing process inventories before and after app launch; the preceding app's helpers disappeared on quit. Values below use the sampler's binary M/K units, expressed as MiB. Sums are approximate per-process accounting, not a measurement of whole-machine incremental RAM. RSS is a different metric: the idle RSS sum was about 193 MiB versus 92 MiB physical footprint.

Each larger document was opened in sequence; earlier documents remained open. The four source files totaled about 5.26 MiB. They contain numbered headings, paragraphs, bold/emphasis, code spans, and local links; no images or remote content. Each measurement followed successful native rendering.

| Session stage | App/Go/AppKit | WebContent | GPU + network | Approx. total MiB |
| --- | ---: | ---: | ---: | ---: |
| Fresh welcome screen | 31.1 | 39.8 | 21.5 | 92.4 |
| 8 KiB document | 39.7 | 48.7 | 25.3 | 113.7 |
| 256 KiB document | 44.9 | 72.2 | 25.3 | 142.4 |
| 1 MiB document | 79.1 | 144.2 | 25.2 | 248.5 |
| 4 MiB document | 196.7 | 401.3 | 25.2 | 623.2 |
| Back to 256 KiB; 40 separate one-character edits | 146.1 | 65.6 | 26.0 | 237.7 |
| All documents closed, initial sample | 136.6 | 72.9 | 25.9 | 235.4 |
| 107 seconds later, still no open documents | 122.0 | 66.1 | 25.9 | 214.0 |

All 40 characters were verified on disk. Undo and redo were exercised under load. The WebContent process reported a lifetime peak footprint of 434 MiB. The app later reported a 302.2 MiB lifetime peak after document switching/closing; these per-process peaks are not simultaneous and should not be summed as a peak total. Returning to the welcome screen did not immediately return the process footprint to the cold baseline; a sample 107 seconds later declined to about 214 MiB. That alone does not establish a leak.

### Go dispatcher throughput and allocations

Medians of three benchmark runs with a 200 ms benchmark target. The measured operation includes the real dispatcher, filesystem operations where applicable, rendering, and JSON response encoding. It excludes JavaScript, bridge copies, DOM layout, WebKit, and native event latency. Edit means a distinct complete source revision, atomic save, render, and response encoding; allocations are cumulative bytes allocated per operation, not retained memory. Fixture creation and `App.New` are outside the Open timer.

| Source size | Open ms | Edit/save ms | No-match search ms | Edit allocation MiB/op |
| --- | ---: | ---: | ---: | ---: |
| 8 KiB | 7.71 | 6.82 | 0.13 | 0.45 |
| 256 KiB | 17.47 | 17.01 | 3.54 | 16.42 |
| 1 MiB | 51.36 | 51.45 | 13.97 | 66.89 |
| 4 MiB | 184.84 | 194.31 | 56.05 | 256.10 |

Unchanged refresh took about 0.003 ms and allocated about 1.1 KiB per command across these sizes. Warm filesystem/cache measurements; no cold-cache, image-heavy, folder-search, or 16 MiB-limit qualification.

A separate 5,000-identical-heading fixture took a median **1.08 seconds** and allocated **588 MiB** per open/render. The pinned Goldmark ID generator retries suffixes starting at 1 for every duplicate heading (`parser/parser.go`, `ids.Generate`), explaining quadratic collision work. This is a distinct worst case, not the representative fixture above.

### Go retained heap and undo history

An opt-in dispatcher/disk workload measured `runtime.MemStats` after an explicit GC, with separate heap profiles. These numbers exclude all native/WebKit memory and are not process RSS. One-GC snapshots may still include JSON pools.

- Empty core: approximately 0.8 MiB live heap.
- 256 KiB document after 160 edits: approximately 39.5 MiB live heap in the profiled run.
- Same document after 320 edits: approximately 47.7 MiB live heap. The sampled heap profile attributed about 41.6 MiB to revision strings created for those edits.
- Closing that document: approximately 0.85 MiB live heap.
- Ten open 1 MiB documents: approximately 24.7 MiB live heap.
- All ten closed: approximately 4.7 MiB live heap after one GC, including remaining runtime/encoding allocations.

The documented 32 MiB undo budget bounds the visible history slice's string lengths, not total retained memory. `Document.Edit` removes old entries by slicing without clearing discarded string references; the backing array can retain obsolete snapshots until it is replaced. The measured revision-string retention above the logical budget is consistent with that source-level issue. This was identified, not remediated, during performance testing.

Priority optimization candidates: clear discarded history references, avoid full rendering/DOM replacement for every input while editing, and remove quadratic duplicate-heading ID generation while preserving stable anchors. Each needs its own behavioral/performance proof.

Reproduction:

```sh
GOCACHE=/private/tmp/markdown-reader-go-cache go test ./internal/app -run '^$' \
  -bench 'BenchmarkDispatcher|BenchmarkRepeatedHeadingsStress' -benchmem -benchtime=200ms -count=3
mkdir -p /private/tmp/markdown-performance
MARKDOWN_READER_PERF=1 MARKDOWN_READER_PROFILE_DIR=/private/tmp/markdown-performance \
  GOCACHE=/private/tmp/markdown-reader-go-cache go test ./internal/app \
  -run '^TestPerformanceMemory$' -v -count=1
go tool pprof -top -inuse_space /private/tmp/markdown-performance/256KiB_320_edits.pprof
```

Raw benchmark output, memory logs, heap profiles, and native sampler reports from this session are under `/private/tmp/markdown-performance`; those temporary artifacts are not a durable repository dependency.

## Five-build comparison

The subsequent [comparison report](comparison/README.md) covers runnable WebKit, AppKit/TextKit, Fyne, Qt Widgets, and Gio bundles, native physical-footprint measurements, implementation differences, and native edit/undo checks. Its fixtures and measurement sequence differ from the earlier WebKit profiling above; use the report's five-build table for comparisons between shells. Machine-readable measurements and executable hashes are under `comparison/results`.
