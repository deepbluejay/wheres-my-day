#!/usr/bin/env python3
"""Run the production shape rules without apps, capture, databases or model calls."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMP = Path(os.environ.get('ACTIVITYPROBE_TEST_ROOT', '/tmp/ap-pii')).resolve()

def build():
    TEMP.mkdir(exist_ok=True)
    binary = TEMP / 'redaction-harness'
    subprocess.run(['swiftc', '-j', '1', '-module-cache-path', str(TEMP / 'module-cache'),
                    '-parse-as-library', os.environ.get('ACTIVITYPROBE_REDACTION_SOURCE', str(ROOT / 'Sources/Core/Redaction.swift')),
                    str(ROOT / 'tests/CoreTests/RedactionFormatsFixtures.swift'),
                    str(ROOT / 'tests/CoreTests/RedactionFormatsTest.swift'),
                    str(ROOT / 'Sources/Core/RedactionLabelCorpus.swift'),
                    str(ROOT / 'tests/CoreTests/RedactionHistoryTest.swift'),
                    str(ROOT / 'tests/CoreTests/RedactionRegexTest.swift'),
                    str(ROOT / 'tools/redaction_harness.swift'),
                    str(ROOT / 'tools/redaction_cost_harness.swift'), '-o', str(binary)], check=True)
    return binary

if __name__ == '__main__':
    assert TEMP.is_relative_to(Path('/tmp').resolve())
    for key in ('ACTIVITYPROBE_DB', 'CFFIXED_USER_HOME'):
        assert os.environ.get(key) and Path(os.environ[key]).resolve().is_relative_to(TEMP), key
    subprocess.run([sys.executable, '-B', str(ROOT / 'tools/test_redaction_cost_budget.py')], check=True)
    subprocess.run([str(build()), 'fixtures'], check=True)
    from test_redaction_cost import check_costs
    check_costs()
