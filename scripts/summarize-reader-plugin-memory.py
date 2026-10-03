#!/usr/bin/env python3
"""Write portable evidence for the plugin-enabled native reader measurement."""
import csv
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/reader-mermaid-memory")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


samples = []
for stage, name in [("idle", "final-idle.txt"), ("two_diagrams", "final-diagrams-settled.txt"), ("closed", "final-closed.txt")]:
    path = source / name
    text = path.read_text()
    amount, unit = re.search(r"^Physical footprint:\s+([\d.]+)([KMG])", text, re.M).groups()
    samples.append(dict(stage=stage, process_count=1, footprint_mib=round(float(amount)*{"K":1/1024,"M":1,"G":1024}[unit],3),
                        timestamp=re.search(r"^Date/Time:\s+(.+)$",text,re.M)[1], source_file=name, source_sha256=digest(path)))
trace = source / "final-diagrams.csv"
with trace.open() as f:
    observations = list(csv.DictReader(f))
peak = max(observations, key=lambda r: int(r["total_bytes"]))
assert any("com.apple.WebKit.WebContent" in r["helper_names"] for r in observations), "WebKit helpers not captured"
assert all(not r["helper_pids"] for r in observations[-20:]), "Helpers remained at capture end"
bundle = root / "dist/Markdown Reader.app"
artifacts = {}
for relative in ["Contents/MacOS/reader", "Contents/Resources/markdown-reader", "Contents/Resources/Plugins/mermaid/render", "Contents/Resources/Plugins/mermaid/mermaid.js", "Contents/Resources/Plugins/mermaid/plugin.json"]:
    p = bundle / relative
    artifacts[relative] = dict(bytes=p.stat().st_size, sha256=digest(p))
fixture = root / "viewer-only/plugins/mermaid/example.md"
report = dict(
    metric="Current physical footprint, MiB, not RSS; sample for settled states, proc_pid_rusage v2 for transient observations",
    protocol="Fresh actual app bundle, 1080x780 content window; load example.md containing a flowchart and sequence diagram; native content verified; at least five seconds before settled sample; then resize and close.",
    samples=samples,
    transient=dict(observed_peak_mib=round(int(peak["total_bytes"])/2**20,3),
                   reader_mib_at_peak=round(int(peak["reader_bytes"])/2**20,3),
                   helpers_mib_at_peak=round(int(peak["helpers_bytes"])/2**20,3),
                   peak_epoch_seconds=float(peak["epoch_seconds"]),
                   peak_helper_names=peak["helper_names"], observations=len(observations),
                   target_interval_ms=20, final_helpers=0,
                   helper_processes=sorted({part for row in observations for part in row["helper_names"].split(";") if part}),
                   source_file=trace.name, source_sha256=digest(trace),
                   context_sha256=digest(Path(str(trace)+".context.json"))),
    attribution="Recursive reader descendants plus WebKit XPC processes absent at capture start. Real-plugin CLI tests finished before this capture; no other WebKit apps launched during it. Preexisting WebKit helpers excluded.",
    artifacts=artifacts, fixture=dict(path=str(fixture.relative_to(root)),bytes=fixture.stat().st_size,sha256=digest(fixture)),
    versions=json.loads((root/"viewer-only/plugins/mermaid/package.json").read_text())["dependencies"],
    limitations=["Single exploratory sequence; sampled transient peaks can miss shorter spikes.",
                 "Shared WindowServer/system services are not attributed.",
                 "Native PDF/font/allocator caches remain after diagrams close.",
                 "No forced garbage collection or memory-pressure intervention.",
                 "Only the included two-diagram workload; not a bound for arbitrary Mermaid documents."])
destination = root / "viewer-only/results/plugins.json"
destination.write_text(json.dumps(report,indent=2)+"\n")
for sample in samples:
    print(sample["stage"],sample["footprint_mib"],"MiB")
print("Observed combined rendering peak",report["transient"]["observed_peak_mib"],"MiB")
