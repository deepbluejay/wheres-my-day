"""Prove the Git schedule oracle detects broken production code in an owned copy.

Run explicitly; the ordinary suite retains the fast, deterministic schedules.
Each mutant must compile and fail its designated model assertion. Build failures,
crashes, unrelated assertions and timeouts never count as a killed mutant.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATE = 'Sources/Storage/GitPublication.swift'
COLLECTION = 'Sources/Storage/GitCollection.swift'

# Each replacement is pinned to one source occurrence, so source drift fails
# loudly rather than silently changing the mutation being tested.
MUTANTS = [
    ('admission', GATE,
     'if let refusal = try gitPublicationRefusal(operation, now: now) {',
     'if let refusal: GitPublicationRefusal = nil {',
     'testGeneratedAdmissionSchedules', 'admission'),
    ('completion', GATE,
     'try? gitLocked { gitDidInterrupt(.commitUnit(id)) }',
     '// Mutant: a caught child-stream error no longer interrupts the parent.',
     'testGeneratedCompletionSchedules', 'completion'),
    ('frontier', GATE,
     'guard read.state == .admitted,\n      try connection.integer("SELECT EXISTS(SELECT 1 FROM git_commits WHERE repo_id=? AND complete!=1)", [.integer(repo)]) == 0 else { return .interrupted }',
     'guard repo > 0 else { return .interrupted }',
     'testGeneratedFrontierSchedules', 'frontier'),
    ('interruption', GATE,
     'return current === owner && !owner.isCancelled',
     'return true // Mutant: replacement producer steals cancelled work.',
     'testGeneratedInterruptionSchedules', 'interruption'),
    ('erasure', COLLECTION,
     'SELECT EXISTS(SELECT 1 FROM git_tombstones WHERE hash=?) OR EXISTS(SELECT 1 FROM git_commits WHERE repo_id=? AND hash=? AND complete=1)',
     'SELECT 0*EXISTS(SELECT 1 FROM git_tombstones WHERE hash=?) OR EXISTS(SELECT 1 FROM git_commits WHERE repo_id=? AND hash=? AND complete=1)',
     'testGeneratedErasureSchedules', 'erasure'),
    ('retention', GATE,
     'return receipt.authorTime < cutoff || receipt.commitTime < cutoff ? .expired : nil',
     'if receipt.authorTime < cutoff || receipt.commitTime < cutoff {\n      try connection.run("INSERT OR IGNORE INTO git_tombstones VALUES(?)", [.key(receipt.hash)])\n      return .expired\n    }\n    return nil',
     'testGeneratedRetentionSchedules', 'retention'),
]


def run(command, cwd, log):
    with log.open('w') as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=600)
    return result.returncode, log.read_text()


def swift_trace(trace):
    steps = []
    for step in trace.removeprefix('1-minimal=').split(' -> '):
        if step.startswith(('discover(', 'file(')):
            steps.append('.' + step)
        elif step.startswith('after('):
            phase, event = step[6:-1].split(',')
            steps.append('.arm("' + phase + '", .' + event + ')')
        elif step in ('prepare', 'parent', 'ref', 'complete', 'stage', 'certify', 'retime', 'retry'):
            steps.append('.' + step)
        else:
            if not re.fullmatch(r'[A-Za-z]+', step):
                raise AssertionError('Unrecognized trace step: ' + step)
            steps.append('.event(.' + step + ')')
    return ', '.join(steps)


def verify_original_trace(copy, logs, name, trace):
    path = copy / 'tests/AgentLogTests/GitPublicationScheduleTests.swift'
    original = path.read_text()
    replay = ("\nextension GitPublicationScheduleTests {\n"
              "  func testCounterexampleOnUnmodifiedSource() throws {\n"
              "    for bytes in [65537, 81921, 98305] {\n"
              "      let copy = try GitScheduleReplay(bytes: bytes); defer { copy.close() }\n"
              "      try copy.run([" + swift_trace(trace) + "])\n"
              "    }\n"
              "  }\n}\n")
    try:
        path.write_text(original + replay)
        code, output = run(['swift', 'test', '--jobs', '1', '--filter',
                            'GitPublicationScheduleTests.testCounterexampleOnUnmodifiedSource'],
                           copy, logs / (name + '-original-trace.log'))
        if code or not re.search(r'Executed 1 test, with 0 failures', output):
            raise AssertionError(name + ': reduced trace also fails on original source')
    finally:
        path.write_text(original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-dir', type=pathlib.Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='activityprobe-git-mutants-') as temporary:
        work = pathlib.Path(temporary)
        copy = work / 'source'
        copy.mkdir()
        for directory in ('Sources', 'tests', 'tools', 'Plugins'):
            shutil.copytree(ROOT / directory, copy / directory, ignore=shutil.ignore_patterns('__pycache__', '.DS_Store'))
        shutil.copy2(ROOT / 'Package.swift', copy / 'Package.swift')
        logs = args.report_dir or work / 'logs'
        logs.mkdir(parents=True, exist_ok=True)
        command = ['swift', 'test', '--jobs', '1', '--filter', 'GitPublicationScheduleTests']
        code, output = run(command, copy, logs / 'baseline.log')
        if code or not re.search(r'Executed 7 tests, with 0 failures', output):
            raise AssertionError('Unmodified copied-source baseline did not pass; see ' + str(logs / 'baseline.log'))
        print('baseline: 7 schedule tests passed', flush=True)
        for name, file, before, after, method, property_name in MUTANTS:
            path = copy / file
            original = path.read_text()
            if original.count(before) != 1:
                raise AssertionError(name + ': mutation anchor is not unique')
            try:
                path.write_text(original.replace(before, after))
                code, output = run(['swift', 'test', '--jobs', '1', '--filter', 'GitPublicationScheduleTests.' + method], copy, logs / (name + '.log'))
                marker = 'MODEL ' + name
                if not code or 'Build complete!' not in output or marker not in output or '1-minimal=' not in output:
                    raise AssertionError(name + ': mutant survived or failed for an unrelated reason')
                failure = next(line for line in output.splitlines() if marker in line)
                if not re.search(r'MODEL \w+ case=\d+ ' + re.escape(property_name) + ':', failure):
                    raise AssertionError(name + ': expected property ' + property_name + ', got ' + failure)
                trace = next(line for line in output.splitlines() if line.startswith('1-minimal='))
                print(name + ': killed; ' + trace, flush=True)
            finally:
                path.write_text(original)
            verify_original_trace(copy, logs, name, trace)
            print(name + ': reduced trace passes on unmodified production source', flush=True)
        # The seventh property is static. Inject a real bypass in the copied
        # source, then run the ordinary catalog test against that actual file.
        path = copy / COLLECTION
        original = path.read_text()
        try:
            path.write_text(original + '\nextension ActivityStorage {\n  func inventedBypass() throws { try connection.run("INSERT INTO git_tombstones VALUES(?)", [.key("invented")]) }\n}\n')
            code, output = run(['python3', 'tools/test_git_publication.py'], copy, logs / 'inventory.log')
            if not code or 'Unreviewed Git mutation' not in output or 'FAILED (failures=1)' not in output:
                raise AssertionError('inventory bypass was not rejected by the pinned mutation catalog')
            print('inventory: killed; ungated Git INSERT rejected', flush=True)
        finally:
            path.write_text(original)
        print('all 7 production-source mutants killed; copied source and scratch deleted on exit', flush=True)


if __name__ == '__main__':
    main()
