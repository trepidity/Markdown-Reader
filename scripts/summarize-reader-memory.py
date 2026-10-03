#!/usr/bin/env python3
"""Summarize native viewer-only samples and simultaneous loading observations."""
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/markdown-reader-memory")
output = root / "viewer-only/results"
output.mkdir(parents=True, exist_ok=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


records = []
for stage in ["idle", "small", "medium", "large", "very-large", "scrolled", "closed"]:
    path = source / f"reader-{stage}.txt"
    text = path.read_text()
    value, unit = re.search(r"^Physical footprint:\s+([\d.]+)([KMG])", text, re.M).groups()
    mib = float(value) * {"K": 1/1024, "M": 1, "G": 1024}[unit]
    records.append(dict(stage=stage, process_count=1, footprint_mib=round(mib, 3),
                        footprint_display=value+unit,
                        timestamp=re.search(r"^Date/Time:\s+(.+)$", text, re.M)[1],
                        source_file=path.name, source_sha256=digest(path)))
with (output / "memory.csv").open("w") as f:
    writer = csv.DictWriter(f, fieldnames=["stage", "process_count", "footprint_mib"], extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    writer.writerows(records)
(output / "memory-processes.json").write_text(json.dumps(records, indent=2)+"\n")

transients = []
for name in ["reload-4MiB.csv", "reload-4MiB-verified.csv"]:
    path = source / name
    with path.open() as f:
        rows = list(csv.DictReader(f))
    with_helpers = [r for r in rows if r["helper_pids"]]
    if not with_helpers:
        raise SystemExit(f"No helper observed in {name}; cannot claim a combined load peak")
    peak = max(rows, key=lambda r: int(r["total_bytes"]))
    transients.append(dict(workload="reload 4 MiB while previous 4 MiB document remains displayed",
                           observations=len(rows), observations_with_helpers=len(with_helpers),
                           target_interval_ms=20,
                           observed_peak_mib=round(int(peak["total_bytes"])/2**20, 3),
                           reader_mib_at_peak=round(int(peak["reader_bytes"])/2**20, 3),
                           helpers_mib_at_peak=round(int(peak["helpers_bytes"])/2**20, 3),
                           peak_epoch_seconds=float(peak["epoch_seconds"]),
                           source_file=name, source_sha256=digest(path)))
(output / "transient.json").write_text(json.dumps(transients, indent=2)+"\n")

bundle = root / "dist/Markdown Reader.app"
artifacts = []
for relative in ["Contents/MacOS/reader", "Contents/Resources/markdown-reader"]:
    path = bundle / relative
    artifacts.append(dict(path=relative, bytes=path.stat().st_size, sha256=digest(path)))
sources = ["viewer-only/main.m", "cmd/markdown-reader/main.go", "scripts/build-viewer-only.sh"]
context = dict(
    metric="sample current Physical footprint, MiB; not RSS or peak",
    os=subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    machine=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
    window_content_points=[1080, 780],
    settled_protocol="One fresh native bundle; idle, then sequential 8 KiB, 256 KiB, 1 MiB, 4 MiB opens. UI content verified; at least five seconds before sample.",
    active_processes="One reader process at settled samples; parser helpers exit after each load. No WebKit helpers.",
    transient_protocol="proc_pid_rusage v2 current physical footprint for reader plus direct parser children, polled at a target 20 ms; spikes between samples may be missed.",
    no_forced_gc=True, no_memory_pressure_intervention=True,
    fixture_manifest=json.loads((root / "comparison/fixtures/manifest.json").read_text()),
    artifacts=artifacts, sources={p: digest(root / p) for p in sources},
    baseline="comparison/results/memory.csv and rust-comparison/results/memory.csv; historical runs, not remeasured",
    limitations=["Exploratory single settled sequence, two reload observations; not a statistical benchmark.",
                 "Current document only; no editing, undo, source editor, document cache, image decoding, or HTML/DOM.",
                 "Images use alt placeholders; tables use text rows; heading anchors unsupported.",
                 "Fonts, themes, feature sets, and retention differ across builds.",
                 "Other previously launched comparison applications remained running.",
                 "Settled memory may decrease between larger workloads as allocators and macOS reclaim memory.",
                 "Shared services such as WindowServer are not attributed.",
                 "initial-loads.csv excluded: its preliminary sampler incorrectly interpreted child PID counts; corrected and validated before both recorded reload traces."])
(output / "context.json").write_text(json.dumps(context, indent=2)+"\n")
for row in records:
    print(f"{row['stage']}: {row['footprint_mib']} MiB")
for row in transients:
    print(f"Observed combined reload peak: {row['observed_peak_mib']} MiB")
