#!/usr/bin/env python3
"""Record sizes and hashes of the independently built comparison executables."""
import datetime
import hashlib
import json
import platform
from pathlib import Path

root = Path(__file__).resolve().parent.parent
rows = []
for name in ("egui", "iced", "slint", "fltk", "wry"):
    path = root / f"dist/rust-comparison/Markdown Viewer Rust {name}.app/Contents/MacOS/viewer-{name}"
    data = path.read_bytes()
    rows.append(dict(build=f"Rust {name}", bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
go = root / "dist/Markdown Viewer.app/Contents/MacOS/markdown-viewer"
if go.exists():
    data = go.read_bytes()
    rows.append(dict(build="Go WebKit", bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
result = dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              platform=platform.platform(), metric="signed executable bytes; excludes system frameworks and runtime memory",
              builds=rows)
output = root / "rust-comparison/results/builds.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, indent=2) + "\n")
for row in rows:
    print(f"{row['build']}: {row['bytes'] / 2**20:.2f} MiB")
