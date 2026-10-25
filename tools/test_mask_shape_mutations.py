#!/usr/bin/env python3
"""Remove individual shape conditions in isolated copies and run the real XCTest cases."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TEMP = Path(os.environ.get('ACTIVITYPROBE_TEST_ROOT', '/tmp/ap-mask-fix'))


def main():
    source = (ROOT / 'Sources/Core/Redaction.swift').read_text()
    mutations = [
        ('ASCII', 'guard (33...126).contains(c) else { return false }',
         'if !(33...126).contains(c) { classes |= 8; counts[Int(c % 95)] += 1; continue }'),
        ('two classes', 'classes.nonzeroBitCount >= 2, classes & 12 != 0', 'classes & 12 != 0'),
        ('digit or symbol', 'classes.nonzeroBitCount >= 2, classes & 12 != 0', 'classes.nonzeroBitCount >= 2'),
        ('entropy', 'return h >= 4', 'return true'),
        ('host retained', 'guard tail < range.upperBound else { return }',
         'pieces(url.end..<tail)\n      guard tail < range.upperBound else { return }'),
        ('query names retained', 'valueStart = sep + 1', 'pieces(at..<sep); valueStart = sep + 1'),
        ('query decoding', 'let value = String(decoding: decoded, as: UTF8.self)', 'let value = string(range)'),
        ('path splitting', 'if path {\n        var at = start', 'if false {\n        var at = start'),
        ('label splitting', 'separator < end - 1, label(start..<separator)', 'false'),
        ('base64 kept whole', 'if !path, !base64(start..<end)', 'if !path'),
        ('trailing period', 'while end > start, chars[end - 1] == "." { end -= 1 }', ''),
        ('label entropy', '&& entropy(chars, range) < 3.5', ''),
        ('Unicode whitespace', ': chars[i].properties.isWhitespace', ': false'),
        ('ASCII control whitespace', ' || (28...31).contains(c)', ''),
        ('base64 padding', 'padding <= 2, end > range.lowerBound', 'end > range.lowerBound'),
        ('bare host', 'if !web, !componentsOnly, let tail = bareHostEnd(start..<end)', 'if false, let tail = bareHostEnd(start..<end)'),
        ('nested parent decoding', 'if !web, !componentsOnly, let tail = bareHostEnd(start..<end)', 'if !web, let tail = bareHostEnd(start..<end)'),
        ('base64 discriminator', 'guard range.contains(where: { (48...57).contains(chars[$0].value) || chars[$0] == "+" }) else { return false }', ''),
        ('quote delimiters', 'Set("\\\"\'[]{}(),;`".unicodeScalars)', 'Set("[]{}(),;`".unicodeScalars)'),
    ]
    package = TEMP / 'mutations'
    (package / 'Sources/Core').mkdir(parents=True, exist_ok=True)
    (package / 'Tests/CoreTests').mkdir(parents=True, exist_ok=True)
    (package / 'Package.swift').write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "ShapeMutation", platforms: [.macOS(.v14)], targets: [.target(name: "Core"), .testTarget(name: "CoreTests", dependencies: ["Core"])])
''')
    (package / 'Tests/CoreTests/RedactionShapeTests.swift').write_text(
        (ROOT / 'tests/CoreTests/RedactionShapeTests.swift').read_text())
    env = dict(os.environ, ACTIVITYPROBE_TEST_ROOT=str(TEMP), ACTIVITYPROBE_DB=str(TEMP/'mutation.sqlite'),
               CFFIXED_USER_HOME=str(TEMP/'home'), TMPDIR=str(TEMP/'tmp'))
    results = []
    for name, before, after in [('unmodified', '', '')] + mutations:
        if before:
            assert source.count(before) == 1, name
        changed = source.replace(before, after, 1) if before else source
        (package / 'Sources/Core/Redaction.swift').write_text(changed)
        command = ['swift', 'test', '--jobs', '1', '--scratch-path', str(TEMP/'mutation-build'),
                   '--package-path', str(package), '--filter', 'RedactionShapeTests']
        run = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (TEMP / ('mutation-' + name.replace(' ', '-') + '.log')).write_text(run.stdout)
        failing = sorted(set(re.findall(r"Test Case '.*? (test\w+)\]' failed", run.stdout)))
        result = dict(condition=name, exit_status=run.returncode, failed_test_methods=failing)
        results.append(result)
        print(json.dumps(result, sort_keys=True), flush=True)
        assert (run.returncode == 0) if name == 'unmodified' else (run.returncode == 1 and failing), name
    (TEMP/'mutation-summary.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
