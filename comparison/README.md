# Five runnable Markdown Viewer builds

These are local macOS comparison builds. They reuse the existing Go document state, Markdown renderer, atomic persistence, conflict protection, undo/redo, and search engine. The four alternative shells are comparison prototypes, not feature-complete replacements for the WebKit product.

## Open the applications

All five signed application bundles are in [`../dist/comparison`](../dist/comparison):

- [WebKit baseline](../dist/comparison/Markdown%20Viewer%20WebKit.app)
- [AppKit / TextKit](../dist/comparison/Markdown%20Viewer%20AppKit.app)
- [Fyne](../dist/comparison/Markdown%20Viewer%20Fyne.app)
- [Qt Widgets](../dist/comparison/Markdown%20Viewer%20Qt.app)
- [Gio](../dist/comparison/Markdown%20Viewer%20Gio.app)

Open `fixtures/features.md` in each app to compare typography, emphasis, lists, quotations, tables, code, task markers, and links. The alternatives also accept a file or folder path in the toolbar. Editing saves immediately; use copies when comparing editors. Settings are separate for each variant under the user's Application Support / Markdown Viewer Comparisons directory. The existing application remains separate.

## Measured memory

Native physical footprint, **MiB**, on an Apple M2 Ultra, macOS 26.7.1. Each row is a fresh application process followed by sequential preview opens; previously opened documents remain in Go's open-document cache. These are single-run observations, not statistically qualified framework rankings.

| Build | Idle | 8 KiB document | 256 KiB document | 1 MiB document | 4 MiB document |
|---|---:|---:|---:|---:|---:|
| WebKit | 78.2 | 113.7 | 180.6 | 378.2 | 918.3 |
| AppKit / TextKit | **34.1** | **52.4** | **86.5** | 208.8 | 497.5 |
| Fyne | 170.3 | 184.7 | 201.5 | 269.1 | **429.2** |
| Qt Widgets | 40.7 | 86.4 | 146.7 | 350.5 | ~1,126 |
| Gio | 103.0 | 117.9 | 138.8 | **186.9** | 460.5 |

AppKit is the strongest candidate for a small macOS application: its idle footprint is about 56% below this WebKit baseline, and its 256 KiB footprint is about 52% below. Gio and Fyne become competitive for large previews after avoiding layout of an invisible editor. Fyne has a substantially higher fixed cost. Qt starts small, but its rich-text document layout scales poorly on the largest fixture in this implementation.

The 4 MiB Fyne/Gio results do **not** imply that their editors use the same memory. Their source editors are populated only when Edit is selected; large-document source editing remains expensive, particularly in Fyne. AppKit and Qt currently populate their hidden source editors on open, and WebKit follows the existing product behavior. These are real implementation differences, not a controlled comparison of identical toolkit internals.

### Method and limits

- Exact ASCII workloads: 8,192; 262,144; 1,048,576; and 4,194,304 bytes. Unique section headings, styled paragraphs and lists. No images, network loads, edits, or search during measurement. Hashes: [`fixtures/manifest.json`](fixtures/manifest.json). Generate again with `python3 scripts/generate-comparison-fixtures.py` from the repository root.
- All applications launched as actual `.app` bundles and operated through their visible UI. Rendered content was checked before accepting measurements. Requested window content size: 1080×780 points; Fyne's toolbar minimum expands width to approximately 1123 points. Native fonts, controls, viewport sizes and layout strategies differ.
- A minimum five-second wait after UI observation, then `/usr/bin/sample PID 1 -file ...`. Longer waits occurred where layout or UI observation required them. No forced garbage collection or memory-pressure intervention. The later Fyne/Gio runs were sampled together after both previews were loaded; Fyne therefore had several additional seconds to settle.
- WebKit totals include the application and its newly launched WebContent, GPU, and Networking helpers. The four alternatives have one process each. Samples of the four WebKit processes were taken concurrently. **Current physical footprints are summed; historical process peaks are not.** RSS is not the metric in the table.
- `sample` rounds large values: Qt's largest footprint was reported as `1.1G`, so the converted MiB value is approximate. Shared system services such as WindowServer are not attributed to a single build.
- Raw samples remain in `/private/tmp/markdown-comparison-memory/`. Portable evidence is in [`results/memory-processes.json`](results/memory-processes.json), including timestamps, PIDs, displayed measurements and raw-file hashes. [`results/memory.csv`](results/memory.csv) contains totals; [`results/builds.json`](results/builds.json) records executable hashes. Regenerate the summaries with `python3 scripts/summarize-comparison-memory.py [sample-directory]`.
- Initial duplicate-heading fixtures exposed the existing shared parser's costly heading-ID collision handling. Those results were discarded, and all final rows use the same unique-heading fixtures. Earlier Fyne/Gio measurements from superseded builds were also excluded. Discarded samples are retained in named subdirectories for diagnosis.

