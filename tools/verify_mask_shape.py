#!/usr/bin/env python3
"""Compare invented token ranges only; never read a database or print values."""
import argparse
from collections import Counter, defaultdict
import difflib
import json
from pathlib import Path
import re
import subprocess
from measure_mask_shape import Baseline, CANDIDATES, covered, invented_secrets, placements, selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('harness', type=Path)
    parser.add_argument('--baseline-harness', type=Path)
    args = parser.parse_args()
    candidate = next(c for c in CANDIDATES if c.name == 'B16_4_ASCII')
    texts = [text for _, secret in invented_secrets() for _, text, _, _ in placements(secret)]
    texts += [
        '日本語文章読書作業記録確認試験設計実装2026!',
        '中文简体连续句子阅读记录设计实现测试2026!',
        '한국어문장읽기활동기록설계구현시험확인2026!',
        'aB7xQ2pL9mR4zT6vé',
        'https://invented.invalid/read?v=aB7xQ2pL9mR4zT6v%FF',
        'https://invented.invalid/read?v=aB7xQ2pL9mR4zT6v%20ordinary',
        'https://invented.invalid/read?v=https%3A%2F%2FaB7xQ2pL9mR4zT6v.invalid',
        'https://aB7xQ2pL9mR4zT6v.invalid/read?aB7xQ2pL9mR4zT6v=ordinary',
        'longMeaningfulIdentifierName2026 long_meaningful_identifier_name_2026',
        'v123.456.7890 /readable/project/documentation/source2.swift',
        '01234567-89ab-cdef-0123-456789abcdef d41d8cd98f00b204e9800998ecf8427e012345678',
    ]
    texts += ['π' + chr(i) + 'aB7xQ2pL9mR4zT6v' for i in range(0x110000) if chr(i).isspace()]
    texts += [label + ':aB7xQ2pL9mR4zT6v' for label in ('²', 'Ⅷ', 'e\u0301', 'é')]
    texts += ['httpſ://aB7xQ2pL9mR4zT6v.invalid/read?v=aB7xQ2pL9mR4zT6v']
    texts += ['chat.example/c/01234567-89ab-cdef-0123-456789abcdef',
              'notes.example/Page-Name-0123456789abcdef0123456789abcdef',
              'notes.example/read?v=aB7xQ2pL9mR4zT6v',
              'Sources/Shell/Commands',
              '/Users/someone/My Projects/ActivityProbe/mask-shape',
              'AbCdEfGhIjKlMnOp/QrStUvWxYz+',
              'AbCdEfGhIjKlMnOp/aB7xQ2pL9mR4zT6v===']
    payload = ''.join(json.dumps(text, ensure_ascii=False) + '\n' for text in texts)
    process = subprocess.run([str(args.harness), 'shape-batch'], input=payload, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    outputs = process.stdout.rstrip('\n').split('\n')
    assert len(outputs) == len(texts)
    differences = []
    for index, (text, output) in enumerate(zip(texts, outputs)):
        def utf16(at):
            return len(text[:at].encode('utf-16-le')) // 2
        expected = [[utf16(a), utf16(b)] for a, b in selected(text, candidate)]
        if json.loads(output) != expected:
            differences.append(index)
    print(json.dumps({'inputs': len(texts), 'differences': len(differences),
                      'invented_input_indices': differences[:40]}, sort_keys=True))
    if differences:
        raise SystemExit(1)
    if args.baseline_harness:
        def engine(harness):
            run = subprocess.run([str(harness), 'batch'], input=payload, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            return [json.loads(line) for line in run.stdout.rstrip('\n').split('\n')]
        before, after = engine(args.baseline_harness), engine(args.harness)
        assert len(before) == len(after) == len(texts)
        def shape(text):
            if re.fullmatch(r'[0-9a-fA-F_:\-,]+', text) and re.search(r'[a-fA-F]', text):
                return text
            try:
                value = json.loads(text) if text.startswith(('{', '[')) else None
            except ValueError:
                value = None
            if isinstance(value, (dict, list)):
                def clean(value):
                    if isinstance(value, str):
                        return shape(value)
                    if isinstance(value, list):
                        return [clean(v) for v in value]
                    if isinstance(value, dict):
                        return {k: clean(v) for k, v in value.items()}
                    return value
                cleaned = clean(value)
                return text if cleaned == value else json.dumps(cleaned, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
            spans = selected(text, candidate)
            # Retain the atomic mark handling used after the old rules.
            spans = [(a, b + 1 if b < len(text) and text[b] == ']' and
                      any(text[a:b].endswith(mark[:-1]) for mark in ('[secret]', '[email]')) else b)
                     for a, b in spans]
            result, at = [], 0
            for a, b in spans:
                result.extend((text[at:a], '[secret]'))
                at = b
            return ''.join(result) + text[at:]
        composition_differences = [i for i, (old, new) in enumerate(zip(before, after)) if shape(old) != new]
        def covered_by_marks(text, result, start, end):
            result = result.replace('[secret]', '\0').replace('[email]', '\0')
            blocks = difflib.SequenceMatcher(None, text, result, autojunk=False).get_matching_blocks()
            return not any(a < end and a + n > start for a, _, n in blocks)
        counts = defaultdict(Counter)
        baseline = Baseline()
        baseline_differences = Counter()
        total_differences = Counter()
        i = 0
        for kind, secret in invented_secrets():
            for context, text, start, end in placements(secret):
                old, new = covered_by_marks(text, before[i], start, end), covered_by_marks(text, after[i], start, end)
                counts[kind].update(total=1, baseline=old, production=new)
                spans = baseline.ranges(text)
                if old != covered(spans, start, end):
                    baseline_differences[kind + '/' + context] += 1
                if new != covered(spans + selected(text, candidate), start, end):
                    total_differences[kind + '/' + context] += 1
                i += 1
        print(json.dumps({'production_inputs': len(texts), 'composition_differences': len(composition_differences),
                          'invented_input_indices': composition_differences[:40], 'swift_recall': counts,
                          'python_baseline_recall_differences': baseline_differences,
                          'python_union_recall_differences': total_differences}, sort_keys=True))
        if composition_differences:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
