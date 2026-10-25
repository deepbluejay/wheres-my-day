#!/usr/bin/env python3
"""Count-only, offline comparison of language-free masking candidates.

Requires a single authorized backup in the explicitly selected temporary root.
Never opens the live database, emits evidence, or calls a model. The baseline is
an explicitly scoped Python translation, not a verified Swift execution.
"""
import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import random
import re
import sqlite3
import statistics
import string
import time
from urllib.parse import quote, unquote

ROOT = Path(__file__).resolve().parents[1]
TEMP = Path('/tmp/ap-mask-shape')
KINDS = ('hex hash', 'UUID', 'base64-like', 'number with separators',
         'path segment', 'part of a web address', 'code identifier',
         'version string', 'word with a digit', 'mixed-language word', 'other')
LABELS = {
    'English': 'password', 'Korean': '비밀번호', 'Japanese': 'パスワード',
    'Simplified Chinese': '密码', 'Traditional Chinese': '密碼',
    'German': 'Passwort', 'French': 'mot_de_passe',
    'Spanish': 'contraseña', 'Portuguese': 'senha',
}
MARKS = {'secret', 'redacted', 'email', 'phone'}
WORD = re.compile(r'\w+', re.UNICODE)
RUN = re.compile(r'\S+')
HEX = re.compile(r'[0-9a-fA-F]{7,64}\Z')
UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z')
VERSION = re.compile(r'v?\d+(?:\.\d+){1,5}(?:[-+][A-Za-z0-9._-]+)?\Z')
B64 = re.compile(r'[A-Za-z0-9+/_-]+={0,2}\Z')


def entropy(value):
    n = len(value)
    return -sum((c / n) * math.log2(c / n) for c in Counter(value).values()) if n else 0.0


def class_rule(value):
    lower = upper = digit = symbol = False
    for ch in value:
        lower |= ch.islower()
        upper |= ch.isupper()
        digit |= ch.isdecimal()
        symbol |= not ch.isalnum()
    return sum((lower, upper, digit, symbol)) >= 2 and (digit or symbol)


@dataclass(frozen=True)
class Candidate:
    name: str
    minimum: int
    mode: str
    bound: float = 0.0
    ascii_only: bool = False

    def accepts(self, value, h=None, classes=None):
        if self.ascii_only and any(not 33 <= ord(ch) <= 126 for ch in value):
            return False
        if len(value) < self.minimum or value in MARKS:
            return False
        if self.mode in ('class', 'both') and not (class_rule(value) if classes is None else classes):
            return False
        return self.mode == 'class' or (entropy(value) if h is None else h) >= self.bound


# 4 class thresholds, 3 entropy thresholds at 16, 4 combined lengths at 3.5,
# and the stricter combined threshold with and without the ASCII-only condition.
CANDIDATES = tuple(
    [Candidate(f'C{n}', n, 'class') for n in (12, 16, 20, 24)]
    + [Candidate(f'E16_{b:g}', 16, 'entropy', b) for b in (3.0, 3.5, 4.0)]
    + [Candidate(f'B{n}_3.5', n, 'both', 3.5) for n in (12, 16, 20, 24)]
    + [Candidate('B16_4', 16, 'both', 4.0),
       Candidate('B16_4_ASCII', 16, 'both', 4.0, ascii_only=True)]
)


@dataclass(frozen=True)
class Token:
    start: int
    end: int
    value: str
    context: str = 'plain'
    whole_value: bool = False


def pieces(value, offset, context='plain', components_only=False):
    """Split only recognized structure, keeping random slash-bearing bodies whole."""
    for part in re.finditer(r'''[^"'\[\]{}(),;`]+''', value):
        v = part.group().rstrip('.')
        if not v:
            continue
        start = offset + part.start()
        if v in MARKS:
            continue
        # One named assignment or label separator; padding and random punctuation stay.
        m = re.match(r'^([^:=]+)[:=](.+)$', v)
        if m and re.fullmatch(r'[^\W\d][\w-]*', m[1], re.UNICODE) and entropy(m[1]) < 3.5:
            yield Token(start, start + len(m[1]), m[1], context)
            yield from pieces(m[2], start + m.start(2), context, components_only)
            continue
        if not components_only and context == 'plain' and re.match(r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]+/', v):
            yield from tokens('https://' + v, offset=start - 8)
            continue
        # Explicit/relative filesystem paths, or slash runs with a readable directory.
        # A high-entropy base64 body is deliberately not inferred to be a relative path.
        base64_body = len(v) >= 20 and B64.fullmatch(v) and entropy(v) >= 3.5 and bool(re.search(r'[0-9+]', v))
        path = v.startswith(('/', './', '../', '~/')) or (
            '/' in v and not base64_body and any(
                re.fullmatch(r'[A-Za-z_-]{2,}', p) for p in v.split('/')[:-1]))
        if context == 'web' or path:
            for p in re.finditer(r'[^/.:=@?&#]+', v):
                yield Token(start + p.start(), start + p.end(), p.group(), 'web' if context == 'web' else 'path')
        else:
            yield Token(start, start + len(v), v, context)


