#!/usr/bin/env python3
"""Bounded cold masking costs, plus a diagnostic sweep of each production guard/rule.

The harness uses invented runs only. A subprocess deadline stops even a regex that cannot
be interrupted on its own; the hard regression bound compares interleaved baseline runs.
"""
import json
import os
from pathlib import Path
import subprocess
import statistics

SIZES = (300, 2_000, 10_000, 100_000)
NUMERIC = ('digits', 'split-digits')
GUARD_CASES = ('ordinary-few-digits', 'log-like', 'source-like')
# URL parameter values with nothing to mask: read decoded, once and to the end.
URL_CASES = ('url-value', 'url-five-deep', 'url-fifty-deep', 'url-percent-chain', 'url-parameters')
KINDS = ('ordinary', 'letters', *NUMERIC, 'hex', 'dots', 'slashes', 'percents', 'backslashes', 'labels', 'joined-prefixes', 'credential-prefixes', 'ocr-path')
TEMP = Path(os.environ['ACTIVITYPROBE_TEST_ROOT']).resolve()
BINARY = TEMP / 'redaction-harness'
ROOT = Path(__file__).resolve().parents[1]
BASE_SOURCE = ROOT / 'tools/redaction_cost_baseline.swift'
BASE_BINARY = TEMP / 'redaction-cost-baseline'
# Ordinary and URL cases measured below 2x; historical numeric/prefix fast paths
# approach 3x with the added scan. Budgets include headroom and 2 ms scheduler noise.
MAX_COST_RATIO = 2.5
NOISE_SECONDS = 0.002


def ratio_limit(operation, kind):
    return 3.5 if operation == 'apply' and kind in ('digits', 'split-digits', 'joined-prefixes') else MAX_COST_RATIO


def build_baseline():
    harness = ROOT / 'tools/redaction_cost_harness.swift'
    if not BASE_BINARY.exists() or BASE_BINARY.stat().st_mtime < max(BASE_SOURCE.stat().st_mtime, harness.stat().st_mtime):
        subprocess.run(['swiftc', '-j', '1', '-module-cache-path', str(TEMP / 'module-cache'),
                        '-parse-as-library', '-D', 'REDACTION_COST_ONLY', str(BASE_SOURCE),
                        str(harness), '-o', str(BASE_BINARY)], check=True)


def paired_cost(operation, size, kind, pairs=3):
    limit = ratio_limit(operation, kind)
    measurements = []
    for index in range(pairs):
        binaries = (BASE_BINARY, BINARY) if index % 2 == 0 else (BINARY, BASE_BINARY)
        measured = {binary: sample(operation, size, kind, binary) for binary in binaries}
        measurements.append((measured[BASE_BINARY], measured[BINARY]))
    if any(before is None or after is None for before, after in measurements):
        return dict(seconds=None, baseline_seconds=None, budget_ratio=None, pairs=pairs, max_ratio=limit)
    return dict(seconds=statistics.median(after for before, after in measurements),
                baseline_seconds=statistics.median(before for before, after in measurements),
                budget_ratio=statistics.median(after / (before + NOISE_SECONDS / limit)
                                              for before, after in measurements), pairs=pairs, max_ratio=limit)


def exceeds_budget(row):
    return row['budget_ratio'] is None or row['budget_ratio'] > row['max_ratio']


def sample(operation, size, kind, binary=BINARY):
    try:
        result = json.loads(subprocess.check_output([str(binary), 'cost', operation, str(size), kind], text=True, timeout=10))
        if operation == 'apply':
            assert result['result'] == size * (5 if size <= 2000 else 1), (operation, size, kind, 'changed unchanged run')
        return result['seconds']
    except subprocess.TimeoutExpired:
        return None


def best_sample(operation, size, kind):
    samples = [sample(operation, size, kind) for _ in range(3)]
    completed = [value for value in samples if value is not None]
    return min(completed) if completed else None


def check_costs():
    build_baseline()
    rows = []
    failed = []
    cases = {'mayMatch': (*NUMERIC, *GUARD_CASES), 'apply': (*NUMERIC, *GUARD_CASES, 'joined-prefixes', 'credential-prefixes', 'ocr-path', *URL_CASES),
             'pattern-8': ('credential-prefixes',), 'pattern-10': KINDS[1:], 'urlCandidate': KINDS[1:]}
    for operation, kinds in cases.items():
        for size in SIZES:
            baseline = best_sample(operation, size, 'ordinary')
            assert baseline is not None
            for kind in kinds:
                row = paired_cost(operation, size, kind)
                # Retry a borderline ratio with more interleaved pairs, never relax the budget.
                if row['budget_ratio'] is not None and exceeds_budget(row):
                    row = paired_cost(operation, size, kind, pairs=7)
                row.update(operation=operation, size=size, kind=kind, ordinary_seconds=baseline,
                           baseline_fixture=str(BASE_SOURCE.relative_to(ROOT)))
                rows.append(row)
                if exceeds_budget(row):
                    failed.append((operation, size, kind, row['budget_ratio'], row['max_ratio']))
    (TEMP / 'redaction-cost-checks.json').write_text(json.dumps(rows, indent=2) + '\n')
    for size in SIZES:
        values = {r['kind']: round(r['seconds'] * 1000, 3) if r['seconds'] is not None else 'timeout' for r in rows if r['operation'] == 'apply' and r['size'] == size}
        print('cold masking ms', size, values, flush=True)
    for operation in ('pattern-10', 'urlCandidate'):
        measured = [r for r in rows if r['operation'] == operation and r['size'] == 100000]
        worst = max(measured, key=lambda r: r['seconds'] if r['seconds'] is not None else float('inf'))
        print(operation, '100000-character worst ms', None if worst['seconds'] is None else round(worst['seconds'] * 1000, 3), worst['kind'], flush=True)
    assert not failed, failed


def sweep():
    operations = subprocess.check_output([str(BINARY), 'cost-operations'], text=True).splitlines()
    rows = []
    for operation in operations:
        stopped = set()
        for size in SIZES:
            for kind in KINDS:
                if kind in stopped:
                    continue
                seconds = sample(operation, size, kind)
                rows.append(dict(operation=operation, size=size, kind=kind, seconds=seconds))
                if seconds is None:
                    stopped.add(kind)
                    print('stopped at 10 seconds:', operation, size, kind, flush=True)
        print('swept', operation, flush=True)
    (TEMP / 'redaction-rule-costs.json').write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    assert TEMP.is_relative_to(Path('/tmp').resolve())
    for key in ('ACTIVITYPROBE_DB', 'CFFIXED_USER_HOME'):
        assert Path(os.environ[key]).resolve().is_relative_to(TEMP)
    check_costs()
    if '--sweep' in __import__('sys').argv:
        sweep()
