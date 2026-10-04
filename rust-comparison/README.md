# Five Rust UI comparison builds

This round runs a **fully Rust application and document core**, independent of Go,
through five UI frameworks. Branch: `comparison/rust-ui-frameworks`. The original
Go product and the [previous five Go-backed builds](../comparison/README.md) remain
available as baselines. These are runnable comparison prototypes, not replacements
with complete product parity.

## Run

Build from the repository root on macOS with Rust, Xcode command-line tools and
CMake (FLTK builds its C++ toolkit from the pinned crate sources):

```sh
./scripts/build-rust-comparisons.sh
open "dist/rust-comparison/Markdown Reader Rust egui.app"
open "dist/rust-comparison/Markdown Reader Rust iced.app"
open "dist/rust-comparison/Markdown Reader Rust slint.app"
open "dist/rust-comparison/Markdown Reader Rust fltk.app"
open "dist/rust-comparison/Markdown Reader Rust wry.app"
```

Each bundle is ad-hoc signed for local use. Nothing is installed or changes file
associations. `Cargo.lock` pins dependencies. Each bundle is built with only its
own UI feature enabled, thin LTO and stripped symbols. Wry uses the system WebKit;
FLTK wraps a C++ toolkit. Neither uses a Go core or a Go runtime.

Paste an absolute filename into the first field and choose **Open**. Use copies
of the same fixtures in `comparison/fixtures/`: `features.md`, `small.md`,
`medium.md`, `large.md`, and `very-large.md`. **Edit** shows the source editor; edits autosave. Wry populates its hidden
textarea when opening a file; the other four populate the editor on demand. The first field is also the **Save Copy** destination:
enter a new filename, then choose Save Copy. Existing destinations are rejected.
Toolbar Undo/Redo use the shared Rust history. Search reports matching line
numbers for a case-sensitive literal query in the current document. Reload is
allowed for a clean document; conflicting drafts must first be preserved with
Save Copy. A path can also be supplied as the executable's first argument, or
with `open -n "...app" --args /absolute/path.md` on a fresh instance.

## What is being compared

| Build | Rendering path | Source editing | Observed preview differences |
|---|---|---|---|
| Rust egui 0.36.2 | Immediate-mode egui, OpenGL | egui multiline TextEdit | Headings, italics, monospace, strike; bold is only a spacing approximation in this adapter |
| Rust Iced 0.14.0 | Declarative widgets, tiny-skia software renderer | Iced text editor | Styled spans including bold, italic, monospace and strike |
| Rust Slint 1.18.1 | Declarative Slint, winit/software renderer | Slint TextEdit | Headings and code blocks; inline styles are flattened; unchecked task glyph missing in observed font |
| Rust FLTK 1.5.23 | FLTK HelpView HTML layout, no WebKit | FLTK TextEditor | Headings, bold, italic, code; strike styling is omitted by HelpView |
| Rust Wry 0.55.1 | Wry/Tao, system WebKit, local HTML/JS | HTML textarea | HTML heading and inline formatting; accessible document/control tree |
| Go baseline | AppKit/WebKit, Go/Goldmark | Existing HTML editor | More complete Markdown presentation and product features |

All Rust shells use `Session::dispatch`, `Document`, and the same pulldown-cmark
0.13.4 presentation model. The core generates safe HTML from escaped text and
known tags for FLTK/Wry. Raw HTML and all link/image destinations are omitted;
images retain alt text only. Wry additionally blocks network content with CSP and
rejects navigation. This deliberately smaller presentation contract is **not**
Goldmark parity: table cells are text rows with separators, links are inert,
ordered/nested lists lose numbering/indentation, and quotations lack distinct
styling. Compare content preservation and layout separately from toolkit cost.

Rust owns regular-file/UTF-8/16 MiB validation, canonical paths, atomic sibling-file
replacement, permission preservation, external-content conflict detection,
revision rejection, bounded snapshot undo/redo, exclusive save-copy creation,
rendering, and search. Save failure retains the draft and blocks navigation.
Window-close handlers attempt saving and retain a conflicting draft in its window.
As with Go, the final disk check and rename are optimistic, not an OS atomic
compare-and-swap against another writer. ACLs/extended attributes are not preserved.

The Rust prototypes currently have one open document, no persisted preferences or
recents, no folder navigation, no automatic external refresh, no image loading,
no link navigation, and no search-result selection/highlighting. Use toolbar history
actions; editor shortcut behavior differs. In native smoke testing, Command-A did
not select all in Slint or Wry, while it worked in Iced, egui and FLTK. Full macOS
Edit menus and shortcut parity remain unfinished. The prototypes do not implement
crash recovery for unsaved drafts.

## Built artifact comparison

Signed executable sizes on macOS arm64, this round:

| Build | Executable MiB |
|---|---:|
| Rust egui | 6.50 |
| Rust Iced | 4.35 |
| Rust Slint | 12.59 |
| Rust FLTK | 1.38 |
| Rust Wry | 1.59 |
| Go WebKit | 5.81 |

Exact byte counts, executable SHA-256 hashes, platform and timestamp are in
[`results/builds.json`](results/builds.json). Recreate with
`python3 scripts/summarize-rust-builds.py` from the repository root. These are
**disk sizes**, not RSS or physical footprint; system libraries/WebKit and helper
processes are excluded. The smaller feature set also prevents attributing the
size difference solely to Rust versus Go.

## Native memory comparison