## What differs between the builds

| Area | AppKit | Fyne | Qt Widgets | Gio |
|---|---|---|---|---|
| Preview | Attributed text in NSTextView; native text tables | Virtualized list of rich-text blocks | QTextBrowser / QTextDocument; no WebEngine | Virtualized rich-text block list |
| Source editor | NSTextView | Fyne multiline Entry, loaded on demand | QPlainTextEdit | Gio Editor, loaded on demand |
| Tables | Native cells | Rich-text cells | HTML text tables | Text rows with separators, not a full table grid |
| Embedded raster images | Native attachments | Decoded image spans | Data-URI image resource loader | Alt-text placeholders only |
| Strikethrough | Yes | Text retained without strike styling | Yes | Text retained without strike styling |
| Heading links | Anchor map | Not implemented; visible status message | Toolkit HTML anchor behavior; not acceptance-tested | Block navigation |
| Search results | Select matching source range | Opens editor and reports line/column | Select matching source range | Select matching source range |
| Accessibility | Native controls and text | Custom canvas controls; limited AX tree | Native accessible widget controls | Custom canvas controls; limited AX tree |

All alternatives implement open, folder navigation, recent/open documents, preview/edit, autosave, shared undo/redo toolbar actions, save copy, reload confirmation, close document, current/open/folder search, paper/night/sepia themes, and external file refresh. They do not reproduce every WebKit design detail, keyboard shortcut, typography control, sidebar behavior, OS file association, or document creation flow. Use the toolbar Undo/Redo actions for the shared document history; toolkit editor keyboard histories may group input differently.

HTML is sanitized by the same Go core before presentation. The structured adapter is used by AppKit, Fyne and Gio; Qt uses sanitized HTML (the shared adapter also builds blocks in its bridge). Remote images are not loaded. The AppKit build uses TextKit through NSTextView and includes native text tables; it is not presented as a pure TextKit 2 implementation.

## Verification performed

- Root `go test ./...`, `go vet ./...`, and `./scripts/build.sh`: passed.
- Comparison `go test ./...` and `go vet ./...`: passed. Tests exercise meaningful shared adapter seams: formatting/safe content and preservation of an unsaved draft after an external-write conflict blocks navigation. Native packages compile but do not contain automated UI tests.
- `scripts/build-comparisons.sh`: built all five bundles; each launched through macOS.
- Native preview: formatting fixture inspected in all four alternatives; final previews at all four workload sizes were loaded. Fyne's final block-list preview and both on-demand-editor changes were verified at 4 MiB after correcting the initial defects.
- Native editing: in separate temporary files, all four alternative editors changed file bytes to `# Changed` via autosave. Clicking their Undo toolbar action changed the actual file bytes to a prior state. This is native persistence evidence, not merely a Go-unit-test claim.
- Native search: a literal query returned the expected single match in all four alternative shells. This check does not qualify every result-navigation interaction.
- Full native feature parity, all image/anchor/search interactions, accessibility conformance, long editing sessions, external-provider behavior, and cross-platform builds are **not qualified** by these checks. Preview measurements do not qualify large-document edit performance.

## Build again

Requires Go with cgo, Xcode command-line tools, Python 3, and a Qt 6 macOS installation with `bin/macdeployqt`:

```sh
QT_ROOT=/path/to/Qt/6.12.0/macos ./scripts/build-comparisons.sh
```

Pinned comparison dependencies: Fyne 2.8.1, Gio 0.10.3, Gio x 0.10.3; the Qt build used 6.12.0. Built here with Go 1.27.1 for macOS arm64. The nested `comparison/go.mod` keeps these toolkits out of the original product module and pins the effective Goldmark renderer to the original 1.7.13 version.

The local Qt installation used for this run is `/private/tmp/markdown-viewer-deps/qt`. Downloaded Go dependencies and the offline proxy are under `/private/tmp/markdown-viewer-deps`; those temporary caches are not required to run the bundles. Qt frameworks and platform plugins are deployed inside its application. The other alternatives use their compiled Go/native dependencies. The build script applies ad-hoc signatures for local execution; these are not notarized distribution releases.