def tokens(text, offset=0):
    """Non-space runs are parents; recognized URL components are child tokens."""
    for run in RUN.finditer(text):
        raw = run.group()
        url = re.search(r'https?://', raw, flags=re.I)
        if not url:
            yield from pieces(raw, (run.start() + offset))
            continue
        if url.start():
            yield from pieces(raw[:url.start()], (run.start() + offset))
        # Scheme and complete host are retained; path/query/fragment are separate.
        host_end = re.search(r'[/\?#]', raw[url.end():])
        if host_end is None:
            continue
        tail_at = url.end() + host_end.start()
        suffix = raw[tail_at:]
        query_at = re.search(r'[?#]', suffix)
        path = suffix[:query_at.start()] if query_at else suffix
        yield from pieces(path, (run.start() + offset) + tail_at, 'web')
        if query_at:
            rest_at = tail_at + query_at.start() + 1
            rest = raw[rest_at:]
            for item in re.finditer(r'[^&#;]+', rest):
                item_value = item.group().rstrip('"\'[]{}(),.')
                sep = item_value.find('=')
                if sep >= 0:
                    # Parameter names are structure, just like the preserved host.
                    at = rest_at + item.start() + sep + 1
                    encoded = item_value[sep + 1:]
                else:
                    at = rest_at + item.start()
                    encoded = item_value
                decoded = unquote(encoded)
                # Do not emit decoded material: one match hides the written value whole.
                for sub in pieces(decoded, 0, components_only=True):
                    yield Token((run.start() + offset) + at, (run.start() + offset) + at + len(encoded),
                                sub.value, 'web', True)


def classify(t):
    v = t.value
    if UUID.fullmatch(v):
        return 'UUID'
    if HEX.fullmatch(v):
        return 'hex hash'
    if VERSION.fullmatch(v):
        return 'version string'
    if re.fullmatch(r'\d+(?:[-_.,:/]\d+)+', v):
        return 'number with separators'
    scripts = set()
    for c in v:
        if not c.isalpha():
            continue
        o = ord(c)
        scripts.add('latin' if o < 0x0250 else 'hangul' if 0xAC00 <= o <= 0xD7AF
                    else 'kana' if 0x3040 <= o <= 0x30FF else 'han' if 0x3400 <= o <= 0x9FFF else 'other')
    if len(scripts) > 1:
        return 'mixed-language word'
    if re.fullmatch(r'[A-Za-z]+\d+(?:[-.][A-Za-z0-9]+)*', v):
        return 'word with a digit'
    if re.fullmatch(r'[A-Za-z_]\w*', v) and entropy(v) <= 4.0 and (
            '_' in v or re.search(r'[a-z]{2,}[A-Z][a-z]{2,}', v)):
        return 'code identifier'
    if t.context == 'path':
        return 'path segment'
    if t.context == 'web':
        return 'part of a web address'
    if len(v) >= 20 and B64.fullmatch(v) and entropy(v) >= 3.5:
        return 'base64-like'
    return 'other'


def merge(spans):
    out = []
    for a, b in sorted(set(spans)):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(b, out[-1][1]))
        else:
            out.append((a, b))
    return out


def selected(text, candidate):
    return merge([(t.start, t.end) for t in tokens(text) if candidate.accepts(t.value)])


def covered(spans, start, end):
    return any(a <= start and b >= end for a, b in merge(spans))


def luhn(digits):
    ds = [int(c) for c in digits]
    return sum((d * 2 - 9 if d > 4 else d * 2) if i % 2 else d
               for i, d in enumerate(reversed(ds))) % 10 == 0


