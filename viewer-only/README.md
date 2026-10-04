# Markdown Reader — viewer-only memory experiment

The measurements below record the original viewer-only baseline at commit
`d889153`, before plugins. The current build also includes the optional
[Mermaid plugin system](plugins/README.md), with SVG export, native vector display,
and separately recorded plugin memory measurements.

Separate runnable macOS application focused on low resident RAM:
[Markdown Reader.app](../dist/Markdown%20Reader.app).
It does not replace the existing Markdown Reader Editor app or change default file associations.

```sh
./scripts/build-viewer-only.sh
open 'dist/Markdown Reader.app'
```

Requires macOS 13 or newer. The bundle is locally ad-hoc signed, not notarized.
Use **Open…**, the path field, or Finder's Open With. Command-O opens a file,
Command-R reloads, Command-F finds text, and Command-W releases the document.
Text is selectable and copyable but cannot be edited. Only one document is retained.

## Readability pass and memory changes (October 3, 2026)

The reader now uses a typographic reading style: New York serif body, SF sans
headings, a centered ~700 pt measure, code bands, quote bars, hanging list
indents, rules and aligned monospaced tables, all drawn with TextKit 2 layout
fragments (no TextKit 1 fallback, no NSTextTable). The helper/reader flag
contract is documented in `cmd/markdown-reader/main.go`.

Memory changes: the helper reads the file into an exactly sized buffer and
parses it in chunks split only before column-0 headings outside fences and HTML
blocks (disabled when link reference definitions exist; output is byte-identical
to an unchunked parse). The reader streams the pipe into a new text storage with
no whole-stream buffer and no per-run attributed strings, installs it without a
copy, and calls `malloc_zone_pressure_relief` after load and close.

Tradeoff: once the helper's stream has started, the previous document is released
before the new one is built. If the helper dies mid-stream the view is left empty
with an error (Reload to retry); failures before the stream starts keep the
previous document.

Single-run peak combined footprint (reader + helper), same machine, sampled every
20 ms, real helper: 1 MiB 63.7 → 37.8 MiB; 4 MiB 171.7 → 44.3 MiB; 16 MiB (new
only) 80.8 MiB peak, 65 MB settled. Settled 4 MiB: 47 → 38 MB. Not repeated trials.

## Measured result

Current native **physical footprint in MiB**, Apple M2 Ultra, macOS 26.7.1.
The new row was measured in the actual bundled app on October 3, 2026; the other
rows are earlier recorded measurements, not rerun in this experiment.

| Build | Idle | 8 KiB | 256 KiB | 1 MiB | 4 MiB |
|---|---:|---:|---:|---:|---:|
| **Viewer-only AppKit / TextKit 2** | **25.4** | **56.4** | **47.3** | **46.9** | **86.5** |
| Go WebKit | 78.2 | 113.7 | 180.6 | 378.2 | 918.3 |
| Go AppKit editor prototype | 34.1 | 52.4 | 86.5 | 208.8 | 497.5 |
| Go Fyne | 170.3 | 184.7 | 201.5 | 269.1 | 429.2 |
| Go Qt | 40.7 | 86.4 | 146.7 | 350.5 | ~1126 |
| Go Gio | 103.0 | 117.9 | 138.8 | 186.9 | 460.5 |
| Rust egui | 107.6 | 128.9 | 133.2 | 235.5 | 559.8 |
| Rust iced | 74.5 | 90.4 | 204.1 | 542.0 | ~1946 |
| Rust slint | 72.7 | 77.8 | 138.3 | 293.9 | 964.4 |
| Rust FLTK | 58.5 | 50.9 | 58.4 | 128.9 | 325.1 |
| Rust Wry | 69.5 | 99.7 | 145.2 | 326.5 | 981.2 |

Against the recorded WebKit run, this is **67.5% less idle RAM** and **90.6% less
settled RAM at 4 MiB**. It is not the lowest observed 8 KiB result: the earlier
FLTK and AppKit prototypes were slightly lower at that point. This is an
architecture-and-feature comparison, not an isolated measurement of removing editing.

Loading has a separate cost. Two 4 MiB reload observations reached **215.0 MiB**
and **214.2 MiB** combined physical footprint for the reader and its temporary Go
parser. These are simultaneous sampled totals, not sums of separate process peaks;
20 ms sampling can miss shorter spikes. The previous document stays visible until
the replacement has successfully parsed and decoded, increasing reload peak memory.

After reloads and a jump to the last section, the reader measured **77.2 MiB**.
After further middle/top navigation and closing the document it measured
**58.7 MiB**, not the original 25.4 MiB idle value. AppKit/system allocator caches
can remain resident after the document is released. No forced GC, malloc purge,
or memory-pressure operation was used. The sequence is not monotonic: memory can
be reclaimed between samples, so these single observations are not exact budgets.

## What changed

- A native AppKit process owns a single read-only `NSTextView`, explicitly created
  with TextKit 2. The UI confirms TextKit 2 remains active after loading and scrolling.
- Go/Goldmark parses the file in a bundled short-lived helper. The helper exits
  after producing a compact binary stream of text, formatting flags, and links.
  The parser AST, Markdown source, and Go runtime are not retained in the reader.
