#!/usr/bin/env python3
"""Extract native sample evidence; sum current footprints, never peak footprints."""
import csv
import hashlib
import json
from pathlib import Path
import re
import sys

source = Path(sys.argv[1] if len(sys.argv)>1 else '/private/tmp/markdown-rust-memory')
root = Path(__file__).resolve().parents[1]
output = root / 'rust-comparison' / 'results'
output.mkdir(exist_ok=True)
records = []
summary = []
for variant in ['egui', 'iced', 'slint', 'fltk', 'wry']:
    for stage in ['idle', 'small', 'medium', 'large', 'very-large']:
        pattern = f'{variant}-{stage}-[0-9]*.txt'
        paths = sorted(source.glob(pattern))
        expected = 4 if variant == 'wry' else 1
        if len(paths) != expected:
            raise SystemExit(f'{variant}/{stage}: expected {expected} samples, found {len(paths)}')
        total = 0
        for path in paths:
            data = path.read_text()
            value, unit = re.search(r'^Physical footprint:\s+([\d.]+)([KMG])', data, re.M).groups()
            mib = float(value) * {'K': 1/1024, 'M': 1, 'G': 1024}[unit]
            total += mib
            records.append(dict(variant=variant,stage=stage,process=re.search(r'^Process:\s+(.+)$',data,re.M)[1],timestamp=re.search(r'^Date/Time:\s+(.+)$',data,re.M)[1],footprint_display=value+unit,footprint_mib=mib,source_file=path.name,source_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        summary.append(dict(variant=variant,stage=stage,process_count=expected,footprint_mib=round(total,1)))
(output/'memory-processes.json').write_text(json.dumps(records,indent=2)+'\n')
with (output/'memory.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=['variant','stage','process_count','footprint_mib'],lineterminator='\n');writer.writeheader();writer.writerows(summary)
for variant in ['egui','iced','slint','fltk','wry']:
    print(variant, ' | '.join(str(s['footprint_mib']) for s in summary if s['variant']==variant))
