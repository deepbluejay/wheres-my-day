#!/usr/bin/env python3
"""Cold whole-command masking timings, one process per invented input, ten-second stop."""
import json
import os
from pathlib import Path
import subprocess
import time

TEMP = Path(os.environ['ACTIVITYPROBE_TEST_ROOT']).resolve()
SIZES = (10_000, 100_000, 1_000_000)

def corpus():
    for size in SIZES:
        for kind, unit, tail in [
            ('ordinary-few-digits', 'Invented prose explains a small measurement in plain words. ', ' There are 2 notes, 3 lines and 4 tasks in 2026.'),
            ('log-like', '2026-10-12 08:42:11 event=42 elapsed=125 count=3\n', ''),
            ('source-like', 'let count = 42\nlet limit = 2026\nif count < limit { count += 1 }\n', ''),
            ('hyphen-letters-year', 'a-', ' year 2026'),
            ('hyphen-letters-seven-digits', 'a-', ' year 2026 count 123'),
        ]:
            yield kind, size, (unit * (size // len(unit) + 1))[:size - len(tail)] + tail

def measure(binary):
    rows = []
    for kind, size, text in corpus():
        start = time.perf_counter()
        try:
            result = subprocess.run([str(binary), 'privacy', 'mask'], input=json.dumps([text]), text=True, capture_output=True, timeout=10, check=True)
            seconds = time.perf_counter() - start
            outputs = json.loads(result.stdout)
            assert len(outputs) == 1
            row = dict(kind=kind, size=size, seconds=seconds, changed=outputs[0] != text)
        except subprocess.TimeoutExpired:
            row = dict(kind=kind, size=size, seconds=None, changed=None)
        rows.append(row)
        print(json.dumps(row), flush=True)
    return rows

if __name__ == '__main__':
    import sys
    assert TEMP.is_relative_to(Path('/tmp').resolve())
    for key in ('ACTIVITYPROBE_DB', 'CFFIXED_USER_HOME'):
        assert Path(os.environ[key]).resolve().is_relative_to(TEMP)
    rows = measure(Path(sys.argv[1]))
    (TEMP / sys.argv[2]).write_text(json.dumps(rows, indent=2) + '\n')