- The native decoder builds attributed text directly. There is no intermediate
  HTML, JSON document model, browser DOM, base64 image payload, or WebKit helper.
- No source editor, editing commands, autosave, undo history, open-document cache,
  or polling timer is created. Formatting dictionaries are reused while decoding.
- Files are only opened for reading. Invalid input or failed loading leaves the
  previous presentation intact. Documents are limited to regular UTF-8 text up
  to 16 MiB without NUL bytes, matching the existing product's size class.

The signed reader executable is 98,992 bytes; its Go helper is 2,628,496 bytes.
These are disk sizes and exclude system frameworks; they are not RAM measurements.

## Presentation scope

This is a memory-focused experimental reader, not a feature-complete replacement.

Supported: headings, bold, italic, inline/fenced code, strikethrough, nested lists,
ordered list numbers, indented quotations, task markers, horizontal rules,
select/copy, native Find, local Markdown links, and explicitly clicked HTTP/HTTPS/
mailto links. It follows the system appearance. Raw HTML is omitted rather than
executed; documents do not automatically load network resources.

Images show **alt-text placeholders**, with no decoding. Tables preserve cell text
as monospaced rows separated by bars, without a native table grid or aligned column
widths. Heading-anchor links display an unsupported message. There is no sidebar,
folder search, recents, multiple-document UI, automatic file refresh, editor, or
custom theme switcher. Only native Find in the current presentation is included.

The memory fixtures contain text, headings, emphasis, inline code, and lists;
**they contain no images or tables**. Image omissions therefore do not explain
the measured reduction on those fixtures, but image-heavy usage is not qualified.

## Protocol and evidence

One fresh bundle, 1080×780-point content window, was sampled idle and then after
sequential opens of the same 8,192-, 262,144-, 1,048,576-, and 4,194,304-byte
fixtures used in the earlier comparisons. Each filename and rendered content was
checked through the native UI; at least five seconds elapsed before each
`sample PID 1 -file ...` measurement. Fixture SHA-256 hashes were verified.

The reader has one process when settled; its parser has exited. All live parser
children are included in the separate transient traces. Other earlier comparison
apps remained running. WindowServer/shared system services are not charged to one
app. Fonts, feature sets, and document-retention policies differ across variants.
There is one settled sequence and two reload observations, not repeated-trial
statistics. These observations do not establish the theoretical minimum RAM.

Portable evidence:

- [Settled measurements](results/memory.csv)
- [Per-sample timestamps and raw-file hashes](results/memory-processes.json)
- [Combined transient observations](results/transient.json)
- [Build/source hashes, machine and measurement context](results/context.json)
- [Earlier Go comparison](../comparison/README.md) and [Rust comparison](../rust-comparison/README.md)

Raw diagnostics are local under `/private/tmp/markdown-reader-memory`; they are
not tracked because native samples can include machine-specific paths. The
preliminary `initial-loads.csv` trace is excluded: its initial child-count handling
was incorrect. The corrected sampler was checked against a known child process
before collecting both reported reload traces.

To reproduce, launch a fresh bundle and obtain its PID, then operate it through
the native UI and record each settled stage:

```sh
sample PID 1 -file /private/tmp/markdown-reader-memory/reader-idle.txt
# Repeat with reader-small.txt, reader-medium.txt, reader-large.txt,
# reader-very-large.txt, reader-scrolled.txt, and reader-closed.txt.
python3 scripts/measure-reader-transient.py PID /private/tmp/markdown-reader-memory/reload-4MiB.csv --seconds 60
# Reload through the native UI while the sampler runs. Repeat with
# reload-4MiB-verified.csv, then summarize:
python3 scripts/summarize-reader-memory.py /private/tmp/markdown-reader-memory
```

## Verification

Passed `go test ./...`, `go vet ./...`, `./scripts/build.sh`, and
`./scripts/build-viewer-only.sh`. The new renderer's content-preservation test was
observed failing against the unimplemented command, then passing. It checks
literal presentation content, formatting flags, link destinations, omission of
raw script content, and unchanged file bytes. Negative checks reject invalid UTF-8,
NUL text, missing files, directories, and invalid command arguments.

Native checks performed in the real bundle:

- All four workload sizes visibly rendered with TextKit 2 active.
- Formatting fixture inspected for emphasis, code, strike, nested lists, tasks,
  quotation, table text, and links.
- Largest document navigated to end (section 29,824), middle, and top.
- Read-only fixture resisted typing and Delete after Select All; actual source
  bytes were verified unchanged afterward.
- Find selected the expected `unchanged` match.
- Local document link navigated to the intended file.
- Missing-file open reported an error while retaining the previous presentation.
- Reload spawned and reaped the parser; close cleared the presentation and reduced
  physical footprint.

Full accessibility conformance, external-browser/mail launching, all Markdown edge
cases, image rendering, long-session stress, and a distribution release are not
qualified by this experiment. There were intermittent automation errors after
reload actions; process traces and subsequent UI observation confirmed successful
reloads and a still-running reader, with no reader crash report found.
