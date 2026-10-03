# Reader plugins and Mermaid

Markdown Reader supports optional, local **fenced-code renderer plugins**. The
bundled Mermaid plugin turns `mermaid` fences into diagrams. Open
[the example document](mermaid/example.md) in `dist/Markdown Reader.app`.

Mermaid emits **SVG**, which the reader preserves for export. A vector PDF of the
same SVG is displayed through AppKit/TextKit 2. It is not a PNG screenshot.
Diagrams scale to the available text width. **File → Export Diagram as SVG…**
(Shift-Command-S) exports the first diagram in the text selection, or the first
diagram in the document when no text is selected. The save panel controls the
destination and overwrite confirmation.

**Plugins → Enable Plugins** turns rendering on/off for the current session and
reloads the current document. With plugins disabled, diagram fences remain code.
Syntax errors, renderer failures, timeouts, or limits produce a visible message
followed by the original source. Surrounding Markdown remains readable.

## Runtime and memory

The reader process does not link WebKit, Node, or a Go runtime. On open, the
short-lived Go parser loads manifests from the bundle's `Resources/Plugins`.
Only a matching fence starts a plugin. The Mermaid executable starts an
offscreen, nonpersistent WebKit view, renders SVG/PDF, writes its result, and
exits. Only native diagram presentation remains. There is no renderer daemon,
cross-document diagram cache, network rendering service, or CDN access.

Node/npm are **build dependencies only**. Mermaid 12.1.0 and esbuild 0.28.2 are
pinned by `mermaid/package-lock.json`; the browser bundle and third-party license
notices are packaged into the app. The helper uses the system WebKit runtime.

The final native measurements and artifact hashes are in
[the plugin memory results](../results/plugins.json). These are exploratory
observations with the example's two diagrams, not universal memory limits. The
earlier [viewer-only baseline](../README.md) predates plugins. Diagram rendering
has temporary browser costs; native PDF/font/allocator caches can remain after
closing a document even though the renderer processes exit.

| Stage | Physical footprint |
| --- | ---: |
| Fresh idle reader | 25.1 MiB |
| Two diagrams, rendering finished | 73.0 MiB |
| After closing the document | 63.1 MiB |
| Sampled peak, including temporary renderers and WebKit helpers | 233.5 MiB |

These figures come from one native run. All rendering helpers exited afterward.

## Build and verify

```sh
# Optional explicit clean dependency restore before building:
npm ci --ignore-scripts --no-audit --no-fund --prefix viewer-only/plugins/mermaid
./scripts/build-viewer-only.sh
go test ./...
go vet ./...
./scripts/build.sh
python3 scripts/test-reader-plugins.py
```

The first plugin build installs locked dependencies if absent. Subsequent builds
bundle locally installed dependencies; use `npm ci` after changing the lockfile.
Actual plugin integration tests require macOS WebKit services and cannot run in
a shell sandbox that denies those services. The Go tests use real child processes
to exercise the plugin protocol without launching WebKit.

Verification includes real Mermaid flowchart/sequence labels and vector outputs,
invalid syntax and configuration rejection, reader-stream embedding, source
fallback and preservation, and child-process failure/timeout/output-size limits.
Native acceptance checks cover both diagrams, narrow-window layout, plugin
disable/re-enable, SVG export, and invalid-diagram presentation. Go tests alone
do not establish native behavior. Not every upstream Mermaid diagram type,
accessibility behavior, or long-session workload has been qualified.

## Plugin package contract, version 1

This is a rendering extension point, not an in-process UI or arbitrary document
mutation API. Each installed plugin occupies one directory:

```text
Plugins/
  mermaid/
    plugin.json
    render
    mermaid.js
    THIRD-PARTY-NOTICES.txt
```

Example manifest:

```json
{
  "schemaVersion": 1,
  "id": "mermaid",
  "name": "Mermaid diagrams",
  "version": "1.0.0",
  "languages": ["mermaid"],
  "executable": "render",
  "timeoutMilliseconds": 10000
}
```

IDs must match their directory and use lowercase letters, digits, and hyphens;
languages use the same syntax. IDs/languages are at most 64 characters. Executables
must be regular executable files in their package, not paths or symlinks outside
it. Duplicate language claims and malformed manifests are rejected. The registry
allows at most 64 entries and 16 languages per plugin. No document directory is
searched for plugins. The app supplies its bundled registry explicitly; the
standalone parser also accepts `markdown-reader --plugins DIRECTORY FILE`.

Installed executables are **trusted application code**, not sandboxed third-party
scripts. To add a renderer, package its manifest, executable, and resources under
`Contents/Resources/Plugins`, then sign the executable and application as part of
the build. No host-code change is required for another fence language. There is
no automatic download or plugin-installation UI.

One invocation receives a UTF-8 JSON request on stdin, followed by EOF:

```json
{"protocol":1,"language":"mermaid","source":"flowchart LR; A-->B\n","width":900}
```

Success exits zero and writes one JSON object to stdout:

```json
{"protocol":1,"svg":"<svg xmlns=\"http://www.w3.org/2000/svg\">...</svg>","pdf":"BASE64_PDF_BYTES","width":900,"height":300}
```

SVG is the exportable vector source; PDF must be a single-page vector preview of
the same diagram. Diagnostics belong on stderr. Failure exits nonzero and must
not claim success. The host caps input at 64 KiB per diagram, stdout at 8 MiB,
stderr at 4 KiB, SVG at 2 MiB, and PDF at 4 MiB. Dimensions must be positive, at
most 4096 each, and total at most four million square points per diagram.
The native decoder additionally validates the PDF page and bounds.

Rendering is sequential, with at most 16 attempts, 30 seconds of rendering time,
16 MiB of combined vector payload, and sixteen million square points per document.
Each plugin gets its declared 50–10,000 ms timeout. Cancellation kills its process
group. These bound the host's work/output; they are not a hard OS memory quota on
trusted plugin executable internals. The Mermaid helper has its own nine-second
deadline and WebKit's lifecycle governs its XPC processes.

The reader's `MVRO1` presentation stream adds record flag `1 << 30`: the body is
raw PDF bytes and the metadata is UTF-8 SVG. Ordinary records remain styled text.
Only these vector records create native attachments; they are not interpreted as
HTML. SVG export writes the retained SVG, not the PDF or a raster conversion.

## Mermaid safety and scope

The pinned [Mermaid renderer API](https://mermaid.js.org/config/usage.html) runs
with [strict security](https://mermaid.js.org/config/schema-docs/config-properties-securitylevel.html),
HTML labels disabled, 500 maximum edges, and no automatic start. Diagram-level
configuration directives/front matter are rejected. A restrictive Content Security
Policy blocks network, image, font, and object loads. SVG output strips active
elements/event handlers and rejects external CSS resources. The embedded result
has no interactive diagram links or HTML labels. Exported diagrams use a light
theme regardless of the reader's system appearance.