class Baseline:
    """Current-rule subset exactly covering the invented corpus vocabulary.

    Extract vendor regexes from current source to avoid a second vendor list.
    Unicode emails, rare glued names and repeated-pass interactions are outside
    this comparison, so this is not a general replacement for the Swift rules.
    """
    def __init__(self):
        source = (ROOT / 'Sources/Core/Redaction.swift').read_text()
        self.source_sha = hashlib.sha256(source.encode()).hexdigest()
        primary = source.split('private static let patterns:', 1)[1].split('].map', 1)[0]
        vendor = source.split('private static let vendorPatterns:', 1)[1].split('].map', 1)[0]
        self.patterns = []
        for block in (primary, vendor):
            for name, pattern in re.findall(r'\("([^"\n]+)",[^\n]*?#"(.*?)"#\)', block):
                if name in ('email', 'wallet-recovery', 'url-credential'):
                    continue
                self.patterns.append((name, re.compile(pattern)))
        self.label = re.compile(
            r'(?:password|passwd|passphrase|passcode|secret(?:[_ -]key)?|api[_ -]?key|token)'
            r'''(?:["'])?\s*[:=：]\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|\S+)''', re.I)
        self.card = re.compile(r'(?<![\w.-])(?:\d[ -]?){12,18}\d(?![\w.-])')

    def opaque(self, value):
        v = value.strip(')]},')
        return len(v) >= 16 and re.fullmatch(r'[A-Za-z0-9_+/.=\-]+', v) is not None and (
            any(c.isalpha() for c in v) and any(c.isdecimal() for c in v) and entropy(v) >= 3.3)

    def ranges(self, text):
        if re.fullmatch(r'[0-9a-fA-F_:\-,]+', text) and re.search(r'[a-fA-F]', text):
            return []
        # JSON values are cleaned recursively, without looking at their keys.
        try:
            value = json.loads(text) if text.startswith(('{', '[')) else None
        except ValueError:
            value = None
        if isinstance(value, (dict, list)):
            # Corpus JSON contains one string value, no escaping in secrets.
            if isinstance(value, dict) and len(value) == 1 and isinstance(next(iter(value.values())), str):
                v = next(iter(value.values()))
                at = text.rfind(json.dumps(v, ensure_ascii=False)) + 1
                return [(at + a, at + b) for a, b in self.ranges(v)]
            raise ValueError('baseline JSON corpus shape unsupported')
        spans = []
        for name, pattern in self.patterns:
            for m in pattern.finditer(text):
                group = 1 if name not in ('private-key', 'github-token', 'api-key', 'aws-key', 'slack-token', 'jwt') and m.lastindex else 0
                spans.append(m.span(group))
        spans.extend(m.span() for m in self.label.finditer(text))
        for m in self.card.finditer(text):
            digits = ''.join(c for c in m.group() if c.isdecimal())
            if 13 <= len(digits) <= 19 and luhn(digits):
                spans.append(m.span())
        for url in re.finditer(r'https?://[^\s]+', text):
            q = re.search(r'[?#]', url.group())
            if q:
                at = url.start() + q.start() + 1
                for m in re.finditer(r'(?:^|[&#;])(?:[^=&#;]*=)?([^&#;]*)', text[at:url.end()]):
                    raw = m[1]
                    decoded = unquote(raw)
                    if self.opaque(raw) or self.opaque(decoded) or (decoded != raw and self.ranges(decoded)):
                        spans.append((at + m.start(1), at + m.end(1)))
        return merge(spans)