The original Go preview protocol was repeated for all five Rust bundles on the
same Apple M2 Ultra / macOS 26.7.1, with 1080 × 780 point content windows. Values
below are **current physical footprint in MiB**, not RSS or peak memory. Go rows
are the previously recorded run; they were not remeasured during the Rust run.

| Build | Idle | 8 KiB | 256 KiB | 1 MiB | 4 MiB |
|---|---:|---:|---:|---:|---:|
| Rust egui | 107.6 | 128.9 | 133.2 | 235.5 | 559.8 |
| Rust iced | 74.5 | 90.4 | 204.1 | 542.0 | 1945.6 |
| Rust slint | 72.7 | 77.8 | 138.3 | 293.9 | 964.4 |
| Rust fltk | 58.5 | 50.9 | 58.4 | 128.9 | 325.1 |
| Rust wry | 69.5 | 99.7 | 145.2 | 326.5 | 981.2 |
| Go (prior) WebKit | 78.2 | 113.7 | 180.6 | 378.2 | 918.3 |
| Go (prior) AppKit | 34.1 | 52.4 | 86.5 | 208.8 | 497.5 |
| Go (prior) Fyne | 170.3 | 184.7 | 201.5 | 269.1 | 429.2 |
| Go (prior) Qt | 40.7 | 86.4 | 146.7 | 350.5 | ~1126 |
| Go (prior) Gio | 103.0 | 117.9 | 138.8 | 186.9 | 460.5 |

FLTK had the lowest measured Rust footprint for every loaded document size,
including 325.1 MiB at 4 MiB. Iced reached approximately 1.9 GiB (the source sample
reports `1.9G`, converted to 1945.6 MiB; precision is limited by that display).
The Go Qt 4 MiB source similarly reports only `1.1G`. These observations describe
these adapters and do not establish that Rust or any framework is inherently
more memory efficient.

Each variant started in a fresh process, was sampled idle, then opened the exact
SHA-256-verified existing fixtures in ascending order in the same process. Each
preview's filename and rendered content were checked in the native app. Samples
were taken after at least five seconds of settling following visible verification.
No editing or searching occurred before the last memory sample. All five Rust
apps remained running; sampling was concurrent across their eight processes.
No forced garbage collection or memory-pressure intervention was applied.

Wry totals include its host plus the newly spawned WebContent, GPU and Networking
helpers; preexisting helpers belonging to other apps were excluded. The other
four Rust rows each contain one app process. There was one trial, with manual UI
verification and variable additional settling time, matching the exploratory
nature of the prior Go comparison. This is not a controlled latency benchmark.

**Comparability limits:** Rust retains only the current document, whereas the Go
core caches documents opened earlier in the sequence. Wry populates its hidden
textarea on open; the other Rust editors are populated on entering Edit. The Go
adapters also differ in hidden-editor population. Fonts, layout, rendering fidelity
and features differ as described above and in the Go report. Lower memory can
therefore accompany less functionality. Startup time, frame time, large-document
editing latency and repeated-trial variance have not been measured.

Evidence: [totals](results/memory.csv), [per-process samples and hashes](results/memory-processes.json),
and [run context, fixture and binary hashes](results/memory-context.json).
Raw local sample files remain in `/private/tmp/markdown-rust-memory`; they are
not tracked because OS diagnostics contain machine-specific paths. Recompute:

```sh
python3 scripts/summarize-rust-memory.py /private/tmp/markdown-rust-memory
```

## Verification

Commands run in this round:

```sh
cargo test --locked --manifest-path rust-comparison/Cargo.toml --all-features --all-targets
cargo clippy --locked --manifest-path rust-comparison/Cargo.toml --all-features --all-targets -- -D warnings
cargo fmt --manifest-path rust-comparison/Cargo.toml --check
./scripts/build-rust-comparisons.sh
go test ./...
go vet ./...
./scripts/build.sh
```

Three shared-dispatcher workflow tests cover persisted edits/undo and stale-command
rejection; external-write conflicts, retained drafts, blocked navigation and
non-clobbering save-copy; and semantic preview content without raw HTML or remote
image destinations. They were observed failing against the missing-behavior stub,
then passing against the implementation. They assert actual temporary-file bytes
and independent preview expectations. Tests do not qualify native rendering.

All five actual bundles launched through macOS. The same formatting fixture was
inspected in each. Native keyboard input changed temporary file bytes, and each
shell's toolbar Undo changed the persisted bytes to a previous edit state. Undo
steps differ with the toolkit's input event grouping; this was not an assertion
that one click returns an entire typing session to its starting state. FLTK was
operated by Tab/Space when pointer actions did not activate its controls reliably
through the automation tool.

After memory sampling, all five native apps searched `features.md` for the literal
`Search needle` and displayed exactly matching line 33, independently checked
against the fixture bytes. All four workload previews rendered in every app.

The final Wry bundle additionally passed a native conflict recovery check: an
external write remained `External`, the editor retained `Original draft`, closing
the window was blocked, and Save Copy created a separate file containing
`Original draft`. This directly verifies that Wry close/recovery route; it does
not qualify every framework or OS quit route.

Native full feature parity, accessibility conformance, exhaustive shortcuts,
all close/quit routes, large-file interaction, and extended editing sessions are
not qualified. The build and lint gates are separate from those open checks.

Framework API references: [eframe](https://docs.rs/eframe/0.36.2/eframe/),
[Iced](https://docs.rs/iced/0.14.0/iced/), [Slint](https://docs.rs/slint/1.18.1/slint/),
[FLTK](https://docs.rs/fltk/1.5.23/fltk/), and
[Wry](https://docs.rs/wry/0.55.1/wry/).
