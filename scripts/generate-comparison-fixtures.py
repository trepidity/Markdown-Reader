#!/usr/bin/env python3
"""Generate identical, fixed-size renderer workloads with unique heading IDs."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1] / 'comparison' / 'fixtures'
root.mkdir(exist_ok=True)
records = {}
for name, size in [('small',8192), ('medium',262144), ('large',1048576), ('very-large',4194304)]:
    parts = [f'# {name} workload\n\n']
    length = len(parts[0])
    i = 0
    while length < size:
        i += 1
        part = f'## Section {i}\n\nA paragraph with **bold**, *italic*, and `inline code`. This is the memory comparison workload.\n\n- Alpha item\n- Beta item\n\n'
        parts.append(part)
        length += len(part)
    data = ''.join(parts).encode()[:size]
    (root / (name + '.md')).write_bytes(data)
    records[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
(root / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