def invented_secrets():
    rng = random.Random(50120261014)
    def rand(alphabet, n):
        return ''.join(rng.choice(alphabet) for _ in range(n))
    alnum = string.ascii_letters + string.digits
    urlsafe = alnum + '_-'
    secret_rows = []
    vendors = (
        ('sk-', urlsafe, 40), ('ghp_', alnum, 36), ('AIza', urlsafe, 35),
        ('AKIA', string.ascii_uppercase + string.digits, 16),
        ('sk_live_', alnum, 32), ('glpat-', urlsafe, 28), ('npm_', alnum, 36),
        ('sb_secret_', urlsafe, 32), ('ntn_', alnum, 36), ('cfk_', alnum, 40),
    )
    for prefix, alphabet, n in vendors:
        for _ in range(40):
            secret_rows.append(('known API keys', prefix + rand(alphabet, n)))
    for kind, alphabet in (('unknown API base62', alnum), ('unknown API URL-safe', urlsafe),
                           ('unknown API hex', '0123456789abcdef'),
                           ('unknown API all letters', string.ascii_letters),
                           ('unknown API base64', alnum + '+/')):
        for i in range(200):
            n = rng.randint(20, 64)
            secret_rows.append((kind, rand(alphabet, n)))
    # Include separators in strong passwords to test ambiguity instead of avoiding it.
    for i in range(400):
        n = 12 + i % 13
        chars = list(rand(alnum + '!#$%&*+-_/.=:@', n - 4) + 'aA7!')
        rng.shuffle(chars)
        secret_rows.append(('strong passwords', ''.join(chars)))
    for i in range(200):
        n = 8 + i % 4
        chars = list(rand(string.ascii_letters, n - 2) + 'a7')
        rng.shuffle(chars)
        secret_rows.append(('medium passwords', ''.join(chars)))
    for i in range(80):
        secret_rows.extend((('weak word+digit', ('hunter', 'summer', 'welcome', 'dragon', 'coffee', 'orange', 'rabbit', 'monkey')[i % 8] + str(i // 8)),
                            ('weak all letters', rand(string.ascii_lowercase, 7 + i % 4)),
                            ('weak all digits', rand(string.digits, 7 + i % 4))))
    for _ in range(200):
        secret_rows.append(('private key body line', rand(alnum + '+/', 64)))
    for _ in range(120):
        secret_rows.append(('one-time code', rand(string.digits, 6)))
    for i in range(240):
        if i % 3 == 0:
            v = '-'.join(rand(string.ascii_uppercase + string.digits, 4) for _ in range(4))
        elif i % 3 == 1:
            v = rand(alnum, 16)
        else:
            v = ' '.join(rand(string.digits, 4) for _ in range(3))
        secret_rows.append(('recovery codes', v))
    assert len(secret_rows) >= 2000
    assert len(set(secret_rows)) == len(secret_rows)
    return secret_rows


def placements(secret):
    # 38 equally weighted contexts, with per-language results retained.
    for language, label in LABELS.items():
        for form in ('label', 'JSON', 'assignment', 'URL query'):
            if form == 'label':
                prefix, written, suffix = label + ': ', secret, ''
            elif form == 'JSON':
                prefix, written, suffix = '{' + json.dumps(label, ensure_ascii=False) + ':"', secret, '"}'
            elif form == 'assignment':
                prefix, written, suffix = label + '=', secret, ''
            else:
                prefix, written, suffix = 'https://invented.invalid/read?' + quote(label) + '=', quote(secret, safe=''), ''
            yield form + '/' + language, prefix + written + suffix, len(prefix), len(prefix) + len(written)
    for form, prefix, suffix in (('no label', 'value shown here ', ' end'), ('alone on line', '', '')):
        yield form, prefix + secret + suffix, len(prefix), len(prefix) + len(secret)


def recall_measure(baseline):
    corpus = invented_secrets()
    results = {c.name: defaultdict(lambda: Counter()) for c in CANDIDATES}
    by_context = {c.name: defaultdict(lambda: Counter()) for c in CANDIDATES}
    baseline_results = defaultdict(Counter)
    kind_counts = Counter(kind for kind, _ in corpus)
    for kind, secret in corpus:
        for context, text, start, end in placements(secret):
            old = baseline.ranges(text)
            was_masked = covered(old, start, end)
            baseline_results[kind]['total'] += 1
            baseline_results[kind]['masked'] += was_masked
            ts = list(tokens(text))
            attributes = [(t, entropy(t.value), class_rule(t.value)) for t in ts]
            for c in CANDIDATES:
                spans = merge([(t.start, t.end) for t, h, classes in attributes if c.accepts(t.value, h, classes)])
                alone = covered(spans, start, end)
                plus = covered(old + spans, start, end)
                partial = any(a < end and b > start for a, b in spans) and not alone
                results[c.name][kind].update(total=1, plus=plus, candidate_only=alone, partial=partial)
                by_context[c.name][context].update(total=1, baseline=was_masked, plus=plus)
    return corpus, kind_counts, baseline_results, results, by_context


def word_retention(text, spans):
    words = [m.span() for m in WORD.finditer(text) if m.group() not in MARKS]
    kept = sum(not any(a < end and b > start for a, b in spans) for start, end in words)
    return kept, len(words), kept / len(words) if words else 1.0


def real_measure(db, start, end):
    rows = list(db.execute('SELECT kind,text FROM evidence WHERE ts>=? AND ts<? AND kind IN (\'screen\',\'prompt\') ORDER BY ts,id', (start, end)))
    aggregate = {c.name: {kind: Counter() for kind in ('screen', 'prompt')} for c in CANDIDATES}
    categories = {c.name: {kind: Counter() for kind in ('screen', 'prompt')} for c in CANDIDATES}
    retentions = {c.name: {kind: [] for kind in ('screen', 'prompt')} for c in CANDIDATES}
    corpus_counts = defaultdict(Counter)
    for kind, text in rows:
        corpus_counts[kind].update(rows=1, chars=len(text), lines=len(text.splitlines()) or 1)
        attributes = [(t, entropy(t.value), class_rule(t.value), classify(t)) for t in tokens(text)]
        for c in CANDIDATES:
            matches = [(t, k) for t, h, cls, k in attributes if c.accepts(t.value, h, cls)]
            # URL values may have several qualifying children; count the written span once.
            unique = {}
            for t, k in matches:
                unique.setdefault((t.start, t.end), k)
            spans = merge(list(unique))
            count = aggregate[c.name][kind]
            count.update(tokens=len(unique), rows_touched=bool(spans), chars_masked=sum(b-a for a,b in spans))
            categories[c.name][kind].update(unique.values())
            retentions[c.name][kind].append(word_retention(text, spans))
    return rows, corpus_counts, aggregate, categories, retentions


def semantic_proxy(rows, candidates):
    rng = random.Random(200501)
    samples = []
    for kind in ('screen', 'prompt'):
        population = [text for k, text in rows if k == kind]
        samples.extend((kind, text) for text in rng.sample(population, min(100, len(population))))
    output = {}
    for c in candidates:
        count = {kind: Counter() for kind in ('screen', 'prompt')}
        for kind, text in samples:
            spans = selected(text, c)
            kept, total, fraction = word_retention(text, spans)
            # This is structural triage, deliberately not called a semantic judgment.
            label = 'still clear proxy' if fraction >= .95 else 'less clear proxy' if fraction >= .70 else 'unclear proxy'
            count[kind][label] += 1
        output[c.name] = count
    return len(samples), output


def benchmark(rows):
    rng = random.Random(1000501)
    reservoir, seen = [], 0
    for _, text in rows:
        for line in text.splitlines() or ['']:
            seen += 1
            if len(reservoir) < 1000:
                reservoir.append(line)
            else:
                i = rng.randrange(seen)
                if i < 1000:
                    reservoir[i] = line
    lines = reservoir
    result = {}
    for c in CANDIDATES:
        selected('warmup invented', c)
        timings = []
        for _ in range(5):
            start = time.perf_counter()
            checksum = sum(sum(b-a for a,b in selected(line, c)) for line in lines)
            timings.append((time.perf_counter() - start) * 1000 * 1000 / len(lines))
        result[c.name] = (statistics.median(timings), min(timings), max(timings))
    return result, len(lines), statistics.mean(map(len, lines))


def selfcheck():
    c = next(c for c in CANDIDATES if c.name == 'B16_3.5')
    invented = 'aB7xQ2pL9mR4zT6v'
    assert c.accepts(invented)
    ascii_candidate = next(c for c in CANDIDATES if c.name == 'B16_4_ASCII')
    assert ascii_candidate.accepts(invented)
    assert not ascii_candidate.accepts(invented + '한')
    assert not ascii_candidate.accepts('日本語文章読書作業記録確認試験設計実装2026!')
    assert not c.accepts('documentation')
    assert not c.accepts('longMeaningfulIdentifierName')
    text = 'https://invented.invalid/read/' + invented + '/notes?v=' + invented
    spans = selected(text, c)
    assert sum(b-a for a,b in spans) == 2 * len(invented)
    assert covered(spans, text.index(invented), text.index(invented) + len(invented))
    assert covered(selected('/read/' + invented + '/notes', c), 6, 6 + len(invented))
    assert classify(Token(0,36,'01234567-89ab-cdef-0123-456789abcdef')) == 'UUID'
    assert classify(Token(0,16,'0123456789abcdef')) == 'hex hash'
    assert classify(Token(0,16,'meaningful_name2')) == 'code identifier'
    baseline = Baseline()
    assert covered(baseline.ranges('password: hunter2'), 10, 17)
    assert not baseline.ranges('비밀번호: hunter2')
    assert not baseline.ranges('{"password":"hunter2"}')
    assert baseline.ranges('ghp_' + invented * 2)
    assert not baseline.ranges(invented)
    assert baseline.ranges('https://invented.invalid/read?v=' + invented)
    assert baseline.ranges('-----BEGIN PRIVATE KEY-----\n' + invented + '\n-----END PRIVATE KEY-----')
    assert baseline.ranges('eyJ' + invented + '.' + invented + '.' + invented)
    assert baseline.ranges('4111 1111 1111 1111')
    for label in LABELS.values():
        text = label + ': ' + invented
        assert covered(selected(text, c), len(label)+2, len(text))
    assert not selected('[secret] [email] [redacted]', c)
    encoded = quote(invented + '/abc', safe='')
    text = 'https://invented.invalid/read?v=' + encoded
    assert covered(selected(text, c), len(text)-len(encoded), len(text))
    e = next(c for c in CANDIDATES if c.name == 'E16_3')
    text = 'https://invented.invalid/read?longReadableParameterName=' + invented
    assert selected(text, e) == [(len(text)-len(invented), len(text))]
    return baseline


def pct(n, d):
    return 100*n/d if d else 0.0


def quantile(xs, p):
    v = sorted(xs)
    return v[round((len(v)-1)*p)] if v else 1.0


def choose(aggregate, recall):
    # A declared preference, not an inferred privacy ground truth: prioritize long
    # unknown keys and detached private-key bodies, then strong-password recall.
    scored = []
    for c in CANDIDATES:
        relevant = [v for k,v in recall[c.name].items() if k.startswith('unknown API') or k == 'private key body line']
        key_recall = sum(v['plus'] for v in relevant)/sum(v['total'] for v in relevant)
        password = recall[c.name]['strong passwords']
        password_recall = password['plus']/password['total']
        masked = sum(v['chars_masked'] for v in aggregate[c.name].values())
        scored.append((c, key_recall, password_recall, masked))
    eligible = [s for s in scored if s[1] >= .99]
    # Strong passwords matter, but 12-char thresholds cause larger code loss.
    preferred = [s for s in eligible if s[0].minimum >= 16 and s[2] >= .55]
    pool = preferred or eligible or scored
    ranked = sorted(pool, key=lambda s: (s[3], -s[2], -s[1]))
    best = ranked[0][0]
    top = [best]
    # Compare broad and conservative tradeoff representatives even if ineligible.
    for name in ('C16', 'B16_4', 'B16_3.5', 'B12_3.5', 'B20_3.5'):
        c = next(c for c in CANDIDATES if c.name == name)
        if c not in top:
            top.append(c)
        if len(top) == 3:
            break
    return best, top, scored


def report_text(start, end, baseline, corpus_counts, aggregate, categories, kind_counts,
                baseline_results, recall, contexts, retentions, recommended, best_three,
                sample_n, sample_counts, timings, line_n, avg_chars, scored):
    lines = [f'RECOMMEND: {recommended.name}', '',
             'Scope: offline candidate measurement; product behavior is checked separately.',
             'Detached private-key body lines are included in the recall measurement.',
             f'Window UTC: {datetime.fromtimestamp(start,timezone.utc).isoformat()} <= ts < {datetime.fromtimestamp(end,timezone.utc).isoformat()}; exactly 14 days.',
             f'Current source SHA256: {baseline.source_sha}', '',
             'TOKEN AND SPLITTING RULES',
             'A parent token is a maximal non-whitespace run. Length and entropy use Unicode code points, not bytes or grapheme clusters.',
             'Quotes, brackets, braces, parentheses, commas, semicolons and backticks delimit child tokens. Trailing periods are trimmed as sentence punctuation; other edge symbols remain.',
             'Recognized http/https URLs retain the scheme, entire host and parameter names, split path children at / . : = @ ? & #, and inspect query values separately.',
             'Query percent escapes are decoded once in memory. Any selected child masks the entire original written query value, retaining the key. This can mask readable words sharing that value.',
             'Filesystem paths beginning / ./ ../ ~/ are split at / . : = @ ? & #; relative slash paths split when a readable directory is present. High-entropy base64-like relative runs containing a digit or + remain whole so detached key bodies survive slash separators.',
             'In plain text, one low-entropy letter/underscore/hyphen label followed by : or = splits from its value. Otherwise inner / . = : @ stay within the token, including base64 padding.',
             'Dot-separated bare hosts with a letter-only last label and a slash are parsed as URLs. Unusual prose names may be mistaken for labels; a secret ending in a period is partly missed. A base64 line starting / is interpreted as an absolute path and may be only partly hidden. Hosts and subdomain IDs are intentionally retained.',
             'Masks are spans, counted once per distinct written span; overlapping spans merge for character and word totals. Existing mask words are excluded.',
             'This is more than a regex over whitespace runs: preserving domain/path meaning requires structural splitting, while random base64 bodies require a competing no-split rule.', '',
             'GRID (13 candidates; ASCII extension)',
             'Class rule: >=2 of Unicode lower / upper / decimal digit / non-alphanumeric symbol, and >=1 digit or symbol. Uncased letters do not by themselves count as lower or upper.',
             'B16_4_ASCII adds an all-characters U+0021 through U+007E condition to B16_4; whitespace already delimits parent runs.',
             'Entropy: plug-in Shannon bits per character, sum -p*log2(p); >= bound. BOTH applies class and entropy tests.',
             'name | minimum | test | entropy bound']
    lines.extend(f'{c.name} | {c.minimum} | {c.mode} | {c.bound:g} | ASCII-only={c.ascii_only}' for c in CANDIDATES)
    lines += ['', 'REAL CORPUS TOTALS', 'kind | rows | chars | lines']
    for k in ('screen','prompt'):
        v=corpus_counts[k]
        lines.append(f"{k} | {v['rows']} | {v['chars']} | {v['lines']}")
    lines += ['', 'Classification is shape/context only, mutually exclusive in the listed precedence, not a secret/non-secret truth label.',
              'Precedence: UUID, hex, version, separator-number, mixed scripts, word+digit, low-entropy camel/snake code, path, web, base64-like, other.',
              'Base64-like means >=20 characters in its alphabet and entropy >=3.5; it is not validated decoding. Hex includes all-digit runs. Code checks use <=4 bits/character, underscores or a camel hump.',
              'Kind counts must not be read as precision; real stored text was already redacted, has repeats, and may still contain unknown secrets.']
    for c in CANDIDATES:
        lines += ['', f'CANDIDATE {c.name}', 'REAL: kind | tokens | rows touched | chars masked | percent of all chars']
        for k in ('screen','prompt'):
            v=aggregate[c.name][k]
            lines.append(f"{k} | {v['tokens']} | {v['rows_touched']} | {v['chars_masked']} | {pct(v['chars_masked'],corpus_counts[k]['chars']):.4f}%")
        lines.append('REAL KINDS: class | screen count | prompt count')
        for k in KINDS:
            lines.append(f'{k} | {categories[c.name]["screen"][k]} | {categories[c.name]["prompt"][k]}')
        lines.append('RECALL: secret kind | unique secrets | placements | today masked count/% | today+candidate count/% | candidate-only % | partial-only %')
        for k,n in kind_counts.items():
            v=recall[c.name][k]; b=baseline_results[k]; d=v['total']
            lines.append(f"{k} | {n} | {d} | {b['masked']}/{pct(b['masked'],d):.3f}% | {v['plus']}/{pct(v['plus'],d):.3f}% | {pct(v['candidate_only'],d):.3f}% | {pct(v['partial'],d):.3f}%")
        lines.append('CONTEXT RECALL: context | placements | today % | today+candidate %')
        for context,v in contexts[c.name].items():
            lines.append(f"{context} | {v['total']} | {pct(v['baseline'],v['total']):.3f}% | {pct(v['plus'],v['total']):.3f}%")
    lines += ['', 'INVENTED CORPUS AND BASELINE LIMITS',
              f'{sum(kind_counts.values())} unique generated secrets; 38 placements each; seeded random generator. These are invented strings, not live credentials.',
              'Known-key corpus: 10 current prefix families, 40 each. Unknown base62, URL-safe, hexadecimal, all-letter and base64 keys are separate, 200 each, lengths 20-64.',
              'Strong passwords: 400, lengths 12-24 with all four classes and punctuation including / . = : @. Medium: 200, lengths 8-11, letters+digits. Weak: 80 each word+digit/all-letters/all-digits, length 7-10 except word choice.',
              'Detached private-key bodies: 200, length 64, base64 alphabet; no BEGIN/END lines. OTP: 120, 6 digits. Recovery: 240, evenly split 4x4 hyphen blocks, 16-char alphanumeric, and spaced 3x4 digit groups.',
              'English/Korean/Japanese/Simplified Chinese/Traditional Chinese/German/French/Spanish/Portuguese labels are applied in plaintext, JSON, assignment and URL query; no-label and alone-on-line add two contexts.',
              'The controlled label is the translation of password for every kind, not a survey of all label nouns: password / 비밀번호 / パスワード / 密码 / 密碼 / Passwort / mot_de_passe / contraseña / senha. Baseline recall therefore reflects that chosen label, not every real API/recovery/private-key field name.',
              'Recall requires the entire secret span covered. Partial masking is not a success; plus can combine adjacent/overlapping baseline and candidate spans. Repetitions across contexts are not independent trials.',
              'TODAY BASELINE IS A CORPUS-SPECIFIC PYTHON TRANSLATION, NOT SWIFT-ENGINE-VERIFIED. Vendor patterns are read from current source; label, JSON value recursion, identifier exemption, Luhn and URL entropy behavior are reproduced for this corpus.',
              'It omits Unicode-email/rare glued-label/repeated-pass interactions irrelevant to generated labels, but punctuation/order interactions could still shift current-rule recall. This Python measurement itself runs no Swift engine.',
              'Current whole-JSON recursion cleans values without looking at their label keys; weak English JSON values therefore remain readable. Current query opacity already masks many random values (>=16, letters+digits, entropy>=3.3, restricted alphabet).', '',
              'WORDS LEFT AND MEANING LOSS (three comparison finalists)',
              r'Word = Unicode \w+ run, excluding old mask words. Any overlap marks that whole original word lost; denominator includes hashes/IDs/code as words, so this is a conservative readability proxy.',
              'Every evidence row contributes a fraction, including untouched rows. Zero-word rows have fraction 1. Quantiles below are of per-row fractions, not pooled text.',
              'candidate | kind | mean words left % | pooled words left % | p05 % | p50 % | p95 % | <70% rows | 70-95% rows | >=95% rows']
    for c in best_three:
        for k in ('screen','prompt'):
            entries=retentions[c.name][k]; xs=[v[2] for v in entries]
            lines.append(f'{c.name} | {k} | {100*statistics.mean(xs):.4f} | {pct(sum(v[0] for v in entries),sum(v[1] for v in entries)):.4f} | {100*quantile(xs,.05):.4f} | {100*quantile(xs,.50):.4f} | {100*quantile(xs,.95):.4f} | {sum(v<.7 for v in xs)} | {sum(.7<=v<.95 for v in xs)} | {sum(v>=.95 for v in xs)}')
    lines += [f'Sample: {sample_n} rows, seeded stratified selection, 100 screen and 100 prompt, in memory only.',
              'SEMANTIC HUMAN JUDGMENT NOT MEASURED. Under no real-text console output/no model calls, this run cannot honestly read and judge activity meaning; these counts are structural proxies only, not judgments that the activity remains clear.',
              'Proxy bins: >=95% original words left = still-clear proxy; 70-95% = less-clear proxy; <70% = unclear proxy. Thresholds are chosen, not validated.',
              'candidate | kind | still-clear proxy | less-clear proxy | unclear proxy']
    for c in best_three:
        for k in ('screen','prompt'):
            v=sample_counts[c.name][k]
            lines.append(f"{c.name} | {k} | {v['still clear proxy']} | {v['less clear proxy']} | {v['unclear proxy']}")
    lines += ['', 'COST', f'Reservoir of {line_n} real lines, mean {avg_chars:.2f} characters, held in memory; 5 sequential passes per candidate, end-to-end tokenization + detection + merge, no cache, no database work included.',
              'candidate | median ms per 1000 lines | min | max']
    for c in CANDIDATES:
        med,lo,hi=timings[c.name]
        lines.append(f'{c.name} | {med:.3f} | {lo:.3f} | {hi:.3f}')
    lines += ['Swift caveat: entropy needs a character histogram outside NSRegularExpression. Scan each token once; prefilter length, compute class flags, then entropy only for eligible tokens. Do not try entropy via lookahead regexes.',
              'ICU regex costs rise with unbounded nested quantifiers, lookarounds rescanning long runs, searching every start position in a failed path, and repeated replacements that copy the entire string. Use one linear scanner, precompiled expressions, disjoint ranges and one output pass.',
              'Unicode grapheme iteration / UTF-16 range conversion and repeatedly decoding URL escapes add overhead. Python timings do not predict Swift latency; no Swift-engine timing or worst-case bound was measured.', '',
              'RECOMMENDATION AND ACCEPTED ERRORS',
              f'Prefer {recommended.name} as the provisional implementation experiment, not a final safety guarantee. Selection requires >=99% aggregate full recall on unknown API keys plus detached key bodies, minimum >=16 and >=55% strong-password recall, then minimizes real characters masked among qualifying candidates.',
              'The three comparison finalists represent broad entropy coverage, class-only coverage and strict combined coverage; they are tradeoff representatives, not a model-scored semantic ranking.',
              'Selection inputs: candidate | unknown-key/body recall % | strong-password recall % | real chars masked']
    for c,key,pw,chars in scored:
        lines.append(f'{c.name} | {100*key:.3f} | {100*pw:.3f} | {chars}')
    lines += ['Accepted harmless masks: long readable words (including uncased-language words), hashes, UUIDs, random resource/session IDs, varied code identifiers, version/numeric strings and path/query parts. Exact real kind counts above quantify exposure, not confirmed harmlessness.',
              'Accepted misses: medium/weak passwords and OTPs without today\'s recognizable labels; shorter strong passwords below the selected length; spaced recovery codes; punctuation-split secrets; low-entropy repetitive long values; long all-letter values for class-based candidates; secrets embedded in preserved hosts/subdomains.',
              'Corpus kinds are deliberately balanced stress cases, not estimates of secret prevalence. A minimum 16 cannot cover every 12-15-character strong password. Entropy-only rules can hide ordinary uncased/mixed-language words. Class-only rules overmask long readable identifiers; entropy bounds trade that loss against missed secrets.',
              'A semantic 200-row judgment and exact production-engine baseline verification remain outstanding. Make those checks before treating this provisional recommendation as accepted product behavior.',
              'Privacy: single backup read through mode=ro&immutable=1; only evidence kind/text selected; no titles, addresses, source identifiers or file metadata selected. No raw samples written, displayed or modeled.',
              'Cleanup contract: the caller must delete /tmp/ap-mask-shape/ before final delivery; only this count-only report and the script may remain.',
              'Script: tools/measure_mask_shape.py; compare the Swift tokenizer with tools/verify_mask_shape.py; no push or merge.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--temp-root', type=Path, choices=(Path('/tmp/ap-mask-shape'), Path('/tmp/ap-mask-impl'), Path('/tmp/ap-mask-fix')), default=TEMP)
    parser.add_argument('--end-utc', help='ISO UTC timestamp, default backup completion time')
    args = parser.parse_args()
    baseline = selfcheck()
    if args.self_check:
        print('Invented tokenizer, classifier and baseline checks passed; no database opened.')
        return
    temp = args.temp_root
    dbpath = temp / 'copy.sqlite'
    if not dbpath.is_file():
        raise SystemExit('Single authorized database backup is required.')
    end = int(datetime.fromisoformat(args.end_utc.replace('Z','+00:00')).timestamp()) if args.end_utc else int(dbpath.stat().st_mtime)
    start = end - 14*86400
    db = sqlite3.connect(f'file:{dbpath}?mode=ro&immutable=1', uri=True)
    try:
        rows,counts,aggregate,categories,retentions=real_measure(db,start,end)
    finally:
        db.close()
    if not all(counts[k]['rows'] >= 100 for k in ('screen','prompt')):
        raise SystemExit('Insufficient rows for the requested stratified 200-row sample.')
    corpus,kind_counts,old,recall,contexts=recall_measure(baseline)
    rec,top,scored=choose(aggregate,recall)
    n,samples=semantic_proxy(rows,top)
    timings,line_n,avg_chars=benchmark(rows)
    report=report_text(start,end,baseline,counts,aggregate,categories,kind_counts,old,recall,contexts,
                       retentions,rec,top,n,samples,timings,line_n,avg_chars,scored)
    # An aggregate-only temporary result; caller performs cleanup and single final write.
    (temp/'count-report.txt').write_text(report)
    print(json.dumps({'recommended':rec.name,'rows':{k:v['rows'] for k,v in counts.items()},
                      'invented_secrets':len(corpus),'placements':sum(v['total'] for v in old.values()),
                      'sample_rows':n,'semantic_review':'not measured; structural proxy only'},sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Do not let an exception repr accidentally expose evidence text.
        raise SystemExit('Measurement failed; no raw exception or evidence emitted.') from None
