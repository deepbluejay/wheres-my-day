#!/usr/bin/env python3
"""One-off aggregate measurement. Never emits a stored value; opens only a temp copy read-only."""
import json
import os
import sqlite3
import subprocess
from collections import Counter
from pathlib import Path
from test_redaction import build

TEMP = Path('/tmp/ap-pii')
DB = TEMP / 'copy.sqlite'

def quote(name):
    return '"' + name.replace('"', '""') + '"'

def main():
    assert os.environ.get('ACTIVITYPROBE_DB', '').startswith(str(TEMP) + '/')
    assert os.environ.get('CFFIXED_USER_HOME', '').startswith(str(TEMP) + '/')
    if not DB.is_file():
        raise SystemExit('Create the single read-only backup at /tmp/ap-pii/copy.sqlite first.')
    binary = build()
    db = sqlite3.connect(f'file:{DB}?mode=ro&immutable=1', uri=True)
    results = []
    tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    process = subprocess.Popen([str(binary), 'batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    for table in tables:
        for column in db.execute(f'PRAGMA table_info({quote(table)})'):
            name, sqltype = column[1], column[2]
            if 'TEXT' not in sqltype.upper():
                continue
            rows, changed, counts = 0, 0, Counter()
            for (value,) in db.execute(f'SELECT {quote(name)} FROM {quote(table)} WHERE typeof({quote(name)})=\'text\''):
                rows += 1
                process.stdin.write(json.dumps(value, ensure_ascii=False) + '\n')
                process.stdin.flush()
                report = json.loads(process.stdout.readline())
                changed += report['changed']
                counts.update(report['rules'])
            results.append({'table': table, 'column': name, 'rows': rows, 'changed_rows': changed, 'rules': dict(sorted(counts.items()))})
    process.stdin.close()
    assert process.wait() == 0
    db.close()
    benchmark = json.loads(subprocess.check_output([str(binary), 'bench'], text=True))
    output = {'columns': results, 'benchmark': benchmark}
    path = TEMP / 'redaction-measurement.json'
    path.write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
    table_path = TEMP / 'redaction-counts.tsv'
    table_path.write_text('table.column\trows\tchanged_rows\trule_row_counts\n' + ''.join(
        f"{r['table']}.{r['column']}\t{r['rows']}\t{r['changed_rows']}\t{json.dumps(r['rules'], sort_keys=True)}\n" for r in results))
    print(json.dumps({'columns': len(results), 'changed_columns': sum(r['changed_rows'] > 0 for r in results),
                      'changed_cells': sum(r['changed_rows'] for r in results), 'benchmark': benchmark}, sort_keys=True))

if __name__ == '__main__':
    main()
