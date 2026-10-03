#!/usr/bin/env python3
"""Exercise the shipped plugin executable and the reader's presentation stream.

Requires a built native macOS bundle and access to WebKit services. These checks
do not substitute for inspecting diagrams and export in the native reader.
"""
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / "dist/Markdown Reader.app/Contents/Resources"
plugin = resources / "Plugins/mermaid/render"


def invoke(source):
    return subprocess.run([str(plugin)], input=json.dumps(dict(protocol=1, language="mermaid", source=source, width=900)).encode(), capture_output=True, timeout=15)


def vector(result, labels):
    assert result["protocol"] == 1
    svg = ET.fromstring(result["svg"])
    assert svg.tag == "{http://www.w3.org/2000/svg}svg"
    text = " ".join(svg.itertext())
    for label in labels:
        assert label in text, f"Missing diagram label: {label}"
    assert result["width"] > 0 and result["height"] > 0
    pdf = base64.b64decode(result["pdf"], validate=True)
    assert pdf.startswith(b"%PDF-") and b"%%EOF" in pdf
    for el in svg.iter():
        assert el.tag.rsplit("}", 1)[-1] not in {"script", "foreignObject", "image", "iframe", "a"}
        assert not any(k.lower().startswith("on") or k.endswith("href") for k in el.attrib)


flow = "flowchart LR\n Start[Start] --> Decision{Ready?}\n Decision -->|Yes| Finish[Finish]\n Decision -->|No| Start"
sequence = "sequenceDiagram\n participant Alice\n participant Bob\n Alice->>Bob: Hello\n Bob-->>Alice: Ready"
for name, source, labels in [("flowchart", flow, ["Start", "Ready?", "Finish", "Yes", "No"]),
                             ("sequence", sequence, ["Alice", "Bob", "Hello", "Ready"])]:
    run = invoke(source)
    assert run.returncode == 0, run.stderr.decode(errors="replace")
    vector(json.loads(run.stdout), labels)
    print(f"PASS actual Mermaid {name}: SVG labels and vector PDF")

for source in ["not valid Mermaid", '%%{init: {"securityLevel":"loose"}}%%\nflowchart LR; A-->B',
               "---\nconfig:\n  securityLevel: loose\n---\nflowchart LR; A-->B"]:
    run = invoke(source)
    assert run.returncode != 0 and not run.stdout, "Invalid/configurable diagram was accepted"
print("PASS invalid syntax and diagram configuration rejected")

with tempfile.TemporaryDirectory(prefix="reader-plugin-test-") as directory:
    path = Path(directory) / "document.md"
    source = f"Before diagram\n\n```mermaid\n{flow}\n```\n\nAfter diagram\n\n```mermaid\nnot valid Mermaid\n```\n\nStill readable\n"
    path.write_text(source)
    run = subprocess.run([str(resources/"markdown-reader"), "--plugins", str(resources/"Plugins"), str(path)], capture_output=True, timeout=35)
    assert run.returncode == 0, run.stderr.decode(errors="replace")
    data = run.stdout
    assert data.startswith(b"MVRO1\n")
    offset, diagrams, visible = 6, 0, []
    while offset < len(data):
        flags, length, meta = struct.unpack_from("<III", data, offset)
        offset += 12
        body, extra = data[offset:offset+length], data[offset+length:offset+length+meta]
        assert len(body) == length and len(extra) == meta
        offset += length + meta
        if flags == 1 << 30:
            diagrams += 1
            assert body.startswith(b"%PDF-") and b"%%EOF" in body
            text = " ".join(ET.fromstring(extra).itertext())
            assert "Start" in text and "Finish" in text
        else:
            visible.append(body.decode())
    assert diagrams == 1
    text = "".join(visible)
    for expected in ["Before diagram", "After diagram", "Plugin mermaid:", "not valid Mermaid", "Still readable"]:
        assert expected in text, expected
    assert path.read_text() == source
print("PASS reader command: vector record, syntax fallback, surrounding text, unchanged input")
