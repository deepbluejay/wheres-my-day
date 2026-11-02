#!/usr/bin/env python3
"""Invented fixtures only; never opens default recorder or agent-log locations."""

import ast
from collections import Counter, defaultdict
from contextlib import closing, contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import errno
import io
from itertools import chain
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
import unittest
from unittest.mock import patch

import fidelity_check as fc
SWIFTPM = str(Path(__file__).with_name("swiftpm"))  # names the build system; see that file


START = 1969660800  # Invented aligned UTC day in 2032.
SAMPLE_INSERT = ("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) "
                 "VALUES(?,?,?,?,?,?,?,?,0,0,0,0)")
EVIDENCE_INSERT = "INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(?,?,?,?,'','',?)"
BODY = "Invented instruction with enough separate words to compare its provenance safely"


def last_write(path, stamp):
    """Invented lines are dated in the future; a log file's mtime is its last write."""
    os.utime(path, (stamp, stamp))


def sql_bound_violations(sql):
    """Parse SQL calls and CASE branches; an AND size test grants no guard."""
    tokens = re.findall(r"'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|[A-Za-z_]\w*|\d+|<=|>=|<>|[().,?=<>*]", sql)
    tokens = [token.lower() if not token.startswith(("'", '"')) else token for token in tokens]
    keywords = {'case', 'when', 'then', 'else', 'end', 'in', 'exists', 'select', 'values', 'on', 'key', 'over', 'and', 'or', 'not', 'conflict'}
    metadata = {'typeof', 'octet_length', 'coalesce', 'ifnull', 'nullif', 'count'}
    # Only tool-owned numeric state has an aggregate exemption. Source columns
    # with the same names can still contain oversized text in SQLite.
    numeric_state = {'instructions': {'id'}, 'input_keys': {'ts'}, 'votes': {'n'}, 'text_lines': {'rowid'}, 'activity_signals': {'ts'},
                     'session_apps': set(), 'clicks': {'capacity'}, 'input_seconds': {'app', 'window', 'document'},
                     'recall': {'weighted_found', 'weighted_total', 'found', 'total'}}
    tables = {tokens[i + 1].strip('"') for i, part in enumerate(tokens[:-1])
              if part in {'from', 'join', 'into', 'update'} and tokens[i + 1] not in {'select', '(', 'set'}}
    numeric = set().union(*(numeric_state.get(table, set()) for table in tables))
    violations, branches = [], []
    for index, token in enumerate(tokens):
        if token == 'case':
            branches.append({'start': index + 1, 'guards': set()})
        elif token == 'when' and branches:
            branches[-1] = {'start': index + 1, 'guards': set()}
        elif token == 'then' and branches:
            condition = tokens[branches[-1]['start']:index]
            for offset in range(len(condition) - 5):
                if condition[offset:offset + 2] != ['octet_length', '(']:
                    continue
                close = offset + 2
                while close < len(condition) and condition[close] != ')':
                    close += 1
                if (condition[close:close + 2] == [')', '<='] and close + 2 < len(condition)
                        and offset == 0 and close + 3 == len(condition)
                        and condition[close + 2].isdigit() and int(condition[close + 2]) <= fc.MAX_TEXT_FIELD):
                    branches[-1]['guards'].add(tuple(condition[offset + 2:close]))
        elif token == 'else' and branches:
            branches[-1]['guards'] = set()
        elif token == 'end' and branches:
            branches.pop()
        function = token.strip('"').lower()
        if index + 1 >= len(tokens) or tokens[index + 1] != '(' or function in keywords | metadata:
            continue
        if not re.fullmatch(r'[a-z_]\w*', function):
            continue
        # CREATE/INSERT table and index declarations are not function calls.
        if index and tokens[index - 1] in {'table', 'into', 'index', 'exists'}:
            continue
        if index and tokens[index - 1] == 'on' and 'index' in tokens[max(0, index - 5):index]:
            continue
        depth, close = 1, index + 2
        while close < len(tokens) and depth:
            depth += (tokens[close] == '(') - (tokens[close] == ')')
            close += 1
        args = tokens[index + 2:close - 1]
        if re.fullmatch(r'__fidelity_octets_[a-f0-9]{16}', function) and args == ['rowid']:
            continue
        columns = []
        pos = 0
        while pos < len(args):
            part = args[pos]
            if ((re.fullmatch(r'[a-z_]\w*', part) and part not in keywords | {'null', 'text', 'blob'})
                    or part.startswith('"')):
                if pos + 1 < len(args) and args[pos + 1] == '(':
                    pos += 1
                    continue
                column = [part]
                while pos + 2 < len(args) and args[pos + 1] == '.':
                    column += args[pos + 1:pos + 3]
                    pos += 2
                columns.append(tuple(column))
            pos += 1
        if (function in {'min', 'max', 'sum'} and tables and tables <= numeric_state.keys()
                and all(col[-1].strip('"') in numeric for col in columns)):
            continue
        guards = set().union(*(branch['guards'] for branch in branches))
        if any(column not in guards for column in columns):
            violations.append(token + '(' + ''.join(args) + ')')
    return violations


def sql_source_strings(source):
    """Render every SQL literal/template, including dynamically joined fragments."""
    tree = ast.parse(source)
    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
    def render(node):
        if isinstance(node, ast.Constant):
            return str(node.value) if isinstance(node.value, (str, int)) else ''
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return render(node.left) + render(node.right)
        if isinstance(node, ast.JoinedStr):
            return ''.join(render(value.value) if isinstance(value, ast.FormattedValue) else render(value) for value in node.values)
        if isinstance(node, ast.Name) and node.id == 'MAX_TEXT_FIELD':
            return str(fc.MAX_TEXT_FIELD)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            if node.func.id == 'guarded_text':
                args = [render(arg) for arg in node.args]
                return fc.guarded_text(*args)
            if node.func.id == 'quoted':
                return fc.quoted(render(node.args[0]))
        return 'dynamic_column'
    with closing(sqlite3.connect(':memory:')) as catalog:
        functions = '|'.join(re.escape(row[0]) for row in catalog.execute('PRAGMA function_list'))
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Constant, ast.JoinedStr, ast.BinOp)):
            continue
        parent = parents.get(node)
        if isinstance(parent, (ast.JoinedStr, ast.FormattedValue, ast.BinOp)):
            continue
        # Lint the guard generator through its actual output below, since its
        # arguments are SQL fragments rather than input columns.
        ancestor = node
        while ancestor in parents and not isinstance(ancestor, (ast.FunctionDef, ast.AsyncFunctionDef)):
            ancestor = parents[ancestor]
        if isinstance(ancestor, ast.FunctionDef) and ancestor.name == 'guarded_text':
            continue
        sql = render(node)
        if (re.search(r'\b(?:select|where|join|order by|group by|case|and|or|having|set)\b', sql, re.I)
                or re.search(r'\b(?:' + functions + r')\s*\(', sql, re.I)):
            yield node.lineno, sql
    yield 0, 'SELECT ' + fc.bounded_columns(['invented_text'])
    for function in ('substr', 'length', 'julianday', 'lower', 'trim'):
        yield 0, 'SELECT ' + fc.guarded_text(function, 'invented_text')


@contextmanager
def plain_copy(database):
    """Tests measure a frozen copy of their invented database; only the tool's own open is under test."""
    with tempfile.TemporaryDirectory(prefix="fidelity-test-copy-") as folder:
        target = Path(folder) / "copy.sqlite"
        with closing(sqlite3.connect(Path(database).absolute().as_uri() + "?mode=ro", uri=True)) as source, closing(sqlite3.connect(target)) as dest:
            source.backup(dest)
        db = sqlite3.connect(target.as_uri() + "?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA query_only=ON")
            yield db
        finally:
            db.close()


_schema_folder = None


def current_schema_database():
    """An empty invented database made by the product's own Storage code, once per test run.

    There is no stored copy of the schema to go stale: a table or column the tool
    reads that moves or changes makes its tests fail on the next run. Workers inherit
    the built database through the environment.
    """
    global _schema_folder
    built = os.environ.get("FIDELITY_SCHEMA_DATABASE")
    if built:
        return Path(built)
    repository = Path(__file__).resolve().parents[1]
    _schema_folder = tempfile.TemporaryDirectory(prefix="fidelity-schema-")
    folder = Path(_schema_folder.name)
    subprocess.run([SWIFTPM, "build", "--jobs", "1", "--target", "Storage"], cwd=repository, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1200)
    debug = Path(subprocess.check_output([SWIFTPM, "build", "--jobs", "1", "--show-bin-path"], cwd=repository, text=True).strip())
    objects = sorted((debug / "Core.build").glob("*.o")) + sorted((debug / "Storage.build").glob("*.o"))
    subprocess.run(["swiftc", "-I", str(debug / "Modules"), str(repository / "tools/fidelity_schema_fixture.swift"),
                    *map(str, objects), "-lsqlite3", "-o", str(folder / "fixture")], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    subprocess.run([str(folder / "fixture"), str(folder)], check=True, timeout=120, env=dict(os.environ, HOME=str(folder)))
    with closing(sqlite3.connect(folder / "invented.sqlite")) as db:
        # Tests open their own copy with a plain journal; test_wal_inputs covers the live mode.
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
        db.execute("PRAGMA journal_mode=DELETE").fetchall()
    os.environ["FIDELITY_SCHEMA_DATABASE"] = str(folder / "invented.sqlite")
    return folder / "invented.sqlite"


class FidelityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fidelity-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.database = self.root / "invented.sqlite"
        shutil.copyfile(current_schema_database(), self.database)
        self.db = sqlite3.connect(self.database)
        self.addCleanup(self.db.close)
        self.homes = {"claude": [self.root / "claude"], "codex": [self.root / "codex"]}

    def sample(self, offset, keys=1, app="invented.app", window="invented window", document="invented document", clicks=0, scrolls=0):
        self.db.execute(SAMPLE_INSERT, (START + offset, app, app, window, document, keys, clicks, scrolls))

    def logs(self, tool, lines, stem="invented-session", subagent=False):
        folder = self.homes[tool][0] / ("projects" if tool == "claude" else "sessions")
        if subagent:
            folder = folder / "subagents"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / (stem + ".jsonl")
        path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
        last_write(path, max((line["timestamp"] for line in lines if isinstance(line.get("timestamp"), (int, float))), default=START))
        return path

    def claude(self, offset=10, body=BODY, **fields):
        return dict(type="user", timestamp=START + offset, sessionId="invented-session",
                    uuid="invented-" + str(offset), message={"content": body}, **fields)

    def codex(self, offset=10, **fields):
        payload = dict(type="item_completed", thread_id="invented-session", turn_id="invented-turn-" + str(offset),
                       item={"type": "UserMessage", "id": "invented-item", "content": [{"type": "text", "text": BODY}]})
        payload.update(fields)
        return dict(type="event_msg", timestamp=START + offset, payload=payload)

    def settle_logs(self, end):
        # A file a test wrote without a date looks ten years stale beside its 2032 lines.
        for home in chain.from_iterable(self.homes.values()):
            for path in Path(home).rglob("*.jsonl"):
                if path.stat().st_mtime < START - 10 * 86400:
                    last_write(path, START + end)

    def report(self, end=180, references=None, reference=None):
        self.db.commit()
        self.settle_logs(end)
        with plain_copy(self.database) as copy:
            if reference is not None:
                with fc.reference_snapshot(reference) as other:
                    return fc.analyze(copy, self.homes, START, START + end, references=references, reference=other)
            return fc.analyze(copy, self.homes, START, START + end, references=references)

    def metric(self, report, name, tool=None):
        return next(r for r in report["measurements"] if r["metric"] == name and r["tool"] == tool)

    def evidence(self, offset, source_id, body=BODY, source="invented-session"):
        self.db.execute(EVIDENCE_INSERT, (START + offset, "prompt", source, source_id, body))

    def test_fixture_is_the_schema_the_product_declares(self):
        declared = re.search(r"static let schemaVersion = (\d+)",
                             (Path(__file__).resolve().parents[1] / "Sources/Storage/Schema.swift").read_text())[1]
        self.assertEqual(self.report()["schema_version"], int(declared))

    def test_absent_channels_say_so(self):
        for table in ("git_repositories", "log_recording_history", "screen_payloads", "ax_probe_attempts"):
            self.db.execute("DROP TABLE " + table)
        report = self.report()
        for metric in ("unexplained_gap_seconds", "commits_recorded", "screen_occurrences_with_text"):
            row = self.metric(report, metric)
            self.assertIn("channel absent", row["reason"])
            self.assertIsNone(row["ratio"])
            self.assertIsNone(row["denominator"])

    def test_c1_marker_denominator_includes_missing_keys(self):
        self.logs("claude", [self.claude(i, body=f"short request {i}", promptSource="typed") for i in (10, 20, 30)])
        self.sample(9)
        self.sample(21)
        row = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 3))
        self.assertAlmostEqual(row["ratio"], 2 / 3)

    def test_c1_unknown_app_never_uses_unrelated_keys(self):
        self.logs("claude", [self.claude(promptSource="typed")])
        self.sample(10)
        row = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (0, 1))

    def test_codex_input_inference_and_prompt_identity(self):
        self.logs("codex", [{"type": "session_meta", "payload": {"id": "invented-session", "originator": "invented-client"}},
                            self.codex(10), self.codex(20)])
        for i in (10, 20):
            self.sample(i)
            self.evidence(i, f"codex:invented-session:invented-turn-{i}:invented-item")
        report = self.report()
        for metric in ("typed_instructions_with_keys", "typed_instructions_stored"):
            row = self.metric(report, metric, "codex")
            self.assertEqual((row["numerator"], row["denominator"]), (2, 2))

    def test_c2_masked_identity_and_mismatch(self):
        self.logs("claude", [self.claude(10, promptSource="typed"), self.claude(20, promptSource="typed"),
                             self.claude(30, body="short other request", promptSource="typed")])
        self.evidence(11, "claude:invented-10", "[redacted]")
        self.evidence(20, "claude:invented-20")
        self.evidence(30, "claude:unrelated", "unrelated invented body")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 3))
        self.assertEqual(row["equal_digest"], 1)
        self.assertEqual(row["identity_matched_content_changed"], 1)

    def test_c2_wrong_source_and_time_rejected(self):
        self.logs("claude", [self.claude(promptSource="typed")])
        self.evidence(10, "claude:invented-10", source="invented-other-session")
        self.evidence(12, "claude:invented-10")
        self.assertEqual(self.metric(self.report(), "typed_instructions_stored", "claude")["numerator"], 0)

    def test_c2_digest_fallback_for_legacy_identity(self):
        self.logs("claude", [self.claude(promptSource="typed")])
        self.evidence(10, "claude:legacy:invented-old-identity")
        self.assertEqual(self.metric(self.report(), "typed_instructions_stored", "claude")["numerator"], 1)

    def test_marker_priority_over_provenance(self):
        self.logs("claude", [{"type": "assistant", "timestamp": START + 1, "sessionId": "invented-parent",
                              "message": {"content": [{"type": "tool_use", "input": {"prompt": BODY}}]}}], stem="invented-parent")
        self.logs("claude", [self.claude(promptSource="typed")])
        self.assertEqual(self.report()["classifications"], {"human": 1})

    def test_provenance_priority_over_keys(self):
        self.logs("claude", [{"type": "assistant", "timestamp": START + 1, "sessionId": "invented-parent",
                              "message": {"content": [{"type": "tool_use", "input": {"prompt": BODY}}]}}], stem="invented-parent")
        self.logs("codex", [self.codex(10), self.codex(20)])
        self.sample(10)
        self.sample(20)
        self.assertEqual(self.report()["classifications"], {"agent": 2})

    def test_received_command_output_establishes_provenance(self):
        self.logs("claude", [{"type": "assistant", "timestamp": START + 11, "sessionId": "invented-parent",
                              "message": {"content": [{"type": "tool_use", "input": {"prompt": BODY}}]}}], stem="invented-parent")
        self.logs("codex", [dict(type="event_msg", timestamp=START + 10,
                                 payload={"type": "user_message", "message": "Invented short setup"}),
                            dict(type="response_item", timestamp=START + 11,
                                 payload={"type": "function_call", "name": "exec_command", "call_id": "invented-command",
                                          "arguments": "invented command"}),
                            dict(type="response_item", timestamp=START + 12,
                                 payload={"type": "function_call_output", "call_id": "invented-command", "output": BODY})])
        self.assertEqual(self.report()["classifications"], {"agent": 1})

    def test_future_call_and_same_session_do_not_establish_provenance(self):
        self.logs("claude", [self.claude(), {"type": "assistant", "timestamp": START + 20,
                             "sessionId": "invented-parent", "message": {"content": [{"type": "tool_use", "input": {"prompt": BODY}}]}}])
        self.assertEqual(self.report()["classifications"], {"unknown": 1})

    def test_markers_exclude_agents_imports_and_notifications(self):
        self.logs("claude", [self.claude(10, isSidechain=True, promptSource="typed"),
                             self.claude(20, isMeta=True, origin={"kind": "human"}),
                             self.claude(30, body="<task-notification>Invented notification")])
        self.logs("codex", [self.codex(40, turn_id="external-import-turn-invented"),
                            self.codex(50, parent_thread_id="invented-parent")])
        self.assertEqual(self.report()["classifications"], {"agent": 2, "non_instruction": 2, "imported": 1})

    def test_queued_delivery_deduplicated_and_not_typed(self):
        self.logs("claude", [{"type": "queue-operation", "operation": "enqueue", "timestamp": START + 10,
                              "commandUuid": "invented-queue", "content": BODY},
                             {"type": "attachment", "timestamp": START + 30, "attachment": {
                                 "type": "queued_command", "source_uuid": "invented-queue", "humanTurn": True, "prompt": BODY}},
                             self.claude(31, promptSource="queued")])
        report = self.report()
        self.assertEqual(report["classifications"], {"human_queued": 1})
        self.assertEqual(self.metric(report, "typed_instructions_with_keys", "claude")["denominator"], 0)

    def test_subagent_path_marker(self):
        self.logs("claude", [self.claude(promptSource="typed")], subagent=True)
        self.assertEqual(self.report()["classifications"], {"agent": 1})

    def test_short_instructions_fall_through_to_keys(self):
        self.logs("claude", [self.claude(10, body="Invented yes"), self.claude(20, body="Invented next")])
        self.sample(10)
        self.sample(20)
        self.assertEqual(self.report()["classifications"], {"human": 2})

    def test_session_app_thresholds_and_origin_fallback(self):
        candidates, keys = [], defaultdict(set)
        for session in range(5):
            for index in range(2):
                stamp = session * 10 + index
                keys[stamp].add("invented-app-digest")
                candidates.append(fc.Instruction("codex", str(session), "invented-origin", stamp, "s", "i", "b", 1))
        candidate = fc.Instruction("codex", "new-session", "invented-origin", 100, "s", "i", "b", 1)
        candidates.append(candidate)
        fc.infer_apps(candidates, keys)
        self.assertEqual(candidate.app, "invented-app-digest")
        candidates.pop(0)
        candidate.app = ""
        fc.infer_apps(candidates, keys)
        self.assertEqual(candidate.app, "")

    def test_app_dominance_80_percent(self):
        for minority, expected in ((1, "a"), (2, "")):
            with self.subTest(minority=minority):
                cs = [fc.Instruction("claude", "session", "origin", i * 10, "s", "i", "b", 1) for i in range(5)]
                keys = {i * 10: {"a" if i < 5 - minority else "b"} for i in range(5)}
                fc.infer_apps(cs, keys)
                self.assertEqual(cs[0].app, expected)

    def test_c3_input_seconds_not_samples_and_all_input_types(self):
        self.sample(10, keys=0, clicks=1, window="", document="")
        self.sample(10, keys=0, scrolls=1, window="invented present", document="")
        self.sample(20, keys=0, scrolls=1, app="", window="", document="")
        self.sample(30, keys=0, app="", window="", document="")
        report = self.report()
        self.assertEqual(self.metric(report, "input_seconds_missing_app")["numerator"], 1)
        self.assertEqual(self.metric(report, "input_seconds_missing_window")["numerator"], 1)
        self.assertEqual(self.metric(report, "input_seconds_missing_document")["numerator"], 2)
        row = self.metric(report, "input_seconds_missing_any_attribution")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 2))

    def gap(self, **kwargs):
        return self.metric(self.report(**kwargs), "unexplained_gap_seconds")

    def test_c3_rest_after_input_is_not_loss(self):
        # One input, then the recorder rests 300 s later by design; the window runs well past it.
        for offset in range(0, 301):
            self.sample(offset, keys=int(offset == 0))
        self.sample(5000, keys=0)
        row = self.gap(end=6000)
        self.assertEqual((row["numerator"], row["denominator"]), (0, 301))

    def test_c3_missing_second_after_input_is_counted(self):
        for offset in (*range(0, 100), *range(130, 301)):
            self.sample(offset, keys=int(offset == 0))
        row = self.gap(end=1000)
        self.assertEqual((row["numerator"], row["denominator"]), (30, 301))
        self.assertEqual((row["gap_runs"], row["longest_gap_seconds"], row["gap_runs_over_5_seconds"]), (1, 30, 1))
        self.assertFalse(row["machine_sleep_distinguished"])

    def test_c3_gap_in_the_span_ends_when_the_span_ends(self):
        self.sample(0)
        self.sample(1000, keys=0)
        row = self.gap(end=2000)
        self.assertEqual((row["numerator"], row["denominator"]), (300, 301))

    def test_c3_keeping_awake_rows_expect_nothing_more(self):
        self.sample(1000, keys=0)
        self.sample(1005, keys=0)
        row = self.gap(end=2000)
        self.assertEqual((row["numerator"], row["denominator"]), (0, 0))

    def test_c3_input_before_the_window_still_expects_rows_in_it(self):
        self.sample(-100)
        self.sample(500, keys=0)
        row = self.gap(end=1000)
        self.assertEqual((row["numerator"], row["denominator"]), (201, 201))

    def test_c3_rows_after_the_last_stored_one_are_not_loss(self):
        self.sample(0)
        self.sample(10, keys=0)
        row = self.gap(end=1000)
        self.assertEqual((row["numerator"], row["denominator"]), (9, 11))

    def test_c3_pause_off_and_forgotten_seconds_are_not_loss(self):
        self.sample(0)
        self.sample(500, keys=0)
        self.db.execute("INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,1,?)", (START + 100, START + 150))
        self.db.execute("INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,0,NULL)", (START + 200,))
        self.db.execute("INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,1,NULL)", (START + 250,))
        self.db.execute("INSERT INTO forgotten_ranges VALUES(?,?)", (START + 270, START + 280))
        # Missing 1..300 is 300 seconds, less 50 paused, 50 off and 10 forgotten.
        row = self.gap(end=1000)
        self.assertEqual(row["numerator"], 190)

    def init_git(self, name="invented-repo"):
        repo = self.root / name
        env = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_AUTHOR_DATE": f"{START + 10} +0000", "GIT_COMMITTER_DATE": f"{START + 10} +0000"}
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), "-c", "user.name=Invented", "-c",
                                            "user.email=invented@example.invalid", "-c", "commit.gpgsign=false", *args],
                                           env=env, stderr=subprocess.DEVNULL, text=True).strip()
        repo.mkdir()
        git("init", "-q")
        return repo, git

    def registered(self, folder, blocked=0, identity=None):
        return self.db.execute("INSERT INTO git_repositories(identity,common_dir,ts,reopen_blocked) VALUES(?,?,?,?)",
                               (identity or fc.digest(str(folder)), str(folder), START, blocked)).lastrowid

    def commit_row(self, repository, commit, complete=1):
        self.db.execute("INSERT INTO git_commits(repo_id,hash,author_ts,ts,author,email,message,complete) VALUES(?,?,?,?,'','','Invented',?)",
                        (repository, commit, START, START, complete))

    def test_c4_real_invented_git_repository(self):
        repo, git = self.init_git()
        git("commit", "--allow-empty", "-qm", "Invented first")
        first = git("rev-parse", "HEAD")
        git("commit", "--allow-empty", "-qm", "Invented second")
        before = {str(p.relative_to(repo)): (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in repo.rglob("*") if p.is_file()}
        # The recorder registers the common Git folder, not the working folder.
        self.commit_row(self.registered(repo / ".git"), first)
        row = self.metric(self.report(), "commits_recorded")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))
        self.assertEqual(row["repositories_readable"], 1)
        after = {str(p.relative_to(repo)): (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in repo.rglob("*") if p.is_file()}
        self.assertEqual(after, before)

    def test_c4_incomplete_and_forgotten_commits(self):
        repo, git = self.init_git()
        git("commit", "--allow-empty", "-qm", "Invented first")
        incomplete = git("rev-parse", "HEAD")
        git("commit", "--allow-empty", "-qm", "Invented second")
        forgotten = git("rev-parse", "HEAD")
        self.commit_row(self.registered(repo / ".git"), incomplete, complete=0)
        self.db.execute("INSERT INTO git_tombstones VALUES(?)", (forgotten,))
        row = self.metric(self.report(), "commits_recorded")
        self.assertEqual((row["numerator"], row["denominator"]), (0, 1))
        self.assertEqual((row["commits_incomplete"], row["commits_forgotten"]), (1, 1))

    def test_c4_unreadable_masked_and_blocked_repositories(self):
        self.registered(self.root / "invented-missing")
        self.registered(self.root / "invented-[redacted]", identity="invented-identity-of-the-raw-path")
        self.registered(self.root / "invented-blocked", blocked=1)
        row = self.metric(self.report(), "commits_recorded")
        self.assertIn("partial", row["reason"])
        self.assertTrue(row["partial_input"])
        self.assertEqual((row["repositories_unreadable"], row["repositories_path_masked"], row["repositories_blocked"]), (1, 1, 1))

    def test_c4_no_registered_repositories_has_a_reason(self):
        self.assertEqual(self.metric(self.report(), "commits_recorded")["reason"], "no readable registered repositories")

    def probe_blob(self, attempt, text):
        identity = fc.digest(text)
        self.db.execute("INSERT OR IGNORE INTO ax_probe_blobs(hash,bytes,created_ts,complete) VALUES(?,?,?,1)", (identity, len(text), START))
        self.db.execute("INSERT OR IGNORE INTO ax_probe_refs(attempt_row,hash) VALUES(?,?)", (attempt, identity))
        self.db.execute("INSERT OR IGNORE INTO ax_probe_chunks(hash,ordinal,text) VALUES(?,0,?)", (identity, text))
        return identity

    def probe_attempt(self, offset, texts=(), app="invented.app", ocr_status="completed", evidence_id=None, ax_status="completed", refusal=None):
        """The stored shape of an accessibility attempt: JSON nodes in part blobs, text in others."""
        attempt = self.db.execute(
            "INSERT INTO ax_probe_attempts(run_id,attempt_id,ts,mapping_key,evidence_id,payload) VALUES('invented-run',?,?,?,?,'{}')",
            ("invented-attempt-" + str(offset), START + offset, fc.digest(app.lower()), evidence_id)).lastrowid
        nodes = [{"nodeID": index, "depth": 0, "secure": False, "roleRef": self.probe_blob(attempt, "AXStaticTextRoleWord"),
                  "attributes": [{"attributeRef": self.probe_blob(attempt, "AXValueAttributeWord"),
                                  "textRef": self.probe_blob(attempt, text), "length": len(text), "maskHits": {}}]}
                 for index, text in enumerate(texts)]
        if nodes:
            part = self.probe_blob(attempt, json.dumps(nodes))
            self.db.execute("INSERT INTO ax_probe_parts(attempt_row,ordinal,hash) VALUES(?,0,?)", (attempt, part))
        payload = {"storageVersion": 3, "ocrStatus": ocr_status, "ax": {"status": ax_status}, "ocrRef": self.probe_blob(attempt, "ocrrefwordnotax")}
        if refusal:
            payload.update(ocrStatus="policy_refused", ocr_refusal_reason=refusal)
        self.db.execute("UPDATE ax_probe_attempts SET payload=? WHERE id=?", (json.dumps(payload), attempt))
        return attempt

    def agent_event(self, offset, payload, tool="claude"):
        identity = self.db.execute("INSERT OR IGNORE INTO agent_log_payloads(digest,payload) VALUES(?,?)", (fc.digest(payload), payload)).lastrowid
        identity = self.db.execute("SELECT id FROM agent_log_payloads WHERE digest=?", (fc.digest(payload),)).fetchone()[0]
        return self.db.execute("""INSERT INTO agent_log_events(tool,source,device,inode,byte_offset,ts,timestamp_known,observed_ts,project,
            record_type,role,flags,parse_status,byte_count,payload_id) VALUES(?,'invented-source',1,1,?,?,1,?,'','assistant','assistant','[]','parsed',1,?)""",
            (tool, offset * 1000, START + offset, START + offset, identity)).lastrowid

    def test_c5_probe_attempts_measure_what_was_acquired(self):
        self.screen(10, "ordinary invented prose")
        evidence = self.db.execute("SELECT id FROM evidence").fetchone()[0]
        self.probe_attempt(10, evidence_id=evidence)
        self.probe_attempt(20)
        self.probe_attempt(30, ocr_status="empty")
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertEqual((row["numerator"], row["denominator"], row["denominator_basis"]), (1, 2, "ax_probe_attempts"))
        self.assertEqual(row["other_statuses"], {"empty": 1})

    def test_c5_without_a_probe_run_states_why_not(self):
        self.screen(10, "ordinary invented prose")
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertEqual(row["reason"], fc.NO_ACQUISITION_RECORD)
        self.assertIsNone(row["denominator"])

    def test_c5_stored_occurrences_can_be_read(self):
        self.screen(10, "ordinary invented prose")
        self.screen(20, "other invented prose")
        self.db.execute("PRAGMA defer_foreign_keys=ON")
        self.db.execute("DELETE FROM collection_blobs WHERE hash=?", (fc.digest("other invented prose"),))
        row = self.metric(self.report(), "screen_occurrences_with_text")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))

    def test_no_text_in_json_or_plain_summary(self):
        secret = "invented-private-host.example.invalid/invented-private-path"
        self.logs("claude", [self.claude(promptSource="typed", body=secret)])
        self.evidence(10, "claude:invented-10", body="[redacted]")
        self.sample(10, app=secret, window=secret, document=secret)
        report = self.report()
        output = json.dumps(report) + fc.summary(report)
        for forbidden in (secret, BODY, "invented-session", "invented-10", str(self.root), "invented.app"):
            self.assertNotIn(forbidden, output)

    def test_readonly_bytes_and_mtime_and_temp_cleanup(self):
        self.sample(10)
        log = self.logs("claude", [self.claude(promptSource="typed")])
        log_before = log.read_bytes(), log.stat().st_mtime_ns
        self.db.commit()
        before, stamp = self.database.read_bytes(), self.database.stat().st_mtime_ns
        parent = self.root / "scratch"
        parent.mkdir()
        with patch.object(tempfile, "tempdir", str(parent)):
            with fc.primary_snapshot(self.database) as copy:
                self.assertEqual(len(list(parent.iterdir())), 1)
                with self.assertRaises(sqlite3.OperationalError):
                    copy.execute("DELETE FROM samples")
                fc.analyze(copy, self.homes, START, START + 60)
        self.assertEqual(list(parent.iterdir()), [])
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(self.database.stat().st_mtime_ns, stamp)
        self.assertEqual((log.read_bytes(), log.stat().st_mtime_ns), log_before)

    def test_temp_cleanup_after_analysis_failure(self):
        parent = self.root / "scratch"
        parent.mkdir()
        with patch.object(tempfile, "tempdir", str(parent)), self.assertRaisesRegex(RuntimeError, "invented"):
            with fc.primary_snapshot(self.database):
                raise RuntimeError("invented")
        self.assertEqual(list(parent.iterdir()), [])

    def test_temp_cleanup_after_backup_failure_and_no_creation(self):
        parent = self.root / "scratch"
        parent.mkdir()
        missing = self.root / "invented-missing.sqlite"
        with patch.object(tempfile, "tempdir", str(parent)), self.assertRaises(OSError):
            with fc.primary_snapshot(missing):
                self.fail("must not open missing input")
        self.assertFalse(missing.exists())
        self.assertEqual(list(parent.iterdir()), [])
        bad = self.root / "invented-invalid.sqlite"
        bad.write_bytes(b"invented non-SQLite bytes")
        before = bad.stat().st_mtime_ns
        with patch.object(tempfile, "tempdir", str(parent)), self.assertRaises(sqlite3.DatabaseError):
            with fc.primary_snapshot(bad):
                self.fail("must not read invalid input")
        self.assertEqual(bad.stat().st_mtime_ns, before)
        self.assertEqual(list(parent.iterdir()), [])

    def test_wal_snapshot_includes_committed_uncheckpointed_rows(self):
        self.db.execute("PRAGMA journal_mode=WAL")
        self.sample(10)
        self.db.commit()
        before = self.database.read_bytes()
        with fc.primary_snapshot(self.database) as copy:
            self.assertEqual(copy.execute("SELECT COUNT(*) FROM samples").fetchone()[0], 1)
        self.assertEqual(self.database.read_bytes(), before)

    def test_per_day_and_exclusive_end(self):
        self.logs("claude", [self.claude(offset, body=f"short request {offset}", promptSource="typed") for offset in (10, 86410, 86420)])
        report = self.report(end=86420)
        rows = [r for r in report["measurements"] if r["metric"] == "typed_instructions_with_keys" and r["tool"] == "claude"]
        self.assertEqual([r["denominator"] for r in rows], [1, 1])

    def test_cli_json_summary_and_sanitized_errors(self):
        self.db.commit()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home",
                str(self.homes["codex"][0]), "--from", str(START), "--to", str(START + 60)]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 0)
        self.assertEqual(json.loads(out.getvalue())["schema_version"], self.report()["schema_version"])
        self.assertIn("Top failure categories", err.getvalue())
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main([str(self.root / "invented-private-missing"), *args[1:]]), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertNotIn(str(self.root), err.getvalue())

    def test_malformed_log_count_and_no_exception_content(self):
        path = self.logs("claude", [])
        path.write_text("invented-private-invalid-json\n[]\n")
        report = self.report()
        self.assertEqual(report["diagnostics"]["malformed_log_lines"], 2)
        self.assertNotIn("invented-private", json.dumps(report))

    def test_missing_sample_and_evidence_tables(self):
        self.db.execute("DROP TABLE samples")
        self.db.execute("DROP TABLE evidence")
        self.logs("claude", [self.claude(promptSource="typed")])
        report = self.report()
        for metric in ("typed_instructions_with_keys", "typed_instructions_stored"):
            row = self.metric(report, metric, "claude")
            self.assertIn("channel absent", row["reason"])
            self.assertEqual(row["denominator"], 1)
            self.assertIsNone(row["ratio"])

    def chrome(self, visits):
        path = self.root / "invented-chrome-history"
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE urls(id INTEGER,url TEXT)")
            db.execute("CREATE TABLE visits(id INTEGER,url INTEGER,visit_time INTEGER)")
            for index, (offset, url) in enumerate(visits):
                db.execute("INSERT INTO urls VALUES(?,?)", (index, url))
                db.execute("INSERT INTO visits VALUES(?,?,?)", (index, index, (START + offset + 11644473600) * 1000000))
        return path

    def test_c6_visits_url_host_path_and_tolerance(self):
        chrome = self.chrome([(10, "https://invented.example.invalid/a?q=secret"),
                              (20, "https://invented.example.invalid/b"), (30, "https://invented.example.invalid/c")])
        self.sample(15, document="https://INVENTED.example.invalid/a?different=1#fragment")
        self.sample(26, document="https://invented.example.invalid/b")
        before, mtime = chrome.read_bytes(), chrome.stat().st_mtime_ns
        report = self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,), tolerance=5))
        row = self.metric(report, "chrome_visits_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 3))
        self.assertEqual(chrome.read_bytes(), before)
        self.assertEqual(chrome.stat().st_mtime_ns, mtime)
        self.assertNotIn("invented.example", json.dumps(report) + fc.summary(report))

    def test_c6_duplicates_input_and_exclusive_end(self):
        chrome = self.chrome([(10, "https://invented.invalid/"), (180, "https://invented.invalid/")])
        self.sample(10, document="https://invented.invalid/")
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome, chrome))), "chrome_visits_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_c6_absent_bad_schema_and_non_http_visits(self):
        row = self.metric(self.report(), "chrome_visits_attributed")
        self.assertIn("channel absent", row["reason"])
        chrome = self.chrome([(10, "chrome://invented-settings/")])
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (0, 1))
        with closing(sqlite3.connect(chrome)) as db, db:
            db.execute("DROP TABLE visits")
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
        self.assertIn("unsupported", row["reason"])

    def test_c6_snapshot_deleted_on_query_failure(self):
        chrome = self.chrome([(10, "https://invented.invalid/")])
        scratch = self.root / "invented-scratch"
        scratch.mkdir()
        with patch.object(tempfile, "tempdir", str(scratch)):
            self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        self.assertEqual(list(scratch.iterdir()), [])
        with patch.object(tempfile, "tempdir", str(scratch)), \
                patch.object(fc, "url_digest", side_effect=ValueError("invented-private-input")):
            self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        self.assertEqual(list(scratch.iterdir()), [])

    def changed_file(self, name, offset, folder=None):
        path = (folder or self.root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("invented file contents never opened by checker")
        os.utime(path, (START + offset, START + offset))
        return path

    def test_c7_a_file_the_person_had_open_changed(self):
        repo = self.root / "invented-known-repository"
        (repo / ".git").mkdir(parents=True)
        one, two = self.changed_file("invented-one", 10, repo), self.changed_file("invented-two", 20, repo)
        old, unopened = self.changed_file("invented-old", -10, repo), self.changed_file("invented-unopened", 30, repo)
        self.sample(15, document=one.as_uri())
        self.sample(100, document=two.as_uri())
        self.sample(101, document=old.as_uri())
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (one, two, old, unopened)}
        report = self.report()
        row = self.metric(report, "open_document_changes_attributed")
        # Three files were open. `old` did not change in the window, `two` changed long before it was
        # focused, and `unopened` was never anyone's document.
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))
        self.assertEqual(row["documents_known"], 3)
        self.assertTrue(row["latest_mtime_only"])
        for path, (content, mtime) in before.items():
            self.assertEqual(path.read_bytes(), content)
            self.assertEqual(path.stat().st_mtime_ns, mtime)
        self.assertNotIn(str(repo), json.dumps(report) + fc.summary(report))

    def test_c7_never_walks_a_folder(self):
        repo = self.root / "invented-repo"
        (repo / ".git").mkdir(parents=True)
        known = self.changed_file("invented-known", 10, repo)
        self.changed_file("invented-sibling", 10, repo)
        self.sample(10, document=str(known))
        with patch.object(fc.os, "walk", side_effect=AssertionError("walked")):
            row = self.metric(self.report(), "open_document_changes_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_c7_one_saved_document_among_agent_written_files(self):
        # The review's scenario: one save by a person, 1257 files an agent, Git and a build wrote.
        repo = self.root / "invented-worktree"
        (repo / ".git").mkdir(parents=True)
        saved = self.changed_file("invented-saved-document", 10, repo)
        for index in range(1257):
            self.changed_file(f"invented-agent-{index}", 20 + index % 100, repo)
        self.sample(10, document=str(saved))
        self.db.execute("""INSERT INTO git_working_folders(identity,source,device,inode,session,folder,top_level,branch,head,ts,last_seen,attempt_ts,status)
            VALUES('invented',?,1,1,'invented-session',?,?,'','',?,?,?,'')""", ('invented-source', str(repo), str(repo), START, START + 20, START))
        row = self.metric(self.report(), "open_document_changes_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_c7_stays_out_of_worst_days_and_top_failures(self):
        # A file the person had open that changed unattributed, which an agent can also cause.
        path = self.changed_file("invented-open-file", 100, None)
        self.sample(10, document=str(path))
        report = self.report()
        row = self.metric(report, "open_document_changes_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (0, 1))
        self.assertNotIn("C7", [item["check"] for item in report["worst_days"]])
        self.assertFalse([item for item in report["top_failure_categories"] if "document" in item["category"]])
        self.assertEqual(report["diagnostics"]["open_document_changes_without_attribution"], 1)

    def test_c7_unicode_forms_of_one_name_are_one_file(self):
        composed = unicodedata.normalize("NFC", "invented-\ud55c\uae00-file")
        decomposed = unicodedata.normalize("NFD", composed)
        self.assertNotEqual(composed, decomposed)
        path = self.changed_file(composed, 10)
        self.sample(10, document=str(self.root / decomposed))
        self.sample(100, document=str(path))
        row = self.metric(self.report(), "open_document_changes_attributed")
        self.assertEqual((row["numerator"], row["denominator"], row["documents_known"]), (1, 1, 1))

    def test_c7_symlink_ancestor_is_measured_and_counted(self):
        real = self.root / "invented-real"
        path = self.changed_file("invented-file", 10, real)
        alias = self.root / "invented-alias"
        alias.symlink_to(real, target_is_directory=True)
        self.sample(10, document=str(alias / "invented-file"))
        self.sample(100, document=str(path))
        report = self.report()
        row = self.metric(report, "open_document_changes_attributed")
        self.assertEqual((row["numerator"], row["denominator"], row["documents_known"]), (1, 1, 1))
        self.assertEqual(report["diagnostics"]["document_paths_through_symlink"], 1)

    def test_c7_symlink_file_and_folder_are_not_documents(self):
        target = self.changed_file("invented-target", 10)
        link = self.root / "invented-link"
        link.symlink_to(target)
        folder = self.root / "invented-folder"
        folder.mkdir()
        self.sample(10, document=str(link))
        self.sample(11, document=str(folder))
        report = self.report()
        self.assertEqual(self.metric(report, "open_document_changes_attributed")["denominator"], 0)
        self.assertEqual(report["diagnostics"]["document_paths_not_regular_files"], 2)

    def test_c7_missing_known_file_is_counted(self):
        self.sample(10, document=str(self.root / "invented-missing-parent" / "invented-deleted"))
        report = self.report()
        self.assertEqual(report["diagnostics"]["known_document_paths_unavailable"], 1)
        self.assertIn("no known documents", self.metric(report, "open_document_changes_attributed")["reason"])

    def test_c8_zsh_and_bash_timestamps_and_no_command_output(self):
        zsh, bash = self.root / "invented-zsh-history", self.root / "invented-bash-history"
        command = "invented-private-command --host invented-private-host.invalid"
        zsh.write_text(f": {START + 10}:0;{command}\n: {START + 20}:3;{command}\nuntimed invented command\n")
        bash.write_text(f"#{START + 30}\n{command}\n")
        self.sample(14, app="com.apple.Terminal")
        self.sample(20, app="invented-nonterminal")
        self.sample(30, keys=0, app="com.apple.Terminal", clicks=1)
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (zsh, bash)}
        report = self.report(references=fc.ReferenceInputs(shell_histories=(zsh, bash)))
        row = self.metric(report, "timestamped_shell_commands_with_keys")
        self.assertEqual((row["numerator"], row["denominator"], row["untimed_lines"]), (1, 3, 1))
        self.assertNotIn(command, json.dumps(report) + fc.summary(report))
        self.assertNotIn("invented-private-host", json.dumps(report) + fc.summary(report))
        for path, (content, mtime) in before.items():
            self.assertEqual(path.read_bytes(), content)
            self.assertEqual(path.stat().st_mtime_ns, mtime)

    def test_c8_terminal_override_zero_tolerance_and_multiline_zsh(self):
        history = self.root / "invented-history"
        history.write_text(f": {START + 10}:0;invented first\\\n"
                           "invented continuation\n"
                           f": {START + 20}:0;invented second\n")
        self.sample(10, app="invented-terminal")
        self.sample(21, app="invented-terminal")
        row = self.metric(self.report(references=fc.ReferenceInputs(shell_histories=(history, history), tolerance=0,
                                                                   terminal_apps=("invented-terminal",))),
                          "timestamped_shell_commands_with_keys")
        self.assertEqual((row["numerator"], row["denominator"], row["untimed_lines"]), (1, 2, 0))

    def test_c8_absent_and_unreadable(self):
        self.assertIn("channel absent", self.metric(self.report(), "timestamped_shell_commands_with_keys")["reason"])
        row = self.metric(self.report(references=fc.ReferenceInputs(shell_histories=(self.root / "invented-missing",))),
                          "timestamped_shell_commands_with_keys")
        self.assertIn("unreadable", row["reason"])

    def test_distinct_native_instructions_same_second_survive(self):
        first, second = self.claude(promptSource="typed"), self.claude(promptSource="typed")
        second["uuid"] = "invented-distinct"
        self.logs("claude", [first, second])
        self.evidence(10, "claude:invented-10")
        report = self.report()
        self.assertEqual(self.metric(report, "typed_instructions_with_keys", "claude")["denominator"], 2)
        row = self.metric(report, "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))

    def test_cli_unexpected_error_sanitized_and_snapshot_deleted(self):
        scratch = self.root / "invented-scratch"
        scratch.mkdir()
        args = [str(self.database), "--from", str(START), "--to", str(START + 60)]
        out, err = io.StringIO(), io.StringIO()
        with patch.object(tempfile, "tempdir", str(scratch)), \
                patch.object(fc, "analyze", side_effect=RuntimeError("invented-private-error")), \
                redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 1)
        self.assertEqual(list(scratch.iterdir()), [])
        self.assertNotIn("invented-private", out.getvalue() + err.getvalue())

    def test_nested_agent_marker_overrides_general_human_marker(self):
        self.logs("codex", [{"type": "session_meta", "payload": {"origin": {"kind": "human"}}},
                            self.codex(parent_thread_id="invented-parent")])
        self.assertEqual(self.report()["classifications"], {"agent": 1})

    def test_copied_claude_source_keeps_evidence_identity(self):
        row = self.claude(promptSource="typed")
        self.logs("claude", [row], stem="invented-original")
        self.logs("claude", [row], stem="invented-copy")
        self.evidence(10, "claude:invented-10", source="invented-original")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_codex_json_tool_arguments_establish_short_provenance(self):
        body = "Invented eight word instruction for a different worker"
        self.logs("codex", [{"type": "response_item", "timestamp": START + 1, "payload": {
            "type": "function_call", "name": "invented_dispatch", "arguments": json.dumps({"prompt": body})}}],
                  stem="invented-parent")
        self.logs("claude", [self.claude(body=body)])
        self.assertEqual(self.report()["classifications"], {"agent": 1})

    def reference(self, frames=(), events=()):
        path = self.root / "invented-reference.sqlite"
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE frames(id INTEGER,timestamp TEXT,app_name TEXT,window_name TEXT,browser_url TEXT,focused INTEGER,full_text TEXT,accessibility_text TEXT,text_source TEXT,monitor_id INTEGER)")
            db.execute("CREATE TABLE ui_events(id INTEGER,timestamp TEXT,event_type TEXT,app_name TEXT,window_title TEXT,element_role TEXT,element_name TEXT)")
            db.execute("CREATE TABLE elements(id INTEGER,frame_id INTEGER,text TEXT)")
            db.execute("CREATE INDEX frames_time ON frames(timestamp)")
            db.execute("CREATE INDEX ui_events_time ON ui_events(timestamp)")
            for index, frame in enumerate(frames):
                offset, app, window, url, text, *extra = frame
                focused = extra[0] if extra else 1
                stamp = datetime.fromtimestamp(START + offset, timezone.utc).isoformat()
                db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?,?,?,?,?)", (index, stamp, app, window, url, focused, text, "", "invented", 2))
            for index, (offset, kind, app, window) in enumerate(events):
                stamp = datetime.fromtimestamp(START + offset, timezone.utc).isoformat()
                db.execute("INSERT INTO ui_events VALUES(?,?,?,?,?,?,?)", (index, stamp, kind, app, window, "invented-role", "invented-element"))
        return path

    def screen(self, offset, text, app="invented.app"):
        # As the recorder stores it: an empty text column and the words in a shared blob.
        identity = self.db.execute(EVIDENCE_INSERT, (START + offset, "screen", app, None, "")).lastrowid
        digest = fc.digest(text)
        self.db.execute("INSERT OR IGNORE INTO collection_blobs(hash,content,created_ts) VALUES(?,?,?)", (digest, text, START + offset))
        self.db.execute("INSERT INTO screen_payloads(evidence_id,payload,text_hash) VALUES(?,'{}',?)", (identity, digest))

    def test_c9_attribution_categories_and_focused_filter(self):
        ref = self.reference([(10, "invented.app", "invented window", "", "first"),
                              (20, "invented.app", "wrong window", "", "second"),
                              (30, "other app", "invented window", "", "third"),
                              (40, "invented.app", "invented window", "", "fourth"),
                              (50, "invented.app", "invented window", "", "hidden", 0)])
        for offset in (11, 20, 30):
            self.sample(offset)
        row = self.metric(self.report(reference=ref), "reference_frames_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 4))
        self.assertEqual(row["disagreements"], {"window_or_document_differs": 1, "app_differs": 1, "ours_missing": 1})

    def test_c9_document_url_matches_despite_title_difference(self):
        ref = self.reference([(10, "invented.app", "other title", "https://invented.invalid/doc?secret=one", "text")])
        self.sample(9, document="https://invented.invalid/doc?different=two")
        self.assertEqual(self.metric(self.report(reference=ref), "reference_frames_attributed")["numerator"], 1)

    def test_c10_weighted_informative_recall_and_fuzzy_matching(self):
        ref = self.reference([(10, "invented.app", "invented window", "", "toolbar uniquealpha password=inventedsecretvalue"),
                              (20, "invented.app", "invented window", "", "toolbar uniquebeta"),
                              (30, "invented.app", "invented window", "", "toolbar uniquegamma")])
        self.sample(10)
        self.screen(10, "toolbar uniquealphx password=differentsecretvalue")
        report = self.report(reference=ref)
        weighted = self.metric(report, "informative_term_weighted_recall")
        raw = self.metric(report, "informative_term_unweighted_recall")
        self.assertAlmostEqual(weighted["ratio"], 1 / 3)
        self.assertAlmostEqual(raw["ratio"], 4 / 6)
        self.assertEqual(weighted["app_id"], fc.digest("invented.app"))
        output = json.dumps(report) + fc.summary(report)
        for text in ("uniquealpha", "inventedsecretvalue", "invented.app"):
            self.assertNotIn(text, output)

    def test_c10_same_app_and_60_second_boundary(self):
        ref = self.reference([(10, "invented.app", "window", "", "referencealpha"),
                              (20, "invented.app", "window", "", "referencebeta")])
        self.sample(10)
        self.screen(70, "referencealpha")
        self.screen(81, "referencebeta")
        self.screen(20, "referencebeta", app="wrong.app")
        row = self.metric(self.report(reference=ref), "informative_term_weighted_recall")
        self.assertAlmostEqual(row["ratio"], .5)

    def test_c10_common_terms_zero_weight_and_hangul(self):
        ref = self.reference([(10, "invented.app", "window", "", "메뉴 작업 123"),
                              (20, "invented.app", "window", "", "메뉴 작업 456")])
        row = self.metric(self.report(reference=ref), "informative_term_weighted_recall")
        self.assertEqual(row["denominator"], 0)
        self.assertIsNone(row["ratio"])
        self.assertEqual(fc.informative_terms("가 가나다 가나 abc ab 123 abc123"), {"가나다", "가나", "abc"})

    def test_c11_reference_click_focus_switch(self):
        ref = self.reference(events=[(10, "click", "invented.app", "invented window"),
                                     (20, "window-focus", "invented.app", "invented window"),
                                     (30, "app-switch", "invented.app", ""),
                                     (40, "click", "invented.app", ""),
                                     (50, "invented-unknown", "invented.app", "")])
        self.sample(11, clicks=1)
        self.sample(20)
        self.sample(30)
        report = self.report(reference=ref)
        rows = {r["event_kind"]: r for r in report["measurements"] if r["check"] == "C11"}
        self.assertEqual((rows["click"]["numerator"], rows["click"]["denominator"]), (1, 2))
        self.assertEqual(rows["window_focus"]["ratio"], 1)
        self.assertEqual(rows["app_switch"]["ratio"], 1)

    def test_reference_absent_schema_and_readonly_snapshot(self):
        report = self.report()
        for metric in ("reference_frames_attributed", "informative_term_weighted_recall", "reference_input_observed"):
            self.assertIn("channel absent", self.metric(report, metric)["reason"])
        ref = self.reference([(10, "invented.app", "window", "", "invented")])
        before = ref.read_bytes(), ref.stat().st_mtime_ns
        self.report(reference=ref)
        self.assertEqual((ref.read_bytes(), ref.stat().st_mtime_ns), before)
        with closing(sqlite3.connect(ref)) as db, db:
            db.execute("DROP TABLE frames")
        self.assertIn("channel absent", self.metric(self.report(reference=ref), "reference_frames_attributed")["reason"])

    def test_reference_retry_on_busy_or_malformed(self):
        ref = self.reference()
        original = fc.readonly
        calls = []
        def flaky(path):
            calls.append(path)
            if len(calls) < 3:
                raise sqlite3.DatabaseError("invented malformed database")
            return original(path)
        with patch.object(fc, "readonly", side_effect=flaky):
            with fc.reference_snapshot(ref) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM frames").fetchone()[0], 0)
        self.assertEqual(len(calls), 3)

    def test_mask_shared_secrets_and_fuzzy_distance(self):
        text = "password=inventedsecretvalue token='invented token' sk-inventedlongsecret123 user@invented.invalid Bearer inventedbearer123"
        masked = fc.mask(text)
        for secret in ("inventedsecretvalue", "invented token", "inventedlongsecret123", "user@invented.invalid", "inventedbearer123"):
            self.assertNotIn(secret, masked)
        self.assertNotIn("inventedsecretvalue", fc.informative_terms('{"token":"inventedsecretvalue"}'))
        self.assertEqual(fc.masked_tree('{"token":"inventedsecretvalue"}'), {"token": "[redacted]"})
        for a, b, expected in (("alpha", "alphx", True), ("alpha", "alph", True), ("alpha", "alphaa", True),
                               ("alpha", "alhpa", False), ("alpha", "alpzz", False)):
            self.assertEqual(fc.edit_one(a, b), expected)

    def test_c12_private_masked_bundle_metadata_and_reverse_material(self):
        secret = "password=inventedsecretvalue"
        ref = self.reference([(10, "invented.app", "invented window", "https://invented.invalid/doc", "Reference " + secret),
                              (20, "invented.app", "different window", "", "Other " + secret)])
        self.sample(10, document="https://invented.invalid/doc")
        self.sample(20)
        self.screen(10, "Screen " + secret)
        self.evidence(15, "claude:invented-prompt", "Prompt " + secret)
        self.agent_event(16, "Agent " + secret)
        self.db.execute("""INSERT INTO git_commits(repo_id,hash,author_ts,ts,author,email,message,complete)
            VALUES(1,'invented-hash',?,?,'','',?,1)""", (START + 17, START + 17, secret))
        folder = self.root / "invented-bundles"
        report = self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder, seed=7), reference=ref)
        self.assertEqual(report["sample_export"]["exported"], 1)
        self.assertEqual(report["sample_export"]["selected_windows"], [{"start_ts": START, "end_ts": START + 300}])
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        paths = list(folder.glob("window-*.json"))
        self.assertEqual(len(paths), 1)
        self.assertEqual(paths[0].stat().st_mode & 0o777, 0o600)
        text = paths[0].read_text()
        self.assertNotIn("inventedsecretvalue", text)
        bundle = json.loads(text)
        why = bundle["reference"][0]["comparison"]
        self.assertEqual(why["focused_per_ours"], "yes")
        self.assertTrue(why["matching_document"])
        self.assertTrue(why["screen_evidence_within_60s"])
        self.assertEqual(len(bundle["our_only_candidates"]["prompts"]), 1)
        self.assertEqual(len(bundle["our_only_candidates"]["agent_session_events"]), 1)
        # Screen text is in a blob and the agent text behind payload_id: both must reach the judge, masked.
        self.assertEqual([row["text"] for row in bundle["ours"]["evidence"] if row["kind"] == "screen"], ["Screen [secret]"])
        self.assertEqual([row["payload"] for row in bundle["our_only_candidates"]["agent_payloads"]], ["Agent [secret]"])
        self.assertEqual(len(bundle["our_only_candidates"]["commits"]), 1)
        self.assertIsNone(bundle["judgment"])
        self.assertNotIn("Reference", json.dumps(report) + fc.summary(report))
        self.assertEqual(fc.delete_bundles(folder), 1)
        self.assertFalse(folder.exists())

    def test_c12_stratification_seed_and_same_time_bounds(self):
        frames = [(i, "invented.app" if i < 600 else "other.app", "window", "", "term " + str(i)) for i in (10, 310, 610, 910)]
        ref = self.reference(frames)
        for offset in (10, 310, 610, 910):
            self.sample(offset)
        options = fc.ReferenceInputs(bundle_count=2, seed=42)
        one = self.report(end=1200, references=options, reference=ref)["sample_export"]
        two = self.report(end=1200, references=options, reference=ref)["sample_export"]
        self.assertEqual(one["selected_windows"], two["selected_windows"])
        self.assertEqual(len(one["selected_windows"]), 2)
        self.assertTrue(any(r["start_ts"] < START + 600 for r in one["selected_windows"]))
        self.assertTrue(any(r["start_ts"] >= START + 600 for r in one["selected_windows"]))
        bounded = fc.ReferenceInputs(bundle_count=20, window_start=START + 300, window_end=START + 900)
        result = self.report(end=1200, references=bounded, reference=ref)["sample_export"]
        self.assertEqual([r["start_ts"] for r in result["selected_windows"]], [START + 300, START + 600])
        self.assertEqual(result["mode"], "same_time")

    def test_c12_rejects_nonprivate_nonempty_and_unsafe_deletion(self):
        ref = self.reference([(10, "invented.app", "window", "", "text")])
        self.sample(10)
        folder = self.root / "invented-bundles"
        folder.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        folder.chmod(0o700)
        keep = folder / "invented-keep"
        keep.write_text("invented")
        with self.assertRaises(ValueError):
            self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        self.assertTrue(keep.exists())
        (folder / ".fidelity-bundles.json").write_text(json.dumps({"format": "fidelity-local-bundles-v1", "files": ["../invented-keep"]}))
        with self.assertRaises(ValueError):
            fc.delete_bundles(folder)
        self.assertTrue(keep.exists())

    def test_c12_failed_export_rolls_back_private_folder(self):
        ref = self.reference([(10, "invented.app", "window", "", "text")])
        self.sample(10)
        folder = self.root / "invented-bundles"
        original = fc.private_json
        def fail_manifest(path, value):
            if path.name.startswith(".fidelity"):
                raise OSError("invented failure")
            original(path, value)
        with patch.object(fc, "private_json", side_effect=fail_manifest), self.assertRaises(OSError):
            self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        self.assertFalse(folder.exists())

    def test_selected_days_exclude_other_days_from_measurements(self):
        self.logs("claude", [self.claude(10, promptSource="typed"), self.claude(86410, promptSource="typed")])
        day = datetime.fromtimestamp(START, timezone.utc).date().isoformat()
        report = self.report(end=172800, references=fc.ReferenceInputs(selected_days=(day,)))
        self.assertEqual({r["day"] for r in report["measurements"]} - {None}, {day})
        self.assertEqual({r["metric"] for r in report["measurements"] if r["day"] is None}, {"seconds_after_last_row", "probe_run_drop_counters"})
        self.assertEqual(report["classifications"], {"human": 1})

    def test_c12_cli_export_and_delete_with_same_time_mode(self):
        ref = self.reference([(10, "invented.app", "invented window", "", "Invented reference token=inventedsecretvalue")])
        self.sample(10)
        self.db.commit()
        folder = self.root / "invented-cli-bundles"
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--window-from", str(START), "--window-to", str(START + 300),
                "--bundle-dir", str(folder), "--seed", "13"]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 0)
        report = json.loads(out.getvalue())
        self.assertEqual(report["sample_export"]["exported"], 1)
        self.assertEqual(report["sample_export"]["mode"], "same_time")
        self.assertNotIn("Invented reference", out.getvalue() + err.getvalue())
        self.assertNotIn("inventedsecretvalue", out.getvalue() + err.getvalue())
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(["--delete-bundles", str(folder)]), 0)
        self.assertFalse(folder.exists())

    def test_reference_query_retry_reopens_snapshot(self):
        ref = self.reference()
        self.db.commit()
        original = fc.reference_checks
        count = 0
        def flaky(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 1:
                raise sqlite3.DatabaseError("invented malformed reference")
            return original(*args, **kwargs)
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--from", str(START), "--to", str(START + 300)]
        with patch.object(fc, "reference_checks", side_effect=flaky), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args), 0)
        self.assertEqual(count, 2)

    def test_reference_failures_are_reported_without_text_or_temp_leaks(self):
        self.db.commit()
        bad = self.root / "invented-malformed-reference"
        bad.write_bytes(b"invented private malformed data")
        out, err = io.StringIO(), io.StringIO()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(bad), "--from", str(START), "--to", str(START + 300)]
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 0)
        self.assertEqual(json.loads(out.getvalue())["diagnostics"]["reference_database_unavailable_after_retries"], 1)
        self.assertNotIn("invented private", out.getvalue() + err.getvalue())

    def test_schema9_web_keys_c6_c9_c12_and_path_negatives(self):
        chrome = self.chrome([(10, "https://invented.invalid/doc///?query=ignored"),
                              (20, "https://invented.invalid/"),
                              (30, "https://invented.invalid/other")])
        ref = self.reference([(10, "invented.app", "different title", "https://invented.invalid/doc/", "ordinary prose"),
                              (20, "invented.app", "different title", "https://invented.invalid/", "ordinary prose"),
                              (30, "invented.app", "different title", "https://invented.invalid/other", "ordinary prose")])
        self.sample(10, document="invented.invalid/doc")
        self.sample(20, document="invented.invalid")
        self.sample(30, document="invented.invalid/doc")
        folder = self.root / "invented-key-bundles"
        report = self.report(end=300, reference=ref, references=fc.ReferenceInputs(chrome_histories=(chrome,), bundle_dir=folder))
        for metric in ("chrome_visits_attributed", "reference_frames_attributed"):
            row = self.metric(report, metric)
            self.assertEqual((row["numerator"], row["denominator"]), (2, 3))
        bundle = json.loads(next(folder.glob("window-*.json")).read_text())
        self.assertEqual([r["comparison"]["matching_document"] for r in bundle["reference"]], [True, True, False])
        self.assertFalse(fc.same_document("invented.invalid/A", "https://invented.invalid/a"))
        self.assertTrue(fc.same_document("localhost/doc", "https://localhost/doc/"))
        self.assertTrue(fc.same_document("invented.invalid/a b", "https://invented.invalid/a%20b"))
        self.assertTrue(fc.same_document("invented.invalid/a?b", "https://invented.invalid/a%3Fb?ignored=yes"))
        self.assertTrue(fc.same_document("invented.invalid/a#b", "https://invented.invalid/a%23b#ignored"))
        self.assertTrue(fc.same_document("invented.invalid/a%20b", "https://invented.invalid/a%2520b"))
        self.assertFalse(fc.same_document("invented.invalid/a?b", "https://invented.invalid/a?b"))
        self.assertTrue(fc.same_document("invented.invalid/https://nested", "https://invented.invalid/https://nested"))

    def test_native_ipv6_idn_and_escaped_hosts_c6_c9_c12(self):
        # Keys independently verified with Foundation URL.host + URL.path.
        fixtures = [("https://[2001:db8::1]/doc/", "2001:db8::1/doc"),
                    ("https://bücher.invalid/doc/", "xn--bcher-kva.invalid/doc"),
                    ("https://faß.invalid/doc/", "xn--fa-hia.invalid/doc"),
                    ("https://%62%C3%BCcher.invalid/doc/", "bücher.invalid/doc"),
                    ("https://[2001:db8::1]/other", "2001:db8::1/doc")]
        chrome = self.chrome([(10 * (i + 1), url) for i, (url, _) in enumerate(fixtures)])
        ref = self.reference([(10 * (i + 1), "invented.app", "different title", url, "ordinary prose")
                              for i, (url, _) in enumerate(fixtures)])
        for i, (_, key) in enumerate(fixtures):
            self.sample(10 * (i + 1), document=key)
        folder = self.root / "invented-native-host-bundles"
        report = self.report(end=300, reference=ref, references=fc.ReferenceInputs(chrome_histories=(chrome,), bundle_dir=folder))
        for metric in ("chrome_visits_attributed", "reference_frames_attributed"):
            row = self.metric(report, metric)
            self.assertEqual((row["numerator"], row["denominator"]), (4, 5))
        bundle = json.loads(next(folder.glob("window-*.json")).read_text())
        self.assertEqual([r["comparison"]["matching_document"] for r in bundle["reference"]], [True] * 4 + [False])

    def test_c7_files_are_asked_about_once_and_bucketed_by_their_change(self):
        first = self.changed_file("invented-a", 86410)
        second = self.changed_file("invented-b", 86410)
        self.sample(10, document=str(first))
        self.sample(11, document=str(first))
        self.sample(86410, document=str(second))
        real, asked = os.path.realpath, []
        def counted(path, *args, **kwargs):
            asked.append(str(path))
            return real(path, *args, **kwargs)
        with patch.object(fc.os.path, "realpath", side_effect=counted):
            report = self.report(end=172800)
        rows = [r for r in report["measurements"] if r["check"] == "C7"]
        self.assertEqual([(r["numerator"], r["denominator"], r["documents_known"]) for r in rows], [(0, 0, 2), (1, 2, 2)])
        self.assertEqual(asked.count(str(first)), 1)

    def test_c7_cannot_enter_credential_folders_even_through_a_symlink(self):
        protected = self.root / ".ssh"
        known = self.changed_file("invented-file", 10, protected)
        alias = self.root / "invented-alias"
        alias.symlink_to(protected, target_is_directory=True)
        self.sample(10, document=str(known))
        self.sample(11, document=str(alias / "invented-file"))
        real, asked = os.path.realpath, []
        with patch.object(fc.os.path, "realpath", side_effect=lambda path, *a, **k: asked.append(str(path)) or real(path, *a, **k)):
            report = self.report()
        self.assertEqual(self.metric(report, "open_document_changes_attributed")["documents_known"], 0)
        self.assertEqual(report["diagnostics"]["document_paths_excluded"], 2)
        # A path already naming the folder is refused before the filesystem is asked anything.
        self.assertNotIn(str(known), asked)

    def test_c2_legacy_matching_is_order_independent(self):
        for order in ((11, 10), (10, 11)):
            with self.subTest(order=order):
                self.db.execute("DELETE FROM evidence")
                self.logs("claude", [self.claude(i, promptSource="typed") for i in order])
                for offset in (10, 12):
                    self.evidence(offset, "claude:legacy:invented-" + str(offset))
                row = self.metric(self.report(), "typed_instructions_stored", "claude")
                self.assertEqual((row["numerator"], row["denominator"]), (2, 2))

    def test_c2_legacy_allocation_reassigns_copied_source_alias(self):
        first, second = (self.claude(i, promptSource="typed") for i in (10, 11))
        self.logs("claude", [first, second])
        self.logs("claude", [first], stem="invented-copy")
        self.evidence(10, "claude:legacy:invented-first")
        self.evidence(9, "claude:legacy:invented-second", source="invented-copy")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 2))

    def test_c2_exact_match_can_move_without_losing_native_priority(self):
        legacy = self.claude(9, promptSource="typed")
        legacy.pop("uuid")
        self.logs("claude", [self.claude(10, promptSource="typed"), legacy])
        self.logs("claude", [self.claude(10, promptSource="typed")], stem="invented-copy")
        self.evidence(10, "claude:invented-10")
        self.evidence(11, "claude:invented-10", body="[redacted]", source="invented-copy")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["identity_matched_content_changed"]), (2, 2, 1))

    def test_dead_mask_child_is_reaped_and_cli_error_sanitized(self):
        fc.close_mask()
        fc.mask("ordinary invented prose")
        helper = fc._product_mask
        folder = Path(helper.temp.name)
        helper.process.kill()
        helper.process.wait()
        ref = self.reference([(10, "invented.app", "invented window", "", "ordinary prose")])
        self.sample(10)
        self.db.commit()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--from", str(START), "--to", str(START + 300)]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertTrue(err.getvalue().endswith("Fidelity check failed: input unavailable, invalid range or unsupported data; no content emitted.\n"))
        self.assertNotIn(str(self.root), err.getvalue())
        self.assertIsNone(fc._product_mask)
        self.assertIsNotNone(helper.process.returncode)
        self.assertTrue(helper.process.stdin.closed)
        self.assertTrue(helper.process.stdout.closed)
        self.assertFalse(folder.exists())
        helper.close()
        fc.close_mask()

    def test_c8_oversized_zsh_bash_and_continuation_records_are_partial(self):
        for shell in ("untimed", "zsh", "bash", "continuation"):
            with self.subTest(shell=shell):
                history = self.root / ("invented-" + shell)
                with history.open("wb") as stream:
                    if shell == "zsh":
                        stream.write(f": {START + 10}:0;".encode())
                    elif shell == "bash":
                        stream.write(f"#{START + 10}\n".encode())
                    elif shell == "continuation":
                        stream.write(f": {START + 10}:0;invented\\\n".encode())
                    stream.write(b"x" * (fc.MAX_HISTORY_LINE * 2) + b"\n")
                    stream.write(f": {START + 20}:0;ordinary invented command\n".encode())
                self.sample(20, app="com.apple.Terminal")
                row = self.metric(self.report(references=fc.ReferenceInputs(shell_histories=(history,))), "timestamped_shell_commands_with_keys")
                self.assertTrue(row["partial_input"])
                self.assertIn("partial", row["reason"])
                self.assertEqual(row["oversized_records"], 1)
                self.assertEqual(row["denominator"], 2 if shell == "continuation" else 1)
                self.assertEqual(row["numerator"], 1)

    def test_c8_only_oversized_records_are_unavailable(self):
        history = self.root / "invented-history"
        history.write_bytes(b"x" * (fc.MAX_HISTORY_LINE + 1))
        row = self.metric(self.report(references=fc.ReferenceInputs(shell_histories=(history,))), "timestamped_shell_commands_with_keys")
        self.assertIsNone(row["denominator"])
        self.assertIsNone(row["numerator"])
        self.assertTrue(row["partial_input"])
        self.assertEqual(row["oversized_records"], 1)

    def test_c2_two_native_instructions_consume_one_legacy_row_once(self):
        first, second = self.claude(promptSource="typed"), self.claude(promptSource="typed")
        second["uuid"] = "invented-distinct-native"
        self.logs("claude", [first, second])
        self.logs("claude", [first, second], stem="invented-copy")
        self.evidence(10, "claude:legacy:invented-old")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))

    def test_c2_exact_native_allocation_precedes_legacy_fallback(self):
        legacy = self.claude(9, promptSource="typed")
        legacy.pop("uuid")
        exact = self.claude(promptSource="typed")
        self.logs("claude", [legacy, exact])
        self.evidence(10, "claude:invented-10")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["identity_matched_content_changed"]), (1, 2, 0))

    def test_c11_click_capacity_and_event_identity_are_conserved(self):
        ref = self.reference(events=[(10 + i / 10, "click", "invented.app", "") for i in range(5)])
        with closing(sqlite3.connect(ref)) as db, db:
            db.execute("INSERT INTO ui_events SELECT * FROM ui_events WHERE id=0")
        self.sample(10, clicks=1)
        row = next(r for r in self.report(reference=ref)["measurements"] if r["check"] == "C11" and r["event_kind"] == "click")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 5))

    def test_c11_capacity_shared_across_seconds_with_exact_tolerance(self):
        ref = self.reference(events=[(9.2, "click", "invented.app", ""),
                                     (10.2, "click", "invented.app", ""),
                                     (11.1, "click", "invented.app", "")])
        self.sample(10, clicks=2)
        row = next(r for r in self.report(reference=ref)["measurements"] if r["check"] == "C11" and r["event_kind"] == "click")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 3))

    def test_c12_context_halo_contains_flag_support(self):
        ref = self.reference([(10, "invented.app", "invented window", "", "ordinary prose")])
        self.sample(10)
        self.screen(-10, "ordinary context outside the selected window")
        folder = self.root / "invented-halo"
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob("window-*.json")).read_text())
        self.assertTrue(bundle["reference"][0]["comparison"]["screen_evidence_within_60s"])
        self.assertEqual(bundle["ours"]["evidence"], [])
        self.assertEqual(bundle["ours"]["screen_evidence_context"][0]["ts"], START - 10)
        self.assertIn("outside", bundle["ours"]["context_note"])

    def test_partial_agent_logs_report_per_source_counts(self):
        claude = self.logs("claude", [self.claude(promptSource="typed")])
        with claude.open("a") as stream:
            stream.write("{invented malformed JSON}\n")
        codex = self.logs("codex", [self.codex()])
        original = Path.open
        def unreadable(path, *args, **kwargs):
            if path == codex:
                raise PermissionError()
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", unreadable):
            report = self.report()
        for tool, malformed, unreadable_count in (("claude", 1, 0), ("codex", 0, 1)):
            for metric in ("typed_instructions_with_keys", "typed_instructions_stored"):
                row = self.metric(report, metric, tool)
                self.assertTrue(row["partial_input"])
                self.assertEqual(row["malformed_source_files"], malformed)
                self.assertEqual(row["unavailable_source_files"], unreadable_count)
                self.assertIn("partial", row["reason"])

    def test_oversized_log_line_is_skipped_and_marks_input_partial(self):
        path = self.logs("claude", [self.claude(promptSource="typed")])
        with path.open("a") as stream:
            stream.write("x" * (fc.MAX_LOG_LINE + 100) + "\n")
        row = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual(row["denominator"], 1)
        self.assertEqual(row["oversized_source_lines"], 1)
        self.assertTrue(row["partial_input"])

    def test_untimed_history_is_unavailable(self):
        history = self.root / "invented-untimed-history"
        history.write_text("invented command one\ninvented command two\n")
        row = self.metric(self.report(references=fc.ReferenceInputs(shell_histories=(history,))), "timestamped_shell_commands_with_keys")
        self.assertEqual(row["reason"], "history not timestamped")
        self.assertIsNone(row["numerator"])
        self.assertIsNone(row["denominator"])
        self.assertEqual(row["untimed_lines"], 2)

    def test_codex_summary_does_not_attach_empty_day_reason_to_counts(self):
        self.logs("codex", [self.codex(10, origin={"kind": "human"})])
        report = self.report(end=172800)
        for line in fc.summary(report).splitlines():
            if line.startswith(("C1 typed_", "C2 typed_")) and "(codex)" in line:
                self.assertIn("/1", line)
                self.assertNotIn("no typed instructions", line)

    def test_reference_live_readonly_wal_and_no_backup(self):
        ref = self.reference()
        with closing(sqlite3.connect(ref)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("INSERT INTO frames(id,timestamp,app_name,focused) VALUES(1,?,'invented.app',1)", (START + 10,))
            writer.commit()
            before = ref.read_bytes(), ref.stat().st_mtime_ns
            with patch.object(shutil, "copyfile", side_effect=AssertionError("must not copy reference")):
                with fc.reference_snapshot(ref) as db:
                    self.assertEqual(len(list(fc.reference_rows(db, "frames", START, START + 20))), 1)
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("DELETE FROM frames")
            self.assertEqual((ref.read_bytes(), ref.stat().st_mtime_ns), before)

    def test_reference_selects_are_time_bounded_and_skip_unselected_text(self):
        ref = self.reference([(10, "invented.app", "window", "", "ordinary selected prose"),
                              (86410, "invented.app", "window", "", "unselected text")])
        day = datetime.fromtimestamp(START, timezone.utc).date().isoformat()
        for indexed in (False, True):
            with self.subTest(indexed=indexed), fc.reference_snapshot(ref) as db, fc.workspace() as work:
                traced = []
                db.set_trace_callback(traced.append)
                rows = list(fc.reference_rows(db, "frames", START, START + 172800, [day],
                            lambda t: datetime.fromtimestamp(t, timezone.utc).date().isoformat(),
                            work=work if indexed else None))
            self.assertEqual(len(rows), 1)
            selects = [q for q in traced if 'FROM "frames"' in q and 'AS "full_text"' in q]
            self.assertTrue(selects)
            if indexed:
                self.assertTrue(all('WHERE rowid=1' in q for q in selects))
            else:
                self.assertTrue(all('CASE WHEN octet_length("timestamp")<=' in q and
                                    '"timestamp">=' in q and '"timestamp"<' in q for q in selects))

    def test_chrome_on_another_volume_falls_back_to_private_file_copy(self):
        chrome = self.chrome([(10, "https://invented.invalid/doc")])
        self.sample(10, document="invented.invalid/doc")
        before = chrome.read_bytes(), chrome.stat().st_mtime_ns
        self.db.commit()
        with fc.readonly(self.database) as db, patch.object(fc, "clone_file", side_effect=fc.CloneUnavailable(errno.EXDEV, "invented")):
            report = fc.analyze(db, self.homes, START, START + 60, references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        row = self.metric(report, "chrome_visits_attributed")
        self.assertEqual((row["numerator"], row["denominator"], row["histories_readable"]), (1, 1, 1))
        self.assertEqual((chrome.read_bytes(), chrome.stat().st_mtime_ns), before)

    def test_product_shared_secret_fixtures_disappear_from_both_bundle_sides(self):
        # Compile only the shared invented fixture declarations, never app code.
        source = self.root / "main.swift"
        source.write_text('import Foundation\nlet rows = RedactionFormatsTest.keys.map { ["rule": $0.rule, "secret": $0.secret, "written": $0.written] }\nprint(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))\n')
        binary = self.root / "invented-fixtures"
        shared = Path(__file__).resolve().parents[1] / "tests/CoreTests/RedactionFormatsFixtures.swift"
        subprocess.run(["swiftc", "-j", "1", "-module-cache-path", str(self.root / "cache"), str(shared), str(source), "-o", str(binary)], check=True, capture_output=True)
        fixtures = json.loads(subprocess.check_output([str(binary)], text=True))
        extra = [("aws", "AKIA0123456789ABCDEF", "AKIA0123456789ABCDEF"),
                 ("installation", "ghs_" + "a" * 25, "ghs_" + "a" * 25),
                 ("client", "inventedClientCredential", "clientSecret=inventedClientCredential"),
                 ("phrase", "invented phrase with spaces", 'passphrase="invented phrase with spaces"'),
                 ("private", "INVENTEDPRIVATEBODY", "-----BEGIN PRIVATE KEY-----\nINVENTEDPRIVATEBODY"),
                 ("basic", "inventedBasicPayload123456789", "Authorization: Basic inventedBasicPayload123456789")]
        fixtures.extend(dict(rule=r, secret=v, written=t) for r, v, t in extra)
        # Separate text rows ensure an unfinished private key cannot hide later fixtures.
        ref = self.reference([(10 + i / 1000, "invented.app", "window", "", "ordinary prose survives " + f["written"]) for i, f in enumerate(fixtures)])
        self.sample(10)
        for i, fixture in enumerate(fixtures):
            self.screen(10 + i / 1000, "ordinary prose survives " + fixture["written"])
        folder = self.root / "invented-secret-bundles"
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob("window-*.json")).read_text())
        reference_side, our_side = json.dumps(bundle["reference"]), json.dumps(bundle["ours"])
        self.assertGreater(len(fixtures), 70)
        for index, fixture in enumerate(fixtures):
            with self.subTest(fixture=index, rule=fixture["rule"]):
                self.assertNotIn(fixture["secret"], reference_side)
                self.assertNotIn(fixture["secret"], our_side)
        self.assertIn("ordinary prose survives", reference_side)
        self.assertIn("ordinary prose survives", our_side)

    def test_chrome_fallback_reads_uncheckpointed_wal_and_cleans_copy(self):
        chrome = self.chrome([])
        self.sample(10, document="invented.invalid/doc")
        self.db.commit()
        with closing(sqlite3.connect(chrome)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("INSERT INTO urls VALUES(1,'https://invented.invalid/doc')")
            writer.execute("INSERT INTO visits VALUES(1,1,?)", ((START + 10 + 11644473600) * 1000000,))
            writer.commit()
            before = chrome.read_bytes(), chrome.stat().st_mtime_ns
            with fc.readonly(self.database) as ours, patch.object(fc, "clone_file", side_effect=fc.CloneUnavailable(errno.EXDEV, "invented")):
                row = self.metric(fc.analyze(ours, self.homes, START, START + 60,
                    references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
            self.assertEqual((row["numerator"], row["denominator"]), (1, 1))
            self.assertEqual((chrome.read_bytes(), chrome.stat().st_mtime_ns), before)

    def test_reference_iso_offsets_spaces_numeric_and_exclusive_boundary(self):
        from datetime import timedelta
        ref = self.reference()
        with closing(sqlite3.connect(ref)) as db, db:
            for index, offset in enumerate((-720, 0, 540, 840)):
                stamp = datetime.fromtimestamp(START + 600, timezone(timedelta(minutes=offset))).isoformat()
                if offset == 540:
                    stamp = stamp.replace("T", " ")
                db.execute("INSERT INTO frames(id,timestamp,app_name,focused) VALUES(?,?,?,1)", (index, stamp, "invented.app"))
            db.execute("INSERT INTO frames(id,timestamp,app_name,focused) VALUES(99,?,?,1)", (START + 600, "invented.app"))
            boundary = datetime.fromtimestamp(START + 601, timezone.utc).isoformat()
            db.execute("INSERT INTO frames(id,timestamp,app_name,focused) VALUES(100,?,?,1)", (boundary, "invented.app"))
        with fc.reference_snapshot(ref) as db:
            rows = list(fc.reference_rows(db, "frames", START + 600, START + 601))
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(row["timestamp_seconds"] == START + 600 for row in rows))

    def test_analysis_spill_deleted_on_success_and_failure(self):
        self.db.commit()
        original = tempfile.TemporaryDirectory
        made = []
        def temporary(*args, **kwargs):
            result = original(*args, **kwargs)
            if kwargs.get("prefix") == "fidelity-analysis-":
                made.append(Path(result.name))
            return result
        with patch.object(fc.tempfile, "TemporaryDirectory", side_effect=temporary):
            self.report()
            with patch.object(fc, "read_logs", side_effect=RuntimeError()), self.assertRaises(RuntimeError):
                self.report()
        self.assertGreaterEqual(len(made), 2)
        self.assertTrue(all(not path.exists() for path in made))

    def test_cli_primary_and_reference_do_not_make_full_copies(self):
        self.db.commit()
        ref = self.reference([(10, "invented.app", "window", "", "ordinary prose")])
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--from", str(START), "--to", str(START + 300)]
        with patch.object(shutil, "copyfile", side_effect=AssertionError()), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args), 0)


    def test_opaque_fuzzy_matching_preserves_edit_distance_semantics(self):
        import random
        rng = random.Random(3)
        for _ in range(500):
            word = "".join(rng.choice("abcde") for _ in range(rng.randrange(3, 9)))
            position = rng.randrange(len(word))
            options = {word, word[:position] + word[position + 1:],
                       word[:position] + "x" + word[position:],
                       word[:position] + "x" + word[position + 1:],
                       word[::-1]}
            for other in options:
                expected = {fc.digest(w) for w in fc.recalled_terms({word}, {other})}
                actual = fc.recalled_identities(fc.term_identities({word}), fc.term_identities({other}))
                self.assertEqual(actual, expected)

    def test_spilled_reference_state_contains_only_opaque_text_identities(self):
        app, title, term = "invented.private.app", "InventedPrivateTitleSentinel", "inventedprivatetermsentinel"
        self.sample(10, app=app, window=title)
        self.screen(10, term, app=app)
        self.probe_attempt(10, [term], app=app)
        self.agent_event(10, json.dumps({"text": term}))
        ref = self.reference([(10, app, title, "", term)], events=[(10, "click", app, title)])
        original = fc.reference_checks
        def checked(*args, **kwargs):
            result = original(*args, **kwargs)
            work = args[-1]
            dumped = "\n".join(work.iterdump())
            for sentinel in (app, title, term):
                self.assertNotIn(sentinel, dumped)
            return result
        with patch.object(fc, "reference_checks", side_effect=checked):
            report = self.report(reference=ref)
        self.assertNotIn(term, json.dumps(report) + fc.summary(report))


    def test_decode_failure_counts_one_unavailable_source_file(self):
        log = self.logs("claude", [self.claude(promptSource="typed")])
        with log.open("ab") as stream:
            stream.write(b"\xff\n")
        row = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual(row["source_files"], 1)
        self.assertEqual(row["readable_source_files"], 0)
        self.assertEqual(row["unavailable_source_files"], 1)
        self.assertTrue(row["partial_input"])


    def test_c8_oversized_history_memory_is_bounded(self):
        shell_scaling_check()

    def test_native_unicode_separators_c6_c9_c12(self):
        fixtures = [('https://invented\u3002invalid/doc/', 'invented.invalid/doc'),
                    ('https://invented\uff61invalid/doc/', 'invented.invalid/doc'),
                    ('https://invented\uff0einvalid/other', 'invented.invalid/doc')]
        chrome = self.chrome([(10 * (i + 1), url) for i, (url, _) in enumerate(fixtures)])
        ref = self.reference([(10 * (i + 1), 'invented.app', 'different title', url, 'ordinary prose')
                              for i, (url, _) in enumerate(fixtures)])
        for i, (_, key) in enumerate(fixtures):
            self.sample(10 * (i + 1), document=key)
        folder = self.root / 'invented-separator-bundles'
        report = self.report(end=300, reference=ref, references=fc.ReferenceInputs(chrome_histories=(chrome,), bundle_dir=folder))
        for metric in ('chrome_visits_attributed', 'reference_frames_attributed'):
            row = self.metric(report, metric)
            self.assertEqual((row['numerator'], row['denominator']), (2, 3))
        bundle = json.loads(next(folder.glob('window-*.json')).read_text())
        self.assertEqual([r['comparison']['matching_document'] for r in bundle['reference']], [True, True, False])

    def test_native_product_keys_cover_host_and_path_forms(self):
        # The actual Swift method supplies each key, including Foundation's case
        # and escaped-host behavior. Check that stored keys need no second parse.
        fixtures = ['https://[2001:db8::1]/doc/', 'https://bücher.invalid/doc/',
                    'https://invented\u3002invalid/', 'https://invented\uff61invalid/doc/',
                    'https://invented\uff0einvalid/doc/', 'https://%62%C3%BCcher.invalid/a%2520b',
                    'https://INVENTED.invalid/A%3Fb%23c///', 'https://faß.invalid/doc/']
        for url in fixtures:
            key = fc.product_helper().document_key(url)
            self.assertTrue(fc.same_document(key, url), url)
            self.assertFalse(fc.same_document(key + '/different', url), url)

    def test_fractional_time_boundaries_c9_c11_c12(self):
        offsets = [9.0, 8.999, 9.001, 11.0, 11.001, 10.999, 11.999]
        self.sample(10)
        ref = self.reference([(offset, 'invented.app', 'invented window', '', 'ordinary prose') for offset in offsets],
                             events=[(offset, 'window_focus', 'invented.app', 'invented window') for offset in offsets] +
                                    [(offset, 'app_switch', 'invented.app', '') for offset in offsets])
        folder = self.root / 'invented-fractional-bundles'
        report = self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        self.assertEqual(self.metric(report, 'reference_frames_attributed')['numerator'], 4)
        rows = [row for row in report['measurements'] if row['check'] == 'C11' and row['event_kind'] != 'click']
        self.assertEqual([row['numerator'] for row in rows], [4, 4])
        bundle = json.loads(next(folder.glob('window-*.json')).read_text())
        expected = [True, False, True, True, False, True, False]
        self.assertEqual([r['comparison']['same_app_within_1s'] for r in bundle['reference']], expected)
        for first, second, tolerance, answer in [(10.25, 11.25, 1, True), (10.25, 11.2501, 1, False),
                                                  (10.25, 9.25, 1, True), (10.25, 9.2499, 1, False),
                                                  (10.25, 15.25, 5, True), (10.25, 15.2501, 5, False),
                                                  (10.25, 70.25, 60, True), (10.25, 70.2501, 60, False)]:
            self.assertEqual(fc.within_time(first, second, tolerance), answer)
            self.assertEqual(fc.near([first], second, tolerance), answer)

    def test_fractional_observations_on_both_sides_c12(self):
        self.sample(10.25)
        offsets = (9.25, 9.249, 11.25, 11.251)
        ref = self.reference([(offset, 'invented.app', 'invented window', '', 'ordinary prose') for offset in offsets])
        folder = self.root / 'invented-fractional-observation-bundles'
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob('window-*.json')).read_text())
        self.assertEqual([row['comparison']['our_samples_within_1s'] for row in bundle['reference']], [1, 0, 1, 0])

    def test_fractional_agent_timestamps_c1_c2(self):
        self.logs('claude', [self.claude(offset, body=f'short request {offset}', promptSource='typed') for offset in (10.25, 20.25, 30.25)])
        self.sample(11.25)
        self.sample(21.25)
        self.sample(31.251)
        self.evidence(11.25, 'claude:invented-10.25')
        self.evidence(21.25, 'claude:invented-20.25')
        self.evidence(31.251, 'claude:invented-30.25')
        report = self.report()
        for metric in ('typed_instructions_with_keys', 'typed_instructions_stored'):
            self.assertEqual(self.metric(report, metric, 'claude')['numerator'], 2)

    def test_sql_oversized_fields_are_counted_once_per_day_and_check(self):
        self.sample(10)
        self.screen(10, 'x' * (fc.MAX_TEXT_FIELD + 1))
        ref = self.reference([(10, 'invented.app', 'invented window', '', 'x' * (fc.MAX_TEXT_FIELD + 1))])
        report = self.report(reference=ref)
        row = self.metric(report, 'informative_term_unweighted_recall')
        self.assertEqual((row['oversized_fields'], row['affected_records']), (2, 2))
        self.assertTrue(row['partial_input'])
        self.assertEqual(self.metric(report, 'reference_frames_attributed')['oversized_fields'], 1)
        with fc.reference_snapshot(ref) as db:
            sql = []
            db.set_trace_callback(sql.append)
            frame = next(fc.reference_rows(db, 'frames', START, START + 60))
            self.assertEqual(frame['full_text'], '')
            self.assertEqual(frame['_oversized_fields'], ['full_text'])
            self.assertTrue(any('substr(' in query and 'length(' in query and 'octet_length(' in query for query in sql))

    def test_all_sql_text_functions_require_case_bounds(self):
        failures = [(line, bad) for line, sql in sql_source_strings(Path(fc.__file__).read_text())
                    for bad in sql_bound_violations(sql)]
        self.assertEqual(failures, [])

    def test_sql_bound_lint_rejects_predicates_joins_ordering_and_grouping(self):
        for function in ('lower', 'julianday', 'substr', 'trim', 'replace', 'hex', 'length', 'invented_function'):
            for clause in ('SELECT {call} FROM samples', 'SELECT 1 FROM samples WHERE {call}=?',
                           'SELECT 1 FROM samples a JOIN evidence b ON {call}=b.source',
                           'SELECT 1 FROM samples ORDER BY {call}', 'SELECT 1 FROM samples GROUP BY {call}'):
                with self.subTest(function=function, clause=clause):
                    self.assertTrue(sql_bound_violations(clause.format(call=function + '(bundle_id)')))
                    self.assertFalse(sql_bound_violations(clause.format(call=fc.guarded_text(function, 'bundle_id'))))
        for call in ('min(app)', 'max(capacity)', 'sum(ts)', '"lower"(bundle_id)'):
            self.assertTrue(sql_bound_violations('SELECT ' + call + ' FROM samples'))
        old = '''def invented(db):
    return bounded_rows(db, 'samples', 'lower(bundle_id)=lower(?)')
'''
        self.assertTrue(any(sql_bound_violations(sql) for _, sql in sql_source_strings(old)))
        self.assertTrue(sql_bound_violations('SELECT 1 WHERE octet_length(bundle_id)<=262144 AND lower(bundle_id)=?'))
        self.assertTrue(sql_bound_violations('SELECT CASE WHEN octet_length(app)<=262144 THEN lower(bundle_id) END'))
        self.assertTrue(sql_bound_violations('SELECT CASE WHEN octet_length(app)<=262144 THEN 1 ELSE lower(app) END'))
        self.assertTrue(sql_bound_violations('SELECT CASE WHEN octet_length(app)<=262144 OR 1 THEN lower(app) END'))
        self.assertTrue(sql_bound_violations('SELECT CASE WHEN NOT octet_length(app)<=262144 THEN lower(app) END'))
        self.assertTrue(sql_bound_violations('SELECT CASE WHEN octet_length(app)<=999999999 THEN lower(app) END'))
        self.assertTrue(sql_bound_violations('SELECT __fidelity_octets_0123456789abcdef(bundle_id)'))

    def test_timestamp_unavailable_records_are_audited_before_range_filtering(self):
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose')])
        with closing(sqlite3.connect(ref)) as db, db:
            # Only values the window's seek can reach are seen; the rest of the reference is never visited.
            stamp = datetime.fromtimestamp(START, timezone.utc).isoformat()
            for index, value in enumerate((stamp + ' not a timestamp', stamp + ' ' * fc.MAX_TEXT_FIELD, 'outside the window', None), 1):
                db.execute("INSERT INTO frames(id,timestamp,focused) VALUES(?,?,1)", (index, value))
        self.sample(30)
        self.db.execute("UPDATE samples SET ts='invalid'")
        report = self.report(reference=ref)
        row = self.metric(report, 'reference_frames_attributed')
        self.assertEqual(row['denominator'], 1)
        self.assertEqual((row['unavailable_records_unplaced'], row['invalid_timestamps'], row['oversized_fields']), (3, 2, 1))
        self.assertTrue(row['partial_input'])

    def test_reference_window_uses_its_time_index_once_and_never_scans(self):
        ref = self.reference([(10, 'invented.app', '', '', 'firstterm'),
                              (20, 'invented.app', '', '', 'secondterm')])
        with fc.reference_snapshot(ref) as db, fc.workspace() as work:
            queries = []
            db.set_trace_callback(queries.append)
            for low, high in ((0, 15), (15, 30), (0, 30)):
                rows = list(fc.time_rows(db, 'frames', ['timestamp'], 'timestamp', START + low, START + high, work, (START, START + 30)))
                self.assertEqual(len(rows), 2 if high - low == 30 else 1)
            window = [query for query in queries if 'AS "rowid"' in query]
            self.assertEqual(len(window), 2)  # One numeric and one text seek.
            self.assertTrue(all('INDEXED BY "frames_time"' in query for query in window))
            plans = [row[3] for query in window for row in db.execute('EXPLAIN QUERY PLAN ' + query)]
            self.assertTrue(all('USING' in plan and 'INDEX frames_time' in plan for plan in plans), plans)

    def test_reference_without_time_index_is_refused_rather_than_scanned(self):
        ref = self.reference([(10, 'invented.app', 'invented window', '', 'ordinary prose')])
        with closing(sqlite3.connect(ref)) as db, db:
            db.execute('DROP INDEX frames_time')
        self.sample(10)
        with fc.reference_snapshot(ref) as db:
            queries = []
            db.set_trace_callback(queries.append)
            self.assertEqual(list(fc.reference_rows(db, 'frames', START, START + 60)), [])
            self.assertFalse([query for query in queries if 'FROM "frames"' in query])
        report = self.report(reference=ref)
        for metric in ('reference_frames_attributed', 'informative_term_weighted_recall'):
            row = self.metric(report, metric)
            self.assertIn('reference timestamp index required', row['reason'])
            self.assertIsNone(row['numerator'])

    def test_real_affinity_text_is_bounded_before_sqlite_conversion(self):
        for declared in ('REAL', 'FLOAT', 'DOUBLE'):
            table = 'invented_' + declared.lower()
            self.db.execute('CREATE TABLE ' + table + '(value ' + declared + ')')
            self.db.executemany('INSERT INTO ' + table + ' VALUES(?)', [('x' * (fc.MAX_TEXT_FIELD + 1),), (12.5,)])
            rows = list(fc.bounded_rows(self.db, table))
            self.assertEqual(rows[0]['_oversized_fields'], ['value'])
            self.assertEqual(rows[0]['value'], '')
            self.assertEqual(rows[1]['value'], 12.5)
            selected = list(fc.bounded_rows(self.db, table, 'value>=?', (0,)))
            self.assertEqual([row['value'] for row in selected], [12.5])

    def test_evidence_apps_read_only_around_the_window(self):
        self.sample(-86400, app='x' * (fc.MAX_TEXT_FIELD + 1))
        self.sample(-3600, app='invented.bundle')
        self.db.execute("UPDATE samples SET app='Invented App' WHERE bundle_id='invented.bundle'")
        self.screen(10, 'ordinary prose', 'INVENTED.BUNDLE')
        self.screen(20, 'ordinary prose', 'INVENTED.BUNDLE')
        ref = self.reference([(10, 'Invented App', '', '', 'ordinary prose')])
        queries = []
        self.db.commit()
        with fc.readonly(self.database) as db, fc.reference_snapshot(ref) as other:
            db.set_trace_callback(queries.append)
            row = self.metric(fc.analyze(db, self.homes, START, START + 120, reference=other), 'informative_term_unweighted_recall')
        self.assertEqual((row['numerator'], row['denominator']), (2, 2))
        self.assertEqual(row['oversized_fields'], 2)
        self.assertTrue(row['partial_input'])
        self.assertFalse(any('lower(' in query.lower() for query in queries))
        self.assertFalse([query for query in queries if 'FROM "samples" NOT INDEXED' in query])

    def renamed_evidence_probe(self, reverse=False):
        samples = [(-86400, 'Earlier Invented App'), (10, 'Current Invented App')]
        for offset, app in reversed(samples) if reverse else samples:
            self.sample(offset, app=app)
        self.db.execute("UPDATE samples SET bundle_id='invented.bundle'")
        self.screen(10, 'distinctivealpha', 'invented.bundle')
        ref = self.reference([(10, 'Current Invented App', 'invented window', '', 'distinctivealpha'),
                              (20, 'Current Invented App', 'invented window', '', 'differentomega')])
        for remove_old in (False, True):
            if remove_old:
                self.db.execute('DELETE FROM samples WHERE ts<?', (START,))
            folder = self.root / ('bundles-' + str(remove_old))
            report = self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
            for metric in ('informative_term_unweighted_recall', 'informative_term_weighted_recall'):
                self.assertAlmostEqual(self.metric(report, metric)['ratio'], .5)
                self.assertFalse(self.metric(report, metric).get('partial_input', False))
            bundle = json.loads(next(folder.glob('window-*.json')).read_text())
            self.assertTrue(bundle['reference'][0]['comparison']['screen_evidence_within_60s'])
            self.assertEqual(self.metric(report, 'reference_frames_attributed')['numerator'], 1)

    def test_temporal_evidence_apps_historical_name_cannot_change_current_recall(self):
        self.renamed_evidence_probe()

    def test_temporal_evidence_apps_reversed_insertion_order(self):
        self.renamed_evidence_probe(reverse=True)

    def test_temporal_evidence_apps_two_day_rename_localization(self):
        # Insert the later localization first to catch both lifetime-first and
        # lifetime-last shortcuts. Evidence keeps the name observed at its time.
        for offset, app in ((86410, '가상 응용 프로그램'), (10, 'Invented Original App')):
            self.sample(offset, app=app)
            self.screen(offset, 'distinctivealpha differentomega', 'invented.bundle')
        self.db.execute("UPDATE samples SET bundle_id='invented.bundle'")
        ref = self.reference([(10, 'Invented Original App', 'invented window', '', 'distinctivealpha'),
                              (20, 'Invented Original App', 'invented window', '', 'differentomega'),
                              (86410, '가상 응용 프로그램', 'invented window', '', 'distinctivealpha'),
                              (86420, '가상 응용 프로그램', 'invented window', '', 'differentomega')])
        folder = self.root / 'bundles'
        report = self.report(end=86700, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        recalls = [r for r in report['measurements'] if r['check'] == 'C10' and r['text_source'] in ('screen', 'all')]
        self.assertEqual(len(recalls), 8)
        self.assertTrue(all(r['ratio'] == 1 for r in recalls), recalls)
        bundles = [json.loads(path.read_text()) for path in folder.glob('window-*.json')]
        self.assertEqual(len(bundles), 2)
        self.assertTrue(all(r['comparison']['screen_evidence_within_60s'] for b in bundles for r in b['reference']))

    def test_temporal_evidence_apps_missing_ambiguous_and_fractional_fallbacks(self):
        for offset, app in ((10.25, 'Original Invented App'), (20, 'Localized Invented App'),
                            (20, 'Conflicting Invented App'), (30, ''), (40, 'Restored Invented App'),
                            (10.25, 'Original Invented App')):
            self.sample(offset, app=app)
        self.db.execute("UPDATE samples SET bundle_id='invented.bundle'")
        with fc.workspace() as work:
            apps = fc.EvidenceApps(self.db, work, fc.InputLimits(lambda ts: 'invented-day', ['invented-day']), START, START + 60)
            fallback = fc.digest('invented.bundle')
            for offset, expected in ((0, fallback), (10.24, fallback),
                                     (10.25, fc.digest('original invented app')),
                                     (19.99, fc.digest('original invented app')),
                                     (20, fallback), (29, fallback), (30, fallback),
                                     (40, fc.digest('restored invented app'))):
                self.assertEqual(apps.at('INVENTED.BUNDLE', START + offset), expected)
            self.assertEqual(apps.at('Direct App Name', START + 50), fc.digest('direct app name'))
            self.assertEqual(work.execute('SELECT count(*) FROM evidence_apps').fetchone()[0], 5)
            dumped = '\n'.join(work.iterdump())
            for sentinel in ('invented.bundle', 'Original Invented App', 'Localized Invented App'):
                self.assertNotIn(sentinel, dumped)

    def halo_caps(self, cap):
        day = lambda stamp: datetime.fromtimestamp(stamp, timezone.utc).date().isoformat()
        target = 'a' * fc.MAX_TERM if cap == 'exact_only_terms' else 'uniquetarget'
        if cap == 'exact_only_terms':
            evidence = target + 'b'
        else:
            def word(index):
                value = ''
                while index:
                    value += chr(ord('a') + index % 26)
                    index //= 26
                return 'inventedterm' + value
            evidence = ' '.join(word(i) for i in range(fc.MAX_TERMS)) + ' ' + target
        # Both midnight directions, outer range boundaries, and a halo on an
        # unselected day between sparse selections. Multiple frames count once.
        for evidence_offset, frame_offset, end, selected in (
                (-10, 10, 120, ()), (130, 110, 120, ()), (86410, 86390, 86400, ()),
                (86390, 86410, 86520, ()), (86410, 86390, 86520, ()),
                (86410, 86390, 259200, (day(START), day(START + 172800))),
                (172790, 172810, 259200, (day(START), day(START + 172800)))):
            with self.subTest(cap=cap, evidence_offset=evidence_offset, selected=selected):
                self.db.execute('DELETE FROM evidence')
                self.screen(evidence_offset, evidence)
                ref = self.root / 'invented-reference.sqlite'
                ref.unlink(missing_ok=True)
                ref = self.reference([(frame_offset, 'invented.app', '', '', target),
                                      (frame_offset + 1, 'invented.app', '', '', 'differentprose')])
                report = self.report(end=end, reference=ref, references=fc.ReferenceInputs(selected_days=selected))
                rows = [r for r in report['measurements'] if r['check'] == 'C10' and r['day'] == day(START + frame_offset)
                        and r['text_source'] in ('screen', 'all')]
                self.assertTrue(rows)
                for row in rows:
                    self.assertEqual(row[cap], 1)
                    self.assertTrue(row['partial_input'])
                    self.assertIn('partial:', row['reason'])
                for row in report['measurements']:
                    if row['check'] == 'C10' and row['day'] != day(START + frame_offset) and row['day'] not in (
                            day(START + evidence_offset - 60), day(START + evidence_offset + 60)):
                        self.assertFalse(row.get(cap))

    def test_c10_exact_only_halo_counts_reach_affected_selected_days(self):
        self.halo_caps('exact_only_terms')

    def test_c10_unsupported_halo_counts_reach_affected_selected_days(self):
        self.halo_caps('unsupported_term_occurrences')

    def test_bounded_reader_metadata_cannot_collide_with_source_columns(self):
        self.db.execute('CREATE TABLE invented_values(__length_0 TEXT)')
        self.db.execute('INSERT INTO invented_values VALUES(?)', ('x' * (fc.MAX_TEXT_FIELD + 1),))
        row = next(fc.bounded_rows(self.db, 'invented_values'))
        self.assertEqual(row['__length_0'], '')
        self.assertEqual(row['_oversized_fields'], ['__length_0'])

    def test_oversized_fields_on_later_day_do_not_taint_earlier_day(self):
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose'),
                              (86410, 'invented.app', '', '', 'x' * (fc.MAX_TEXT_FIELD + 1))])
        report = self.report(end=86520, reference=ref)
        rows = [row for row in report['measurements'] if row['check'] == 'C9']
        self.assertFalse(rows[0].get('partial_input', False))
        self.assertEqual(rows[1]['oversized_fields'], 1)

    def test_oversized_input_on_unselected_day_is_outside_audit_scope(self):
        for offset in (10, 86520, 172810):
            self.sample(offset, window='x' * (fc.MAX_TEXT_FIELD + 1) if offset == 86520 else 'ordinary window')
        day = lambda stamp: datetime.fromtimestamp(stamp, timezone.utc).date().isoformat()
        report = self.report(end=259200, references=fc.ReferenceInputs(selected_days=(day(START), day(START + 172800))))
        rows = [row for row in report['measurements'] if row['check'] == 'C3']
        self.assertTrue(rows)
        self.assertTrue(all(not row.get('partial_input', False) for row in rows))

    def test_long_terms_are_exact_only_and_signature_work_is_bounded(self):
        word = 'a' * 131072
        identities = fc.term_identities({word})
        self.assertEqual(identities[fc.digest(word)], [len(word), []])
        self.assertEqual(fc.recalled_identities(identities, identities), {fc.digest(word)})
        self.assertFalse(fc.recalled_identities(identities, fc.term_identities({word[:-1] + 'b'})))
        self.screen(10, word)
        ref = self.reference([(10, 'invented.app', '', '', word)])
        row = self.metric(self.report(reference=ref), 'informative_term_unweighted_recall')
        self.assertEqual((row['numerator'], row['denominator'], row['exact_only_terms']), (1, 1, 2))
        self.assertTrue(row['partial_input'])

    def test_history_cursors_read_only_predecessor_and_range(self):
        self.db.execute('INSERT INTO log_recording_history VALUES(2,?,0,NULL)', (START + 60,))
        self.db.execute('INSERT INTO log_recording_history VALUES(3,?,1,NULL)', (START + 120,))
        self.db.row_factory = sqlite3.Row
        history = fc.Timeline(self.db, 'log_recording_history', START + 30, START + 180)
        self.assertEqual([history.at(START + second)['enabled'] for second in (30, 59, 60, 119, 120, 179, 40)],
                         [1, 1, 0, 0, 1, 1, 1])

    def test_bounded_record_reader_discards_chunks_and_keeps_next_record(self):
        records = list(fc.bounded_records(io.BytesIO(b'x' * (fc.MAX_RECORD * 3) + b'\nnext\n')))
        self.assertEqual(len(records), 2)
        self.assertTrue(records[0][1])
        self.assertLessEqual(len(records[0][0]), fc.MAX_RECORD + 1)
        self.assertEqual(records[1][0], b'next\n')

    def test_bundle_record_budget_reports_skips(self):
        limits = Counter()
        rows = fc.take_records(({'ts': i} for i in range(fc.MAX_BUNDLE_ROWS + 7)), limits, 'invented')
        self.assertEqual(len(rows), fc.MAX_BUNDLE_ROWS)
        self.assertEqual(limits['invented_skipped_records'], 7)

    def test_bundle_record_budget_preserves_blob_masking(self):
        self.sample(10)
        ref = self.reference([(10, 'invented.app', 'invented window', '', 'ordinary prose')])
        blob = b'invented binary payload'
        self.agent_event(10, 'placeholder')
        self.db.execute('UPDATE agent_log_payloads SET payload=?', (blob,))
        folder = self.root / 'invented-blob-bundles'
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob('window-*.json')).read_text())
        payload = bundle['our_only_candidates']['agent_payloads'][0]['payload']
        self.assertEqual(payload['blob_length'], len(blob))
        self.assertNotIn(blob.decode(), json.dumps(bundle))

    def test_term_count_and_signature_caps_report_unavailable_work(self):
        def word(index):
            result = ''
            while index:
                result += chr(ord('a') + index % 26)
                index //= 26
            return 'inventedterm' + result
        stats = Counter()
        words = fc.informative_terms(' '.join(word(i) for i in range(fc.MAX_TERMS + 7)), stats)
        self.assertEqual(len(words), fc.MAX_TERMS)
        self.assertEqual(stats['unsupported_term_occurrences'], 7)
        signatures = fc.term_identities({'a' * fc.MAX_TERM, 'b' * (fc.MAX_TERM + 1)})
        self.assertEqual(sorted(len(value[1]) for value in signatures.values()), [0, fc.MAX_TERM])

    def test_app_summary_cap_preserves_all_denominators(self):
        ref = self.reference([(10, 'invented.app.' + str(i), '', '', 'ordinary prose')
                              for i in range(fc.MAX_APP_GROUPS + 7)])
        rows = [row for row in self.report(reference=ref)['measurements']
                if row['metric'] == 'informative_term_unweighted_recall']
        self.assertEqual(len(rows), fc.MAX_APP_GROUPS + 1)
        self.assertEqual(sum(row['app_group_count'] for row in rows), fc.MAX_APP_GROUPS + 7)
        self.assertEqual(sum(row['denominator'] for row in rows), 2 * (fc.MAX_APP_GROUPS + 7))

    def word(self, number):
        """Invented terms at least two edits apart, so fuzzy matching cannot blur a count."""
        letters = ''
        for _ in range(3):
            letters += chr(ord('a') + number % 26)
            number //= 26
        return 'term' + letters * 2

    def channels(self, report, metric='informative_term_unweighted_recall'):
        return {channel: self.metric(report, metric + suffix) for channel, suffix in fc.TEXT_CHANNELS.items()}

    def test_c10_reads_screen_text_from_its_blob_not_the_empty_column(self):
        self.screen(10, 'distinctivealpha')
        self.assertEqual(self.db.execute("SELECT text FROM evidence").fetchone()[0], '')
        ref = self.reference([(10, 'invented.app', '', '', 'distinctivealpha'), (11, 'invented.app', '', '', 'differentomega')])
        row = self.metric(self.report(reference=ref), 'informative_term_unweighted_recall')
        self.assertEqual((row['numerator'], row['denominator'], row['text_source']), (1, 2, 'screen'))

    def test_c10_measures_channels_separately_on_the_baseline_shape(self):
        # 1000 terms on one frame, in the shape of the measured baseline (screen 14.5%, AX 74.4%),
        # which pins each channel and the union to a number a change has to explain.
        words = [self.word(i) for i in range(1000)]
        ref = self.reference([(10, 'invented.app', '', '', ' '.join(words)), (11, 'invented.app', '', '', 'differentomega')])
        self.screen(10, ' '.join(words[:145]))
        self.probe_attempt(10, [' '.join(words[100:844])])
        self.agent_event(10, json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": words[844]}]}}))
        rows = self.channels(self.report(reference=ref))
        self.assertEqual({c: rows[c]['numerator'] for c in rows}, {'screen': 145, 'ax_probe': 744, 'agent_log': 1, 'all': 845})
        self.assertTrue(all(rows[c]['denominator'] == 1001 for c in rows))
        self.assertEqual((rows['screen']['text_rows'], rows['ax_probe']['text_rows'], rows['agent_log']['text_rows']), (1, 1, 1))
        self.assertFalse(rows['agent_log']['app_matched'])
        self.assertTrue(rows['ax_probe']['app_matched'])

    def test_c10_all_is_the_union_with_no_double_count(self):
        ref = self.reference([(10, 'invented.app', '', '', 'distinctivealpha distinctivebeta distinctivegamma'),
                              (11, 'invented.app', '', '', 'differentomega')])
        self.screen(10, 'distinctivealpha distinctivebeta')
        self.probe_attempt(10, ['distinctivebeta'])
        self.agent_event(10, json.dumps({"text": "distinctivealpha"}))
        rows = self.channels(self.report(reference=ref))
        self.assertEqual({c: rows[c]['numerator'] for c in rows}, {'screen': 2, 'ax_probe': 1, 'agent_log': 1, 'all': 2})

    def test_c10_ax_structure_and_hashes_are_not_words(self):
        structure = ('attributeRef textRef roleRef nodeID maskHits attributes secure depth storageVersion '
                     'AXStaticTextRoleWord AXValueAttributeWord ocrrefwordnotax')
        hash_like = 'abcdefabcdefabcdef 3f2a9c81b6d04e7f 123e4567-e89b-12d3-a456-426614174000'
        ref = self.reference([(10, 'invented.app', '', '', structure + ' ' + hash_like + ' distinctivealpha'),
                              (11, 'invented.app', '', '', 'differentomega')])
        self.probe_attempt(10, ['distinctivealpha ' + hash_like])
        row = self.metric(self.report(reference=ref), 'informative_term_unweighted_recall_ax_probe')
        self.assertEqual(row['numerator'], 1)

    def test_c10_ax_keeps_to_the_same_app_and_60_seconds_and_skips_pending(self):
        ref = self.reference([(100, 'invented.app', '', '', 'distinctivealpha distinctivebeta distinctivegamma distinctivedelta')])
        self.sample(100, app='invented.app')
        self.probe_attempt(40, ['distinctivealpha'])
        self.probe_attempt(39, ['distinctivebeta'])
        self.sample(95, app='other.app')
        self.probe_attempt(101, ['distinctivegamma'], app='other.app')
        self.probe_attempt(102, ['distinctivedelta'], ax_status='pending')
        row = self.metric(self.report(end=300, reference=ref), 'informative_term_unweighted_recall_ax_probe')
        self.assertEqual((row['numerator'], row['denominator']), (1, 4))

    def test_c10_agent_log_values_only(self):
        ref = self.reference([(10, 'invented.app', '', '', 'distinctivealpha assistant uuidwordinvented'),
                              (11, 'invented.app', '', '', 'differentomega')])
        self.agent_event(10, json.dumps({"type": "assistant", "uuid": "uuidwordinvented", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "distinctivealpha"}]}}))
        row = self.metric(self.report(reference=ref), 'informative_term_unweighted_recall_agent_log')
        self.assertEqual(row['numerator'], 1)

    def test_c10_unparsed_agent_line_still_counts_its_words(self):
        self.assertEqual(fc.agent_log_text('distinctivealpha not json'), 'distinctivealpha not json')

    def test_c10_empty_channel_is_named_not_silent(self):
        ref = self.reference([(10, 'invented.app', '', '', 'distinctivealpha'), (11, 'invented.app', '', '', 'differentomega')])
        row = self.metric(self.report(reference=ref), 'informative_term_unweighted_recall_ax_probe')
        self.assertEqual((row['numerator'], row['denominator'], row['text_rows']), (0, 2, 0))
        self.assertIn('no ax_probe text', row['reason'])

    def test_term_window_agrees_with_recalled_identities(self):
        import random
        rng = random.Random(5)
        for _ in range(300):
            ours = {"".join(rng.choice("abc") for _ in range(rng.randrange(3, 8))) for _ in range(4)}
            word = "".join(rng.choice("abc") for _ in range(rng.randrange(3, 8)))
            identities = fc.term_identities(ours)
            table = {index: (identity, *identities[identity]) for index, identity in enumerate(identities)}
            window = fc.TermWindow(iter([(0.0, json.dumps(list(table)))]), lambda number: table[number])
            window.advance(0.0, 60)
            reference = fc.term_identities({word})
            expected = fc.recalled_identities(reference, identities)
            identity = fc.digest(word)
            self.assertEqual(window.has(identity, *reference[identity]), identity in expected)

    def test_term_window_forgets_rows_that_leave_and_holds_no_empty_entries(self):
        identities = fc.term_identities({'distinctivealpha'})
        (identity, (length, drops)), = identities.items()
        table = {1: (identity, length, drops)}
        window = fc.TermWindow(iter([(0.0, '[1]'), (10.0, '[1]')]), lambda number: table[number])
        window.advance(5.0, 60)
        self.assertTrue(window.has(identity, length, drops))
        window.advance(69.5, 60)
        self.assertTrue(window.has(identity, length, drops))
        window.advance(71.0, 60)
        self.assertFalse(window.has(identity, length, drops))
        self.assertFalse(window.same or window.counts or window.substitutions or window.longer_by_one)

    def test_c12_bundle_carries_screen_text_with_its_masking(self):
        self.sample(10)
        self.screen(10, 'Readable screen words password=inventedsecretvalue')
        self.screen(100, 'Later readable words')
        ref = self.reference([(10, 'invented.app', 'invented window', '', 'ordinary prose')])
        folder = self.root / 'invented-screen-bundles'
        report = self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        text = next(folder.glob('window-*.json')).read_text()
        self.assertIn('Readable screen words [secret]', text)
        self.assertIn('Later readable words', text)
        self.assertNotIn('inventedsecretvalue', text)
        self.assertNotIn('Readable screen', json.dumps(report) + fc.summary(report))

    def test_c12_oversized_screen_blob_is_reported_not_exported(self):
        self.sample(10)
        self.screen(10, 'x' * (fc.MAX_TEXT_FIELD + 1))
        ref = self.reference([(10, 'invented.app', 'invented window', '', 'ordinary prose')])
        folder = self.root / 'invented-large-bundles'
        report = self.report(end=300, references=fc.ReferenceInputs(bundle_dir=folder), reference=ref)
        self.assertNotIn('x' * 1024, next(folder.glob('window-*.json')).read_text())
        self.assertEqual(self.metric(report, 'screen_occurrences_with_text')['oversized_fields'], 1)

    def stored_prompt(self, offset, body=BODY, **fields):
        """A log line and the prompt the recorder stored from it, joined as C2 joins them."""
        line = self.claude(offset, body=body, **fields)
        self.evidence(offset, "claude:invented-" + str(offset), body)
        return line

    def test_c13_groups_come_from_the_log_not_the_text(self):
        lines = [self.stored_prompt(10, "An ordinary typed request", promptSource="typed"),
                 self.stored_prompt(100, "An ordinary request with no keys", promptSource="typed"),
                 self.stored_prompt(110, "A plain dispatched instruction in ordinary prose", isSidechain=True),
                 self.stored_prompt(120, "A plain tool note that looks like prose", isMeta=True),
                 self.stored_prompt(130, "No marker and no provenance at all")]
        self.logs("claude", lines)
        self.sample(10)
        self.evidence(140, "claude:invented-no-line", "Stored with no log line in scope")
        report = self.report()
        person = self.metric(report, "stored_prompts_without_keys_marked_typed")
        self.assertEqual((person["numerator"], person["denominator"]), (1, 2))
        self.assertTrue(person["lower_is_better"])
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_agent")["denominator"], 1)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_machine_notice")["denominator"], 1)
        unknown = self.metric(report, "stored_prompts_without_keys_unknown")
        self.assertEqual((unknown["numerator"], unknown["denominator"], unknown["no_log_line"]), (2, 2, 1))
        self.assertIn("unknown", unknown["reason"])
        self.assertNotIn("ordinary typed", json.dumps(report) + fc.summary(report))

    def test_c13_a_person_quoting_a_notice_is_a_person(self):
        self.logs("claude", [self.stored_prompt(10, "<system-reminder> is what the tool printed, why", promptSource="typed"),
                             self.stored_prompt(20, "Caveat: this came from the tool, please explain", promptSource="typed")])
        report = self.report()
        person = self.metric(report, "stored_prompts_without_keys_marked_typed")
        self.assertEqual((person["numerator"], person["denominator"]), (2, 2))
        self.assertEqual(person["text_starts_like_notice"], 2)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_machine_notice")["denominator"], 0)
        self.assertEqual(report["top_failure_categories"][0]["category"] if report["top_failure_categories"] else None, "instruction_app_unresolved")
        self.assertTrue([item for item in report["top_failure_categories"] if item["category"] == "stored_prompts_without_keys"])

    def test_c13_a_tool_writing_plain_prose_is_not_a_person(self):
        self.logs("claude", [self.stored_prompt(10, "Please continue with the plain looking dispatched work", promptSource="system")])
        report = self.report()
        agent = self.metric(report, "stored_prompts_without_keys_agent")
        self.assertEqual((agent["numerator"], agent["denominator"], agent["text_starts_like_notice"]), (1, 1, 0))
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["denominator"], 0)

    def test_c13_provenance_makes_a_markerless_prompt_an_agents(self):
        self.dated_log("invented-parent", 1, self.dispatched_body(1))
        self.logs("claude", [self.stored_prompt(10)])
        report = self.report()
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_agent")["denominator"], 1)

    def test_c13_keys_do_not_decide_the_group(self):
        # Keys in the same second make the classifier say human, but C13 is about keys.
        lines = [self.stored_prompt(offset, f"Markerless prompt number {offset}") for offset in (10, 20)]
        self.logs("claude", lines)
        self.sample(10)
        self.sample(20)
        report = self.report()
        self.assertEqual(report["classifications"], {"human": 2})
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_unknown")["denominator"], 2)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["denominator"], 0)

    def test_c13_keys_in_another_app_are_reported_apart(self):
        lines = [self.stored_prompt(10, "First request", promptSource="typed"), self.stored_prompt(20, "Second request", promptSource="typed"),
                 self.stored_prompt(100, "A notice while the person types elsewhere", isMeta=True)]
        self.logs("claude", lines)
        self.sample(10, app="invented.terminal")
        self.sample(20, app="invented.terminal")
        self.sample(100, app="invented.other")
        notice = self.metric(self.report(), "stored_prompts_without_keys_machine_notice")
        self.assertEqual((notice["numerator"], notice["denominator"], notice["without_keys_same_app"]), (0, 1, 1))

    def test_c13_same_app_unknown_when_the_session_has_no_app(self):
        self.logs("claude", [self.stored_prompt(10, "Only request", promptSource="typed")])
        self.sample(10)
        person = self.metric(self.report(), "stored_prompts_without_keys_marked_typed")
        self.assertEqual((person["numerator"], person["same_app_unresolved"], person["without_keys_same_app"]), (0, 1, 0))

    def test_c13_only_a_persons_prompts_rank(self):
        self.logs("claude", [self.stored_prompt(10, "A plain note", isMeta=True)])
        report = self.report()
        self.assertFalse(self.metric(report, "stored_prompts_without_keys_machine_notice")["ranked"])
        self.assertNotIn("C13", [item["check"] for item in report["worst_days"]])

    def test_c13_keys_more_than_a_second_away_do_not_count(self):
        self.logs("claude", [self.stored_prompt(11, "near keys request", promptSource="typed"),
                             self.stored_prompt(12, "far keys request", promptSource="typed")])
        self.sample(10)
        row = self.metric(self.report(), "stored_prompts_without_keys_marked_typed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))

    def typed_seconds(self, first, last, keys=1):
        for offset in range(first, last + 1):
            self.sample(offset, keys=keys)

    def test_c3_recorder_dies_and_never_returns(self):
        # Input to minute 30, nothing after, and the copy was taken after the window ended.
        self.typed_seconds(0, 1800)
        report = self.report(end=7200, references=fc.ReferenceInputs(copy_time=START + 7300, copy_time_basis="given"))
        row = self.metric(report, "unexplained_gap_seconds")
        self.assertEqual((row["numerator"], row["denominator"]), (300, 2101))
        self.assertEqual(row["longest_gap_seconds"], 5399)
        self.assertEqual(row["reason"], fc.OUTAGE_BLIND)
        tail = self.metric(report, "seconds_after_last_row")
        self.assertEqual((tail["numerator"], tail["denominator"], tail["copy_after_window_end"], tail["seconds_after_copy_time"]), (5399, 7200, True, 0))
        self.assertIsNone(tail["ratio"])
        unknown = self.metric(report, "no_row_seconds_unknown")
        self.assertEqual((unknown["numerator"], unknown["no_row_spans_over_300_seconds"], unknown["longest_no_row_span_seconds"]), (5399, 1, 5399))
        self.assertIn("unknown", unknown["reason"])
        self.assertIsNone(unknown["ratio"])

    def test_c3_a_copy_taken_before_the_window_ended_cannot_see_past_itself(self):
        self.typed_seconds(0, 1800)
        report = self.report(end=7200, references=fc.ReferenceInputs(copy_time=START + 1900))
        self.assertEqual(self.metric(report, "unexplained_gap_seconds")["numerator"], 100)
        tail = self.metric(report, "seconds_after_last_row")
        self.assertEqual((tail["numerator"], tail["copy_after_window_end"], tail["seconds_after_copy_time"]), (5399, False, 5299))
        self.assertEqual(self.metric(report, "no_row_seconds_unknown")["numerator"], 0)

    def test_c3_an_unknown_copy_time_says_so(self):
        self.typed_seconds(0, 1800)
        report = self.report(end=7200)
        tail = self.metric(report, "seconds_after_last_row")
        self.assertEqual((tail["numerator"], tail["copy_after_window_end"], tail["copy_time_basis"]), (5399, None, "unknown"))

    def test_c3_cli_uses_the_files_last_write_and_an_explicit_time(self):
        self.typed_seconds(0, 10)
        self.db.commit()
        os.utime(self.database, (START + 7300, START + 7300))
        base = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--from", str(START), "--to", str(START + 7200)]
        for extra, basis, after in (([], "last_write", True), (["--copy-time", str(START + 100)], "given", False)):
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(fc.main(base + extra), 0)
            tail = self.metric(json.loads(out.getvalue()), "seconds_after_last_row")
            self.assertEqual((tail["copy_time_basis"], tail["copy_after_window_end"]), (basis, after))

    def test_c3_outage_in_a_rest_span_while_the_person_types(self):
        # 85 min with no row, starting in rest, so no stored input expects anything. Logs and
        # shell history show the person typing throughout.
        self.typed_seconds(0, 300, keys=0)
        self.sample(0)
        self.typed_seconds(6000, 6100)
        typed = [900 + 600 * index for index in range(8)]
        self.logs("claude", [self.claude(offset, body=f"short request {offset}", promptSource="typed") for offset in typed])
        history = self.root / "invented-history"
        history.write_text("".join(f": {START + 950 + 600 * index}:0;invented command\n" for index in range(8)))
        report = self.report(end=7200, references=fc.ReferenceInputs(shell_histories=(history,), copy_time=START + 7300))
        self.assertEqual(self.metric(report, "unexplained_gap_seconds")["numerator"], 300)
        active = self.metric(report, "person_active_seconds_without_row")
        # Shell lines show in by_source and take no part in the total.
        self.assertEqual((active["numerator"], active["denominator"]), (8, 8))
        self.assertEqual(active["by_source"], {"shell_history": {"seconds": 8, "without_row": 8},
                                               "typed_instruction": {"seconds": 8, "without_row": 8}})
        self.assertEqual(active["implied_seconds_without_row"], 8 * 301)
        self.assertIn("person_active_seconds_without_row", [item["category"] for item in report["top_failure_categories"]])
        self.assertTrue(active.get("ranked", True))

    def test_c3_a_silent_span_across_midnight_keeps_its_whole_length_on_both_days(self):
        self.sample(86000)
        self.sample(87000, keys=0)
        report = self.report(end=172800, references=fc.ReferenceInputs(copy_time=START + 87000))
        first, second = [r for r in report["measurements"] if r["metric"] == "no_row_seconds_unknown"]
        # The first day also has the silence from the window's start up to its first row.
        self.assertEqual((first["longest_no_row_span_seconds"], second["longest_no_row_span_seconds"]), (86000, 999))
        self.assertEqual(first["numerator"] + second["numerator"], 86000 + 999)
        self.assertEqual(second["numerator"], 600)
        day_one = [r for r in report["measurements"] if r["metric"] == "unexplained_gap_seconds"][0]
        self.assertEqual((day_one["numerator"], day_one["longest_gap_seconds"]), (300, 999))

    def test_c3_outage_mid_input_keeps_its_real_length(self):
        self.typed_seconds(0, 1000)
        self.typed_seconds(5201, 5300)
        row = self.metric(self.report(end=7200, references=fc.ReferenceInputs(copy_time=START + 7300)), "unexplained_gap_seconds")
        self.assertEqual(row["numerator"], 300 + 300)
        self.assertEqual(row["longest_gap_seconds"], 4200)
        self.assertEqual(row["gap_runs"], 2)

    def test_c3_every_independent_source_counts_and_a_row_clears_it(self):
        ref = self.reference(events=[(100, "click", "invented.app", "w"), (200, "key", "invented.app", "w"),
                                     (300, "window_focus", "invented.app", "w"), (400, "invented_unknown", "invented.app", "w")])
        chrome = self.chrome([(500, "https://invented.invalid/a"), (600, "https://invented.invalid/b")])
        self.sample(603, keys=0)
        report = self.report(end=1000, reference=ref, references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        active = self.metric(report, "person_active_seconds_without_row")
        self.assertEqual(active["by_source"], {"chrome_visit": {"seconds": 2, "without_row": 1},
                                               "reference_input": {"seconds": 2, "without_row": 2}})
        self.assertEqual((active["numerator"], active["denominator"]), (2, 2))

    def test_c3_seconds_after_the_last_row_say_how_many_are_explained(self):
        self.sample(0)
        self.db.execute("INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,0,NULL)", (START + 100,))
        report = self.report(end=1000, references=fc.ReferenceInputs(copy_time=START + 2000))
        tail = self.metric(report, "seconds_after_last_row")
        self.assertEqual((tail["numerator"], tail["paused_off_or_erased_seconds"]), (999, 900))
        self.assertEqual(self.metric(report, "no_row_seconds_unknown")["numerator"], 0)

    def test_c3_paused_seconds_do_not_make_a_person_active_finding(self):
        self.db.execute("INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,1,?)", (START + 100, START + 150))
        self.logs("claude", [self.claude(110, promptSource="typed")])
        self.sample(500, keys=0)
        active = self.metric(self.report(end=1000), "person_active_seconds_without_row")
        self.assertEqual((active["numerator"], active["denominator"]), (0, 0))

    def test_c3_without_independent_sources_it_says_so(self):
        self.sample(0)
        active = self.metric(self.report(end=1000), "person_active_seconds_without_row")
        self.assertEqual(active["reason"], fc.NO_SIGNALS)
        self.assertIsNone(active["ratio"])

    def test_c3_rest_stays_unknown_and_never_ranks(self):
        for offset in range(0, 301):
            self.sample(offset, keys=int(offset == 0))
        self.sample(5000, keys=0)
        report = self.report(end=6000)
        self.assertEqual(self.metric(report, "no_row_seconds_unknown")["numerator"], 5000 - 301)
        self.assertFalse(report["worst_days"] and report["worst_days"][0]["metric"] == "no_row_seconds_unknown")
        self.assertIn("no_row_seconds_unknown", fc.summary(report))

    def program_row(self, offset, keys, synthetic, observed=None):
        self.sample(offset, keys=keys)
        self.db.execute("UPDATE samples SET synthetic=?,observed_ts=? WHERE ts=?", (synthetic, observed, START + offset))

    def test_program_made_keys_are_not_a_persons_in_old_rows(self):
        self.logs("claude", [self.stored_prompt(10, "A request while a program types", promptSource="typed")])
        self.program_row(10, keys=3, synthetic=5)
        report = self.report()
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["numerator"], 1)
        self.assertEqual(self.metric(report, "input_seconds_missing_app")["denominator"], 0)
        self.assertEqual(self.metric(report, "unexplained_gap_seconds")["denominator"], 0)

    def test_keys_above_program_events_are_a_persons(self):
        self.program_row(10, keys=9, synthetic=5)
        self.assertEqual(self.metric(self.report(), "input_seconds_missing_app")["denominator"], 1)

    def test_rows_the_recorder_writes_now_already_hold_only_person_keys(self):
        # ActivityStorage.insertSample rewrites the counts from person events for these rows.
        self.logs("claude", [self.stored_prompt(10, "A request beside a program", promptSource="typed")])
        self.program_row(10, keys=1, synthetic=5, observed=START + 10)
        report = self.report()
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["numerator"], 0)
        self.assertEqual(self.metric(report, "input_seconds_missing_app")["denominator"], 1)

    def test_c5_a_dropped_capture_is_a_loss_in_the_denominator(self):
        self.screen(10, "ordinary invented prose")
        evidence = self.db.execute("SELECT id FROM evidence").fetchone()[0]
        self.probe_attempt(10, evidence_id=evidence)
        self.probe_attempt(20, refusal="dropped")
        self.probe_attempt(30, refusal="no_person_input")
        self.probe_attempt(40, refusal="key_changed")
        self.probe_attempt(50, refusal="failed")
        report = self.report()
        row = self.metric(report, "acquired_captures_dropped")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))
        self.assertTrue(row["lower_is_better"])
        self.assertEqual((row["refused_by_design"], row["refusal_reasons"], row["capture_failed"]),
                         (2, {"no_person_input": 1, "key_changed": 1}, 1))
        self.assertEqual({item["category"]: item["count"] for item in report["top_failure_categories"]}["screen_captures_dropped"], 1)
        self.assertEqual(self.metric(report, "acquired_captures_linked")["numerator"], 1)

    def test_c5_a_day_of_only_refusals_does_not_say_there_were_no_attempts(self):
        self.probe_attempt(10, refusal="no_person_input")
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertIsNone(row["denominator"])
        self.assertEqual(row["reason"], fc.NO_TEXT_ATTEMPTS)
        self.assertEqual(row["refused_by_design"], 1)

    def test_c5_drops_cannot_leave_the_rate_healthy(self):
        for offset in range(10):
            self.probe_attempt(offset, refusal="dropped")
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertEqual((row["numerator"], row["denominator"], row["ratio"]), (0, 10, 0))

    def test_c5_completed_without_a_link_is_not_called_a_loss(self):
        self.probe_attempt(10)
        report = self.report()
        linked, dropped = self.metric(report, "acquired_captures_linked"), self.metric(report, "acquired_captures_dropped")
        self.assertEqual((linked["numerator"], linked["denominator"], linked["unlinked_unknown"]), (0, 1, 1))
        self.assertEqual((dropped["numerator"], dropped["denominator"]), (0, 1))
        self.assertIn(fc.UNLINKED_CAPTURES, linked["reason"])
        self.assertFalse(linked["ranked"])
        self.assertNotIn("acquired_captures_linked", [item["metric"] for item in report["worst_days"]])

    def test_c5_a_stored_capture_that_lost_its_link_is_counted_apart(self):
        self.screen(10, "stored but not linked")
        self.screen(20, "linked to its own attempt")
        self.screen(30, "another app at the same second", app="invented.other")
        identities = {row[0]: row[1] for row in self.db.execute("SELECT ts,id FROM evidence")}
        self.probe_attempt(10)
        self.probe_attempt(20, evidence_id=identities[START + 20])
        self.probe_attempt(30)
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertEqual((row["numerator"], row["denominator"], row["unlinked_with_stored_capture"], row["unlinked_unknown"]), (1, 3, 1, 1))

    def test_c5_reads_the_run_drop_counters(self):
        self.probe_attempt(10, refusal="dropped")
        for event, total in (("ocr_dropped", 7), ("droppedOCR", 7), ("pendingDropped", 2), ("busyOCR", 40)):
            self.db.execute("INSERT INTO ax_probe_flow(run_id,event,total) VALUES('invented-run',?,?)", (event, total))
        report = self.report()
        row = self.metric(report, "probe_run_drop_counters")
        self.assertEqual(row["counters"], {"droppedOCR": 7, "ocr_dropped": 7, "pendingDropped": 2, "overload_dropped": 0})
        self.assertEqual(row["probe_runs"], 1)
        self.assertIsNone(row["ratio"])
        self.assertIsNone(row["day"])

    def test_c5_unreadable_attempts_are_counted_and_partial(self):
        attempt = self.probe_attempt(10)
        self.db.execute("UPDATE ax_probe_attempts SET payload='[1]' WHERE id=?", (attempt,))
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertEqual(row["unreadable_attempts"], 1)
        self.assertTrue(row["partial_input"])

    def test_c5_oversized_attempts_mark_c5_partial(self):
        attempt = self.probe_attempt(10)
        self.db.execute("UPDATE ax_probe_attempts SET payload=? WHERE id=?", (json.dumps({"filler": "x" * (fc.MAX_TEXT_FIELD + 1)}), attempt))
        row = self.metric(self.report(), "acquired_captures_linked")
        self.assertTrue(row["partial_input"])
        self.assertEqual(row["oversized_fields"], 1)

    def test_c5_an_empty_blob_is_not_readable_text(self):
        self.screen(10, "")
        self.screen(20, "ordinary invented prose")
        row = self.metric(self.report(), "screen_occurrences_with_text")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))

    def test_c1_c2_carry_the_unknown_count_and_are_partial(self):
        self.logs("claude", [self.claude(10, promptSource="typed"), self.claude(20)])
        report = self.report()
        for metric in ("typed_instructions_with_keys", "typed_instructions_stored"):
            row = self.metric(report, metric, "claude")
            self.assertEqual((row["denominator"], row["unknown_instructions"]), (1, 1))
            self.assertTrue(row["partial_input"])
            self.assertIn("unknown sender", row["reason"])
        codex = self.metric(report, "typed_instructions_stored", "codex")
        self.assertEqual(codex["unknown_instructions"], 0)
        self.assertFalse(codex["partial_input"])

    def test_c2_all_unknown_is_not_reported_as_no_instructions(self):
        self.logs("claude", [self.claude(10)])
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["unknown_instructions"]), (0, 0, 1))
        self.assertNotEqual(row["reason"], "no typed instructions")

    def test_instructions_before_a_narrow_window_still_name_the_session_app(self):
        # One instruction in the window is one vote, too few. An earlier one is its second.
        self.logs("claude", [self.claude(-3600, body="An earlier markerless request from this person"), self.claude(10)])
        self.sample(-3600)
        self.sample(10)
        report = self.report()
        self.assertEqual(report["classifications"], {"human": 1})
        self.assertEqual(self.metric(report, "typed_instructions_stored", "claude")["denominator"], 1)

    def test_a_wider_vote_never_measures_the_instructions_outside_the_window(self):
        self.logs("claude", [self.claude(-3600, promptSource="typed", body="An earlier typed request from this person"), self.claude(10, promptSource="typed")])
        self.sample(-3600)
        self.assertEqual(self.metric(self.report(), "typed_instructions_with_keys", "claude")["denominator"], 1)

    def test_votes_stay_inside_the_lookback(self):
        self.dated_log("invented-session", 10, self.claude(-90000, body="A much older markerless request"), self.claude(10))
        self.sample(-90000)
        self.sample(10)
        self.assertEqual(self.report()["classifications"], {"unknown": 1})

    def test_logs_only_out_of_scope_do_not_read_as_unreadable(self):
        self.dated_log("invented-old", -2 * 86400, self.claude(-2 * 86400, promptSource="typed"))
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual(row["reason"], "no agent logs in scope")
        self.assertEqual(self.metric(self.report(), "typed_instructions_stored", "codex")["reason"], "no readable agent logs")

    def test_logs_whose_first_line_is_after_the_window_are_counted(self):
        # A resumed log with a new line copied to its top, then an older line inside the window.
        self.dated_log("invented-resumed", 90000, self.claude(90000, promptSource="typed"), self.claude(10, promptSource="typed"))
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["denominator"], row["log_files_outside_scope"], row["log_files_starting_after_window"]), (0, 1, 1))
        self.assertEqual(self.metric(self.report(references=fc.ReferenceInputs(all_logs=True)), "typed_instructions_stored", "claude")["denominator"], 1)

    def closed_wal(self, path):
        with closing(sqlite3.connect(path)) as db:
            db.execute("PRAGMA journal_mode=WAL").fetchall()
        return {item.name for item in path.parent.iterdir()}

    def test_chrome_closed_wal_history_leaves_no_side_files(self):
        chrome = self.chrome([(10, "https://invented.invalid/doc")])
        listing = self.closed_wal(chrome)
        self.assertFalse((self.root / (chrome.name + "-wal")).exists())
        before = chrome.read_bytes(), chrome.stat().st_mtime_ns
        self.sample(10, document="invented.invalid/doc")
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))
        self.assertEqual({item.name for item in chrome.parent.iterdir()}, listing)
        self.assertEqual((chrome.read_bytes(), chrome.stat().st_mtime_ns), before)

    def test_chrome_locked_profile_reads_through_its_clone(self):
        chrome = self.chrome([(10, "https://invented.invalid/doc")])
        writer = sqlite3.connect(chrome, isolation_level=None)
        self.addCleanup(writer.close)
        writer.execute("PRAGMA journal_mode=WAL").fetchall()
        writer.execute("PRAGMA locking_mode=EXCLUSIVE").fetchall()
        writer.execute("BEGIN EXCLUSIVE")
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
        self.assertEqual(row["denominator"], 1)
        self.assertEqual(row["histories_unreadable"], 0)

    def test_primary_refuses_when_it_cannot_be_cloned(self):
        self.sample(10)
        self.db.commit()
        self.db.close()
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("PRAGMA journal_mode=WAL").fetchall()
        listing = {item.name for item in self.database.parent.iterdir()}
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--from", str(START), "--to", str(START + 60)]
        out, err = io.StringIO(), io.StringIO()
        with patch.object(fc, "clone_file", side_effect=fc.CloneUnavailable(errno.EXDEV, "invented")), redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(fc.main(args), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("--input-is-private-copy", err.getvalue())
        self.assertNotIn(str(self.root), err.getvalue())
        self.assertEqual({item.name for item in self.database.parent.iterdir()}, listing)
        with patch.object(fc, "clone_file", side_effect=fc.CloneUnavailable(errno.EXDEV, "invented")), redirect_stdout(out), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args + ["--input-is-private-copy"]), 0)
        self.assertIn("measurements", out.getvalue())
        self.db = sqlite3.connect(self.database)

    def test_clone_retakes_a_database_without_a_log_that_changed_during_it(self):
        path = self.reference([(10, "invented.app", "", "", "first")])
        writer = sqlite3.connect(path, isolation_level=None)
        self.addCleanup(writer.close)
        real, calls = fc.clone_file, []
        def committing(source, target):
            real(source, target)
            calls.append(str(source))
            if len(calls) == 1:
                os.utime(path, ns=(1, path.stat().st_mtime_ns + 1000))
        with patch.object(fc, "clone_file", side_effect=committing):
            with fc.private_clone(path) as clone, closing(sqlite3.connect(clone)) as copy:
                self.assertEqual(copy.execute("SELECT count(*) FROM frames").fetchone()[0], 1)
        self.assertEqual(calls.count(str(path.absolute())), 2)

    def test_clone_gives_up_on_a_database_without_a_log_that_keeps_changing(self):
        path = self.reference()
        real = fc.clone_file
        def always(source, target):
            real(source, target)
            os.utime(path, ns=(1, path.stat().st_mtime_ns + 1000))
        with patch.object(fc, "clone_file", side_effect=always), patch.object(fc.time, "sleep"), self.assertRaises(OSError):
            with fc.private_clone(path):
                self.fail("an unstable clone was used")

    def test_card_number_inside_a_json_value_is_masked(self):
        card = "4242424242424242"
        for value in (f"[{card}]", f'{{"value":{card}}}', f'{{"a":[1,{{"b":{card}}}]}}', f'[{{"v":"{card}"}}]'):
            with self.subTest(shape=value[:6]):
                self.assertNotIn(card, json.dumps(fc.masked_tree(value)))
        self.assertEqual(fc.masked_tree('{"count":3,"ok":true,"none":null}'), {"count": 3, "ok": True, "none": None})
        self.assertEqual(fc.masked_tree({"start_ts": 1969660800}), {"start_ts": 1969660800})

    def test_card_number_inside_a_reference_frame_does_not_reach_a_bundle(self):
        card = "4242424242424242"
        ref = self.reference([(10, "invented.app", "invented window", "", f'{{"value":{card}}}')])
        self.sample(10)
        folder = self.root / "invented-card-bundles"
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        self.assertNotIn(card, next(folder.glob("window-*.json")).read_text())

    # Machine notices. The review's scenario: plain text with typed markers and no keys.
    NOTICE = "Worker finished task {} with status done, see delivery {} for the details please"

    def typed_line(self, offset, body, stem="invented-session", **fields):
        """A typed-marked line in this session's log, and the prompt the recorder stored from it."""
        self.evidence(offset, "claude:invented-" + str(offset), body, source=stem)
        return {**self.claude(offset, body=body, promptSource="typed", **fields), "sessionId": stem}

    def seven_notices(self):
        groups = {"invented-first": [], "invented-second": []}
        for index in range(7):
            stem = "invented-first" if index < 5 else "invented-second"
            body = self.NOTICE.format(index + 100, format(0xabc123 + index, "x"))
            groups[stem].append(self.typed_line(10 + index * 20, body, stem))
        for stem, lines in groups.items():
            self.logs("claude", lines, stem=stem)

    def test_plain_notices_marked_typed_are_not_typed_instructions(self):
        self.seven_notices()
        report = self.report()
        c1, c2 = self.metric(report, "typed_instructions_with_keys", "claude"), self.metric(report, "typed_instructions_stored", "claude")
        self.assertEqual((c1["numerator"], c1["denominator"]), (0, 0))
        self.assertEqual((c2["numerator"], c2["denominator"]), (0, 0))
        self.assertEqual((c1["repeated_text_instructions"], c2["repeated_text_instructions"]), (7, 7))
        self.assertTrue(c1["partial_input"])
        self.assertIn("repeated", c1["reason"])
        self.assertNotIn("typed_instruction", self.metric(report, "person_active_seconds_without_row")["by_source"])
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["denominator"], 0)
        repeated = self.metric(report, "stored_prompts_without_keys_repeated_text")
        self.assertEqual((repeated["numerator"], repeated["denominator"], repeated["ranked"]), (7, 7, False))
        self.assertEqual([item for item in report["worst_days"] if item["defect_ratio"]], [])
        categories = [item["category"] for item in report["top_failure_categories"]]
        for category in ("stored_prompts_without_keys", "instruction_app_unresolved", "instruction_without_keys", "missing_prompt_evidence"):
            self.assertNotIn(category, categories)
        self.assertNotIn("Worker finished", json.dumps(report) + fc.summary(report))

    def test_repeated_text_counts_lines_before_the_window(self):
        # Two earlier deliveries in a log still being written, one inside a narrow window.
        lines = [self.claude(offset, body=self.NOTICE.format(offset + 100000, "abc123"), promptSource="typed") for offset in (-80000, -3000)]
        lines.append(self.typed_line(10, self.NOTICE.format(5, "def456")))
        self.logs("claude", lines)
        report = self.report()
        self.assertEqual(self.metric(report, "typed_instructions_with_keys", "claude")["denominator"], 0)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_repeated_text")["denominator"], 1)

    def test_repeated_text_needs_three_and_a_person_can_reach_them(self):
        body = "Please rewrite the invented report so each section starts with its main finding"
        self.assertEqual(fc.REPEATED_TEXT_MIN, 3)
        lines = [self.typed_line(10, body), self.typed_line(100, body)]
        self.logs("claude", lines)
        c1 = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual((c1["denominator"], c1["repeated_text_instructions"]), (2, 0))
        # The limit, stated: a person pasting one long instruction three times looks like a notice.
        self.logs("claude", lines + [self.typed_line(150, body)])
        c1 = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual((c1["denominator"], c1["repeated_text_instructions"]), (0, 3))

    def test_a_person_repeating_a_short_word_stays_typed(self):
        self.logs("claude", [self.typed_line(10 + index, "continue") for index in range(10)])
        report = self.report()
        c1 = self.metric(report, "typed_instructions_with_keys", "claude")
        self.assertEqual((c1["denominator"], c1["repeated_text_instructions"]), (10, 0))
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_marked_typed")["denominator"], 10)

    def test_copies_of_one_line_are_one_occurrence(self):
        # Resumed sessions copy a line with its identity, and Codex writes one message three ways.
        line = self.claude(10, body=BODY, promptSource="typed")
        for stem in ("invented-one", "invented-two", "invented-three"):
            self.logs("claude", [line], stem=stem)
        self.assertEqual(self.metric(self.report(), "typed_instructions_with_keys", "claude")["denominator"], 1)
        shutil.rmtree(self.homes["claude"][0])
        words = [{"type": "input_text", "text": BODY}]
        self.logs("codex", [dict(type="session_meta", timestamp=START + 9, payload=dict(id="invented-session", originator="human")),
                            self.codex(10, origin={"kind": "human"}),
                            dict(type="event_msg", timestamp=START + 10, payload=dict(type="user_message", message=BODY, origin={"kind": "human"})),
                            dict(type="response_item", timestamp=START + 10, payload=dict(role="user", content=words, origin={"kind": "human"}))])
        row = self.metric(self.report(), "typed_instructions_with_keys", "codex")
        self.assertEqual((row["denominator"], row["repeated_text_instructions"]), (1, 0))

    def test_one_message_written_at_slightly_different_times_is_one_use(self):
        words = [{"type": "input_text", "text": BODY}]
        self.logs("codex", [dict(type="session_meta", timestamp=START + 9, payload=dict(id="invented-session", originator="human")),
                            self.codex(10.1, origin={"kind": "human"}),
                            dict(type="event_msg", timestamp=START + 10.4, payload=dict(type="user_message", message=BODY, origin={"kind": "human"})),
                            dict(type="response_item", timestamp=START + 10.7, payload=dict(role="user", content=words, origin={"kind": "human"}))])
        self.assertEqual(self.metric(self.report(), "typed_instructions_with_keys", "codex")["repeated_text_instructions"], 0)

    def test_a_person_dispatched_to_subagents_is_not_repeated_text(self):
        # Copies a tool marked as its own say nothing about the one line a person typed.
        self.logs("claude", [self.typed_line(10, BODY)])
        for offset, stem in ((20, "invented-worker-one"), (30, "invented-worker-two")):
            self.logs("claude", [{**self.claude(offset, isSidechain=True), "sessionId": stem}], stem=stem)
        self.assertEqual(self.metric(self.report(), "typed_instructions_with_keys", "claude")["denominator"], 1)

    def test_a_notice_beside_keys_does_not_name_the_sessions_app(self):
        # Three notices land while the person types in another app; two real instructions are in this one.
        lines = [self.typed_line(offset, self.NOTICE.format(offset, "abc123")) for offset in (10, 20, 30)]
        lines += [self.typed_line(100, "first short request"), self.typed_line(110, "second short request")]
        self.logs("claude", lines)
        for offset in (10, 20, 30):
            self.sample(offset, app="invented.other")
        self.sample(100, app="invented.terminal")
        self.sample(110, app="invented.terminal")
        row = self.metric(self.report(), "typed_instructions_with_keys", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["session_app_unresolved"]), (2, 2, 0))

    def test_repeated_text_without_a_marker_is_not_also_unknown(self):
        self.logs("claude", [self.stored_prompt(offset, self.NOTICE.format(offset, "abc123")) for offset in (10, 20, 30)])
        report = self.report()
        c1 = self.metric(report, "typed_instructions_with_keys", "claude")
        self.assertEqual((c1["unknown_instructions"], c1["repeated_text_instructions"]), (0, 3))
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_unknown")["denominator"], 0)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_repeated_text")["denominator"], 3)
        self.assertEqual(report["classifications"], {"repeated_text": 3})

    def test_a_queued_notice_was_never_in_the_typed_denominator(self):
        self.logs("claude", [self.stored_prompt(offset, self.NOTICE.format(offset, "abc123"), promptSource="queued") for offset in (10, 20, 30)])
        report = self.report()
        c1 = self.metric(report, "typed_instructions_with_keys", "claude")
        self.assertEqual((c1["denominator"], c1["repeated_text_instructions"]), (0, 0))
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_queued")["denominator"], 0)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_repeated_text")["denominator"], 3)

    def test_provenance_still_says_agent_for_repeated_text(self):
        self.dated_log("invented-parent", 1, self.dispatched_body(1))
        self.logs("claude", [self.stored_prompt(offset) for offset in (10, 20, 30)])
        report = self.report()
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_agent")["denominator"], 3)
        self.assertEqual(self.metric(report, "stored_prompts_without_keys_repeated_text")["denominator"], 0)
        self.assertEqual(self.metric(report, "typed_instructions_with_keys", "claude")["repeated_text_instructions"], 0)

    # One long text pasted into several sessions, beside ordinary typed lines the recorder stored.
    PASTED = "Please review the invented plan again and report anything that still looks wrong today"

    def pasted_sessions(self, sessions, stored, others=14, **fields):
        """Each session names its app with one typed line, and the pasted line has keys in that app."""
        lines = {"invented-session-" + str(index): [] for index in range(max(sessions, 1))}
        names = list(lines)
        for index in range(others):
            stem = names[index % len(names)]
            lines[stem].append(self.typed_line(10 + index * 5, f"ordinary request number {index}", stem))
        for index in range(sessions):
            offset, stem = 100 + index * 5, names[index]
            line = {**self.claude(offset, body=self.PASTED, **fields), "sessionId": stem}
            if stored:
                self.evidence(offset, "claude:invented-" + str(offset), self.PASTED, source=stem)
            lines[stem].append(line)
        for stem, session in lines.items():
            self.logs("claude", session, stem=stem)
        # A row every second, so that silence is not what ranks here.
        keyed = {10 + index * 5 for index in range(others)} | {100 + index * 5 for index in range(sessions)}
        for offset in range(180):
            self.sample(offset, keys=int(offset in keyed))

    def stored_counts(self, report, name):
        row = self.metric(report, name, "claude")
        return row["numerator"], row["denominator"]

    def test_repeated_text_lost_in_three_sessions_is_a_failure(self):
        self.pasted_sessions(3, stored=False, promptSource="typed")
        report = self.report()
        self.assertEqual(self.stored_counts(report, "repeated_text_instructions_stored"), (0, 3))
        # Outside the main ratios, even with keys in the same app.
        self.assertEqual(self.stored_counts(report, "typed_instructions_stored"), (14, 14))
        self.assertEqual(self.stored_counts(report, "typed_instructions_with_keys"), (14, 14))
        self.assertEqual(report["top_failure_categories"], [dict(category="missing_prompt_evidence", count=3)])
        worst = report["worst_days"][0]
        self.assertEqual((worst["metric"], worst["numerator"], worst["denominator"]), ("repeated_text_instructions_stored", 0, 3))
        self.assertNotIn("invented plan", json.dumps(report) + fc.summary(report))

    def test_repeated_text_stored_in_three_sessions_is_not_a_failure(self):
        self.pasted_sessions(3, stored=True, promptSource="typed")
        report = self.report()
        row = self.metric(report, "repeated_text_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["equal_digest"], row["identity_matched_content_changed"]), (3, 3, 3, 0))
        self.assertEqual(self.stored_counts(report, "typed_instructions_stored"), (14, 14))
        self.assertEqual(report["top_failure_categories"], [])
        self.assertEqual([item for item in report["worst_days"] if item["defect_ratio"]], [])

    def test_two_uses_stay_in_c2_and_leave_the_repeated_row_empty(self):
        self.pasted_sessions(2, stored=False, promptSource="typed")
        report = self.report()
        self.assertEqual(self.stored_counts(report, "typed_instructions_stored"), (14, 16))
        row = self.metric(report, "repeated_text_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["ratio"], row["reason"]), (0, 0, None, "empty denominator"))
        self.assertFalse(row["partial_input"])
        self.assertEqual(report["top_failure_categories"], [dict(category="missing_prompt_evidence", count=2)])

    def test_one_repeated_line_in_a_day_is_a_count(self):
        # The other uses are before the window, so this day has just the one line.
        lines = [self.claude(offset, body=self.NOTICE.format(offset + 100000, "abc123"), promptSource="typed") for offset in (-80000, -3000)]
        lines.append(self.typed_line(10, self.NOTICE.format(5, "def456")))
        self.logs("claude", lines)
        row = self.metric(self.report(), "repeated_text_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["ratio"]), (1, 1, 1))
        self.assertIn('"numerator": 1,', json.dumps(row))

    def test_the_repeated_row_covers_lines_with_no_marker(self):
        self.pasted_sessions(3, stored=False, others=3)
        self.assertEqual(self.stored_counts(self.report(), "repeated_text_instructions_stored"), (0, 3))

    def test_the_repeated_row_leaves_out_queued_lines_as_c2_does(self):
        self.pasted_sessions(3, stored=False, others=3, promptSource="queued")
        self.assertEqual(self.stored_counts(self.report(), "repeated_text_instructions_stored"), (0, 0))

    def test_the_repeated_row_says_when_its_inputs_are_partial_or_absent(self):
        self.pasted_sessions(3, stored=True, promptSource="typed")
        folder = self.homes["claude"][0] / "projects"
        (folder / "invented-session-0.jsonl").open("a").write("not json, invented\n")
        row = self.metric(self.report(), "repeated_text_instructions_stored", "claude")
        self.assertTrue(row["partial_input"])
        self.assertIn("partial", row["reason"])
        self.assertEqual((row["log_scope"], row["source_files"]), ("window", 3))
        self.db.execute("DROP TABLE evidence")
        row = self.metric(self.report(), "repeated_text_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["ratio"]), (None, 3, None))
        self.assertIn("channel absent: prompt evidence", row["reason"])

    def test_sparse_instructions_are_not_named_as_unable_to_speak(self):
        self.sample(10)
        self.logs("claude", [self.claude(10, promptSource="typed")])
        active = self.metric(self.report(end=3600), "person_active_seconds_without_row")
        self.assertTrue(active["sources"]["typed_instruction"]["cannot_speak_for_rest"])
        self.assertIsNone(active["reason"])
        events = [(offset, "key", "invented.app", "w") for offset in range(0, 600, 5)]
        active = self.metric(self.report(end=3600, reference=self.reference(events=events), references=fc.ReferenceInputs(copy_time=START + 3700)),
                             "person_active_seconds_without_row")
        self.assertTrue(active["sources"]["typed_instruction"]["cannot_speak_for_rest"])
        self.assertIn("reference_input", active["reason"])
        self.assertNotIn("typed_instruction", active["reason"])

    def test_text_template_ignores_numbers_and_ids_and_short_text(self):
        one = fc.text_template("Worker finished task 12 with status done, see delivery 1f3a9c for the details")
        two = fc.text_template("worker   finished task 9981 with status done, see delivery 77be02aa for the details")
        self.assertEqual(one, two)
        self.assertNotEqual(one, fc.text_template("Worker finished task 12 with status failed, see delivery 1f3a9c for the details"))
        self.assertEqual(len(one), 64)
        self.assertIsNone(fc.text_template("seven plain words and no more here"))
        self.assertIsNone(fc.text_template("1 2 3 4 5 6 7 8 9 10 11 12"))

    def test_template_text_never_reaches_private_state(self):
        self.seven_notices()
        original, states = fc.workspace, []
        @contextmanager
        def measured():
            with original() as work:
                yield work
                work.commit()
                states.append(Path(work.execute("PRAGMA database_list").fetchone()[2]).read_bytes())
        with patch.object(fc, "workspace", measured):
            self.report()
        self.assertTrue(states)
        for state in states:
            self.assertNotIn(b"Worker finished", state)
            self.assertNotIn(b"worker finished", state)

    # Source coverage of person_active_seconds_without_row.
    def test_active_row_says_which_requested_sources_could_not_be_read(self):
        self.logs("claude", [self.claude(10, promptSource="typed")])
        self.sample(10)
        chrome = self.root / "invented-corrupt-history"
        chrome.write_bytes(b"not a database, invented" * 100)
        missing = self.root / "invented-missing-reference"
        active = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,), reference_database=missing)),
                             "person_active_seconds_without_row")
        self.assertEqual((active["numerator"], active["denominator"]), (0, 1))
        self.assertTrue(active.get("partial_input"))
        self.assertIn("chrome_visit", active["reason"])
        self.assertIn("reference_input", active["reason"])
        sources = active["sources"]
        self.assertEqual((sources["chrome_visit"]["requested"], sources["chrome_visit"]["readable"], sources["chrome_visit"]["seconds"]), (True, False, 0))
        self.assertEqual((sources["reference_input"]["requested"], sources["reference_input"]["readable"]), (True, False))
        self.assertEqual(sources["typed_instruction"], dict(requested=True, readable=True, first_second=START + 10, last_second=START + 10, seconds=1, cannot_speak_for_rest=False))
        self.assertEqual(sources["shell_history"]["requested"], False)

    def test_active_row_through_the_command_line_with_a_missing_reference(self):
        self.logs("claude", [self.claude(10, promptSource="typed")])
        self.sample(10)
        self.db.commit()
        self.settle_logs(180)
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main([str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                                      "--from", str(START), "--to", str(START + 180), "--copy-time", str(START + 200),
                                      "--reference-database", str(self.root / "invented-missing-reference")]), 0)
        active = self.metric(json.loads(out.getvalue()), "person_active_seconds_without_row")
        self.assertTrue(active.get("partial_input"))
        self.assertEqual(active["sources"]["reference_input"]["readable"], False)

    def test_active_row_when_a_reference_stops_with_the_recorder(self):
        # 60 min window, both stop at minute 10: the zero is true only for the part the reference saw.
        events = [(offset, "key", "invented.app", "w") for offset in range(0, 600, 5)]
        for offset in range(0, 600, 5):
            self.sample(offset)
        report = self.report(end=3600, reference=self.reference(events=events), references=fc.ReferenceInputs(copy_time=START + 3700))
        active = self.metric(report, "person_active_seconds_without_row")
        self.assertEqual((active["numerator"], active["denominator"]), (0, 120))
        self.assertIn("reference_input", active["reason"] or "")
        source = active["sources"]["reference_input"]
        self.assertEqual((source["first_second"], source["last_second"], source["seconds"], source["cannot_speak_for_rest"]),
                         (START, START + 595, 120, True))

    def test_a_source_reaching_the_end_can_speak_for_it(self):
        events = [(offset, "key", "invented.app", "w") for offset in range(0, 3600, 200)]
        for offset, *_ in events:
            self.sample(offset)
        self.logs("claude", [self.claude(3400, promptSource="typed")])
        active = self.metric(self.report(end=3600, reference=self.reference(events=events)), "person_active_seconds_without_row")
        self.assertFalse(active["sources"]["reference_input"]["cannot_speak_for_rest"])
        self.assertFalse(active["sources"]["typed_instruction"]["cannot_speak_for_rest"])
        self.assertIsNone(active["reason"])
        self.assertFalse(active.get("partial_input"))

    def test_no_usable_source_is_null_not_zero(self):
        self.sample(10)
        chrome = self.root / "invented-corrupt-history"
        chrome.write_bytes(b"not a database, invented" * 100)
        active = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "person_active_seconds_without_row")
        self.assertIsNone(active["numerator"])
        self.assertIsNone(active["denominator"])
        self.assertTrue(active["partial_input"])
        self.assertIn("chrome_visit", active["reason"])
        self.assertIn(fc.NO_SIGNALS, active["reason"])

    def test_each_day_answers_for_its_own_part_of_the_window(self):
        self.sample(100)
        self.sample(86400 + 100)
        self.logs("claude", [self.claude(86000, promptSource="typed"), self.claude(86400 + 100, promptSource="typed")])
        rows = [row for row in self.report(end=172800)["measurements"] if row["metric"] == "person_active_seconds_without_row"]
        self.assertEqual(rows[0]["sources"]["typed_instruction"]["last_second"], START + 86000)
        self.assertTrue(rows[0]["sources"]["typed_instruction"]["cannot_speak_for_rest"])
        self.assertEqual(rows[1]["sources"]["typed_instruction"]["first_second"], START + 86400 + 100)
        self.assertEqual(rows[1]["sources"]["typed_instruction"]["seconds"], 1)

    def chrome_visits(self, visits):
        """visits: (offset, transition). One invented page, with the column real profiles have."""
        path = self.root / "invented-transition-history"
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE urls(id INTEGER,url TEXT)")
            db.execute("CREATE TABLE visits(id INTEGER,url INTEGER,visit_time INTEGER,transition INTEGER)")
            db.execute("INSERT INTO urls VALUES(1,'https://invented.invalid/page')")
            for index, (offset, transition) in enumerate(visits):
                db.execute("INSERT INTO visits VALUES(?,1,?,?)", (index, (START + offset + 11644473600) * 1000000, transition))
        return path

    def test_chrome_visits_stay_out_of_the_active_total(self):
        # The review's scenario: a page reloads itself ten times in a rest span.
        events = [(offset, "key", "invented.app", "w") for offset in range(0, 600, 5)]
        self.typed_seconds(0, 600)
        chrome = self.chrome_visits([(2000 + 60 * index, 0x30000008) for index in range(10)])
        report = self.report(end=3600, reference=self.reference(events=events),
                             references=fc.ReferenceInputs(chrome_histories=(chrome,), copy_time=START + 3700))
        active = self.metric(report, "person_active_seconds_without_row")
        self.assertEqual((active["numerator"], active["denominator"]), (0, 120))
        self.assertEqual(active["by_source"]["chrome_visit"], {"seconds": 10, "without_row": 10})
        self.assertEqual((active["implied_seconds_without_row"], active["implied_expected_seconds"]), (295, 896))
        self.assertNotIn("person_active_seconds_without_row", [item["category"] for item in report["top_failure_categories"]])
        self.assertEqual(active["visit_transitions"]["reload"], 10)
        self.assertEqual(self.metric(report, "chrome_visits_attributed")["visit_transitions"]["reload"], 10)

    def test_shell_history_alone_cannot_make_a_total(self):
        self.sample(0)
        history = self.root / "invented-history"
        history.write_text(f": {START + 500}:0;invented command\n")
        active = self.metric(self.report(end=1000, references=fc.ReferenceInputs(shell_histories=(history,), copy_time=START + 1100)),
                             "person_active_seconds_without_row")
        self.assertEqual(active["by_source"], {"shell_history": {"seconds": 1, "without_row": 1}})
        self.assertIsNone(active["numerator"])
        self.assertEqual(active["reason"], fc.NO_SIGNALS)

    def test_chrome_visit_kinds_come_from_the_transition(self):
        # A profile can hold the flags as a signed 32-bit number.
        chrome = self.chrome_visits([(10, 0), (11, 8), (12, 3), (13, 4), (14, 6), (15, 0x40000000), (16, 0x80000008), (17, -1610612736)])
        kinds = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")["visit_transitions"]
        self.assertEqual(kinds, dict(reload=2, subframe=2, auto_toplevel=1, redirect=3, unavailable=0))

    def test_a_chrome_history_without_transitions_says_so(self):
        chrome = self.chrome([(10, "https://invented.invalid/")])
        row = self.metric(self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,))), "chrome_visits_attributed")
        self.assertEqual(row["visit_transitions"], dict(reload=0, subframe=0, auto_toplevel=0, redirect=0, unavailable=1))

    # C5: what was stored, and what can still be a loss.
    def test_c5_a_stored_capture_counts_as_stored(self):
        self.screen(10, "stored but not linked")
        self.screen(20, "linked to its own attempt")
        identities = {row[0]: row[1] for row in self.db.execute("SELECT ts,id FROM evidence")}
        self.probe_attempt(10)
        self.probe_attempt(20, evidence_id=identities[START + 20])
        self.probe_attempt(30)
        report = self.report()
        stored = self.metric(report, "acquired_captures_stored")
        self.assertEqual((stored["numerator"], stored["denominator"], stored["ranked"]), (2, 3, False))
        unknown = self.metric(report, "acquired_captures_unlinked_unknown")
        self.assertEqual((unknown["numerator"], unknown["denominator"], unknown["lower_is_better"]), (1, 3, True))
        self.assertTrue(unknown.get("ranked", True))
        self.assertEqual(report["worst_days"][0]["metric"], "acquired_captures_unlinked_unknown")
        self.assertFalse(self.metric(report, "acquired_captures_linked")["ranked"])

    def test_c5_every_capture_stored_is_no_defect(self):
        # All unlinked and all stored, the shape measured on a real window: nothing here should rank.
        for offset in (10, 20, 30):
            self.screen(offset, f"stored invented prose {offset}")
            self.probe_attempt(offset)
        report = self.report()
        stored = self.metric(report, "acquired_captures_stored")
        self.assertEqual((stored["numerator"], stored["denominator"]), (3, 3))
        self.assertEqual(self.metric(report, "acquired_captures_linked")["numerator"], 0)
        self.assertEqual([item for item in report["worst_days"] if item["defect_ratio"]], [])
        self.assertEqual(report["top_failure_categories"], [])

    def test_c5_empty_text_and_a_missing_blob_are_apart(self):
        self.screen(10, "ordinary invented prose")
        self.screen(20, "")
        self.screen(30, "other invented prose")
        self.db.execute("PRAGMA defer_foreign_keys=ON")
        self.db.execute("DELETE FROM collection_blobs WHERE hash=?", (fc.digest("other invented prose"),))
        report = self.report()
        row = self.metric(report, "screen_occurrences_with_text")
        self.assertEqual((row["numerator"], row["denominator"], row["empty_text"], row["no_blob"], row["ranked"]), (1, 3, 1, 1, False))
        missing = self.metric(report, "screen_occurrences_no_blob")
        self.assertEqual((missing["numerator"], missing["denominator"], missing["lower_is_better"]), (1, 3, True))
        self.assertEqual({item["category"]: item["count"] for item in report["top_failure_categories"]}, {"screen_occurrences_no_blob": 1})

    def test_c5_an_empty_screen_is_no_defect(self):
        self.screen(20, "")
        report = self.report()
        self.assertEqual(self.metric(report, "screen_occurrences_with_text")["empty_text"], 1)
        self.assertEqual([item for item in report["worst_days"] if item["defect_ratio"]], [])
        self.assertEqual(report["top_failure_categories"], [])

    # C7 says why it cannot measure.
    def test_c7_a_window_of_web_keys_says_the_apps_report_no_files(self):
        self.sample(10, document="invented.invalid/page")
        self.sample(20, document="invented.invalid/other")
        row = self.metric(self.report(), "open_document_changes_attributed")
        self.assertEqual((row["document_keys_seen"], row["document_keys_not_a_path"]), (2, 2))
        self.assertEqual(row["reason"], fc.NO_FILE_DOCUMENTS)

    def test_c7_vanished_paths_are_told_from_web_keys(self):
        self.sample(10, document=str(self.root / "invented-gone"))
        row = self.metric(self.report(), "open_document_changes_attributed")
        self.assertEqual((row["document_keys_seen"], row["document_keys_not_a_path"]), (1, 0))
        self.assertNotEqual(row["reason"], fc.NO_FILE_DOCUMENTS)
        self.assertIn("no known documents", row["reason"])

    def test_gap_seconds_can_be_told_from_a_hang(self):
        self.sample(0)
        with patch.object(fc.Progress, "tick") as tick:
            self.report(end=10)
        self.assertIn("gap seconds", [call.args[0] for call in tick.call_args_list])

    # Numbers in a bundle: only columns known to hold numbers stay as they are.
    def test_card_number_stored_as_a_number_does_not_reach_a_bundle(self):
        card = "4242424242424242"
        ref = self.reference([(10, "invented.app", "invented window", "", "invented words")])
        with closing(sqlite3.connect(ref)) as db, db:
            db.execute("DROP TABLE frames")
            db.execute("CREATE TABLE frames(id INTEGER,timestamp TEXT,app_name TEXT,window_name NUMERIC,browser_url TEXT,focused INTEGER,full_text TEXT,accessibility_text TEXT,text_source TEXT,monitor_id INTEGER)")
            db.execute("CREATE INDEX frames_time ON frames(timestamp)")
            stamp = datetime.fromtimestamp(START + 10, timezone.utc).isoformat()
            db.execute("INSERT INTO frames VALUES(7,?,'invented.app',?,'',1,'invented words','','invented',2)", (stamp, card))
            self.assertEqual(db.execute("SELECT typeof(window_name) FROM frames").fetchone()[0], "integer")
        self.sample(10)
        folder = self.root / "invented-numeric-bundles"
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        text = next(folder.glob("window-*.json")).read_text()
        self.assertNotIn(card, text)
        frame = json.loads(text)["reference"][0]["frame"]
        self.assertEqual((frame["id"], frame["monitor_id"], frame["focused"]), (7, 2, 1))
        self.assertIsInstance(frame["timestamp_seconds"], (int, float))

    def test_every_number_column_of_our_tables_is_known(self):
        for table in ("samples", "evidence", "agent_log_events", "agent_log_payloads", "git_commits"):
            for _, column, declared, *_ in self.db.execute(f"PRAGMA table_info({table})"):
                if declared in ("INTEGER", "REAL"):
                    self.assertIn(column, fc.NUMERIC_COLUMNS, table)

    def test_docs_name_the_temporary_folders_and_the_copy_time(self):
        here = Path(__file__).resolve().parent
        document = (here / "FidelityCheck.md").read_text()
        for prefix in re.findall(r'prefix="(fidelity-[a-z]+-)"', (here / "fidelity_check.py").read_text()):
            self.assertIn(prefix + "*", document)
        self.assertIn("fidelity-reference-*", document)
        self.assertIn("--copy-time", (here.parent / "AGENTS.md").read_text())

    def test_dead_names_are_gone(self):
        self.assertFalse(hasattr(fc.Schema, "find"))
        self.assertFalse(hasattr(fc, "snapshot"))
        self.assertNotIn("other_monitor", Path(fc.__file__).read_text())
        self.assertNotIn("other_monitor", (Path(fc.__file__).parent / "FidelityCheck.md").read_text())

    def dated_log(self, stem, written, *lines):
        path = self.logs("claude", list(lines), stem=stem)
        last_write(path, START + written)
        return path

    def test_log_scope_skips_logs_untouched_since_before_the_lookback(self):
        self.dated_log("invented-old", -2 * 86400, self.claude(-2 * 86400, promptSource="typed"))
        self.dated_log("invented-current", 10, self.claude(10, promptSource="typed"))
        report = self.report()
        row = self.metric(report, "typed_instructions_stored", "claude")
        self.assertEqual((row["denominator"], row["source_files"], row["log_files_outside_scope"], row["log_scope"]), (1, 1, 1, "window"))

    def test_log_scope_skips_logs_that_start_after_the_window(self):
        self.dated_log("invented-later", 90000, self.claude(90000, promptSource="typed"))
        self.dated_log("invented-current", 90000, self.claude(10, promptSource="typed"), self.claude(90000, promptSource="typed"))
        report = self.report()
        row = self.metric(report, "typed_instructions_stored", "claude")
        self.assertEqual((row["denominator"], row["source_files"], row["log_files_outside_scope"]), (1, 1, 1))

    def test_log_scope_keeps_only_instructions_in_the_window(self):
        self.dated_log("invented-long", 90000, *(self.claude(offset, promptSource="typed") for offset in (-500, 10, 90000)))
        original = fc.classify_disk
        seen = []
        def counted(candidates, *rest):
            seen.append(sum(1 for _ in candidates))
            return original(candidates, *rest)
        with patch.object(fc, "classify_disk", side_effect=counted):
            self.report()
        self.assertEqual(seen, [1])

    def dispatched_body(self, offset):
        return {"type": "assistant", "timestamp": START + offset, "sessionId": "invented-parent",
                "message": {"content": [{"type": "tool_use", "input": {"prompt": BODY}}]}}

    def test_provenance_from_a_log_in_the_lookback_survives_narrowing(self):
        self.dated_log("invented-parent", -3600, self.dispatched_body(-3600))
        self.logs("codex", [self.codex(10), self.codex(20)])
        self.sample(10)
        self.sample(20)
        self.assertEqual(self.report()["classifications"], {"agent": 2})

    def test_narrowing_loss_is_exactly_the_documented_misreading(self):
        # The dispatching log was last written before the lookback. Narrowed, the worker's
        # instruction is read by its keys alone. The whole history keeps it an agent's.
        self.dated_log("invented-parent", -2 * 86400, self.dispatched_body(-2 * 86400))
        self.logs("codex", [self.codex(10), self.codex(20)])
        self.sample(10)
        self.sample(20)
        self.assertEqual(self.report()["classifications"], {"human": 2})
        complete = self.report(references=fc.ReferenceInputs(all_logs=True))
        self.assertEqual(complete["classifications"], {"agent": 2})
        self.assertEqual(self.metric(complete, "typed_instructions_with_keys", "codex")["log_scope"], "all")

    def test_narrowing_without_keys_stays_unknown(self):
        self.dated_log("invented-parent", -2 * 86400, self.dispatched_body(-2 * 86400))
        self.logs("codex", [self.codex(10), self.codex(20)])
        self.assertEqual(self.report()["classifications"], {"unknown": 2})

    def test_log_lookback_flag_and_all_logs_reach_the_scope(self):
        self.dated_log("invented-parent", -2 * 86400, self.dispatched_body(-2 * 86400))
        self.logs("codex", [self.codex(10), self.codex(20)])
        self.sample(10)
        self.sample(20)
        self.db.commit()
        base = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--from", str(START), "--to", str(START + 180)]
        for extra, expected in (([], {"human": 2}), (["--log-lookback-hours", "72"], {"agent": 2}), (["--all-logs"], {"agent": 2})):
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(fc.main(base + extra), 0)
            self.assertEqual(json.loads(out.getvalue())["classifications"], expected)

    def test_progress_lines_name_stages_only(self):
        secret = 'inventedprivatesentinel'
        self.logs("claude", [self.claude(promptSource="typed", body=secret + " body")])
        self.sample(10, app=secret, window=secret, document=secret)
        ref = self.reference([(10, secret, secret, '', secret)])
        self.db.commit()
        self.settle_logs(180)
        err = io.StringIO()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--from", str(START), "--to", str(START + 180)]
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            self.assertEqual(fc.main(args), 0)
        lines = [line for line in err.getvalue().splitlines() if line.startswith('fidelity: ')]
        self.assertGreater(len(lines), 8)
        for stage in ('read agent logs', 'classify instructions', 'reference comparison', 'C10 recall', 'bundles'):
            self.assertTrue(any(stage in line for line in lines), stage)
        self.assertNotIn(secret, err.getvalue())
        self.assertNotIn(str(self.root), err.getvalue())
        self.assertFalse(fc.Progress.enabled)

    def source_state(self, path):
        folder = Path(path).parent
        return {item.name: (item.stat().st_size, item.stat().st_mtime_ns) for item in folder.iterdir() if item.name.startswith(Path(path).name)}

    def locked_reference(self):
        """A live recorder: uncheckpointed text in its log and a lock it does not let go."""
        path = self.reference([(10, 'invented.app', '', '', 'committedalpha')])
        writer = sqlite3.connect(path, isolation_level=None)
        self.addCleanup(writer.close)
        writer.execute('PRAGMA journal_mode=WAL')
        writer.execute('PRAGMA wal_autocheckpoint=0')
        writer.execute("INSERT INTO frames(id,timestamp,app_name,window_name,focused,full_text) VALUES(99,?,'invented.app','',1,'walonlyterm')",
                       (datetime.fromtimestamp(START + 11, timezone.utc).isoformat(),))
        writer.execute('PRAGMA locking_mode=EXCLUSIVE')
        writer.execute('BEGIN EXCLUSIVE')
        writer.execute("UPDATE frames SET full_text='uncommitted' WHERE id=99")
        return path, writer

    def test_locked_live_reference_reads_through_a_clone_and_leaves_no_trace(self):
        path, _ = self.locked_reference()
        with self.assertRaises(sqlite3.OperationalError):
            with closing(sqlite3.connect(path.absolute().as_uri() + '?mode=ro', uri=True, timeout=.1)) as direct:
                direct.execute('SELECT count(*) FROM frames').fetchone()
        before, listing = self.source_state(path), set(os.listdir(path.parent))
        with fc.reference_snapshot(path) as db:
            rows = {row[0] for row in db.execute("SELECT full_text FROM frames")}
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("DELETE FROM frames")
        self.assertEqual(rows, {'committedalpha', 'walonlyterm'})
        self.assertEqual(self.source_state(path), before)
        self.assertEqual(set(os.listdir(path.parent)), listing)

    def test_cli_on_a_locked_reference_measures_and_leaves_no_trace(self):
        path, _ = self.locked_reference()
        self.sample(10)
        self.screen(10, 'walonlyterm committedalpha')
        self.db.commit()
        scratch = self.root / 'invented-tmp'
        scratch.mkdir()
        before = self.source_state(path)
        out = io.StringIO()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(path), "--from", str(START), "--to", str(START + 180)]
        with patch.object(tempfile, 'tempdir', str(scratch)), redirect_stdout(out), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args), 0)
        fc.close_mask()
        row = self.metric(json.loads(out.getvalue()), 'informative_term_unweighted_recall')
        self.assertEqual((row['numerator'], row['denominator']), (2, 2))
        self.assertEqual(self.source_state(path), before)
        self.assertEqual(list(scratch.iterdir()), [])

    def test_clone_is_private_and_deleted_on_failure(self):
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose')])
        scratch = self.root / 'invented-tmp'
        scratch.mkdir()
        with patch.object(tempfile, 'tempdir', str(scratch)):
            with self.assertRaises(RuntimeError):
                with fc.reference_snapshot(ref):
                    folder = next(scratch.iterdir())
                    self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
                    self.assertTrue(all(item.stat().st_mode & 0o077 == 0 for item in folder.iterdir()))
                    raise RuntimeError('invented failure')
        self.assertEqual(list(scratch.iterdir()), [])

    def test_clone_refuses_a_real_copy_when_it_cannot_clone(self):
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose')])
        self.sample(10)
        self.db.commit()
        scratch = self.root / 'invented-tmp'
        scratch.mkdir()
        out = io.StringIO()
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--reference-database", str(ref), "--from", str(START), "--to", str(START + 180)]
        real = fc.clone_file
        def only_primary(source, target):
            if str(source).startswith(str(ref)):
                raise fc.CloneUnavailable(errno.EXDEV, 'invented')
            real(source, target)
        with patch.object(fc, 'clone_file', side_effect=only_primary), patch.object(tempfile, 'tempdir', str(scratch)), \
                patch.object(shutil, 'copyfile', side_effect=AssertionError('never copied')), redirect_stdout(out), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args), 0)
        row = self.metric(json.loads(out.getvalue()), 'reference_frames_attributed')
        self.assertIn('not cloneable', row['reason'])
        self.assertEqual(list(scratch.iterdir()), [])

    def test_clone_retries_when_the_log_restarts_between_its_files(self):
        path = self.reference()
        with closing(sqlite3.connect(path, isolation_level=None)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute('PRAGMA wal_autocheckpoint=0')
            writer.execute("INSERT INTO frames(id,timestamp,focused) VALUES(1,?,1)", (START,))
            real, calls = fc.clone_file, []
            def restarting(source, target):
                # The first main-file clone is followed by a checkpoint and a log restart.
                real(source, target)
                calls.append(str(source))
                if len(calls) == 1:
                    writer.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
                    writer.execute("INSERT INTO frames(id,timestamp,focused) VALUES(2,?,1)", (START + 1,))
            with patch.object(fc, 'clone_file', side_effect=restarting):
                with fc.private_clone(path) as clone, closing(sqlite3.connect(clone)) as copy:
                    self.assertEqual(copy.execute('SELECT count(*) FROM frames').fetchone()[0], 2)
            self.assertGreater(calls.count(str(path.absolute())), 1)

    def test_clone_gives_up_rather_than_trust_a_log_that_keeps_restarting(self):
        ref = self.reference()
        salts = iter(bytes([i]) * 8 for i in range(100))
        with patch.object(fc, 'wal_salt', side_effect=lambda path: next(salts)):
            with self.assertRaises(OSError):
                with fc.private_clone(ref):
                    self.fail('an unstable clone was used')

    def test_rollback_journal_in_progress_is_undone_only_in_the_clone(self):
        ref = self.reference([(10, 'invented.app', '', '', 'committedalpha')])
        holder = ref.parent / 'invented-journal-holder.py'
        holder.write_text("""import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute('PRAGMA journal_mode=DELETE')
db.execute('PRAGMA cache_spill=ON')
db.execute('PRAGMA cache_size=1')
db.execute('BEGIN IMMEDIATE')
db.execute("UPDATE frames SET full_text='uncommitted' || hex(zeroblob(200000))")
print('held', flush=True)
time.sleep(30)
""")
        process = subprocess.Popen([sys.executable, '-I', str(holder), str(ref)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        self.assertEqual(process.stdout.readline().strip(), 'held')
        process.stdout.close()
        before = self.source_state(ref)
        with fc.reference_snapshot(ref) as db:
            self.assertEqual(db.execute('SELECT full_text FROM frames').fetchone()[0], 'committedalpha')
        self.assertEqual(self.source_state(ref), before)

    def test_terminate_signal_deletes_the_clone(self):
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose')])
        self.sample(10)
        self.db.commit()
        scratch = self.root / 'invented-tmp'
        scratch.mkdir()
        script = self.root / 'invented-slow.py'
        script.write_text(f"""import sys, time
sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})
import fidelity_check as fc
def slow(*args, **kwargs):
    print('analyzing', flush=True)
    time.sleep(60)
fc.analyze = slow
sys.exit(fc.main(sys.argv[1:]))
""")
        process = subprocess.Popen([sys.executable, '-I', str(script), str(self.database), "--claude-home", str(self.homes["claude"][0]),
                                    "--codex-home", str(self.homes["codex"][0]), "--reference-database", str(ref),
                                    "--from", str(START), "--to", str(START + 180)],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=dict(os.environ, TMPDIR=str(scratch)))
        self.addCleanup(process.stdout.close)
        self.assertEqual(process.stdout.readline().strip(), 'analyzing')
        self.assertTrue(list(scratch.iterdir()))
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=30), 130)
        self.assertEqual(list(scratch.iterdir()), [])

    def test_wal_inputs_keep_their_folder_unchanged(self):
        self.sample(10)
        self.db.commit()
        self.db.close()
        with closing(sqlite3.connect(self.database)) as db:
            db.execute('PRAGMA journal_mode=WAL')
        side = [self.root / (self.database.name + suffix) for suffix in ('-wal', '-shm')]
        self.assertFalse(any(item.exists() for item in side))
        before = self.source_state(self.database)
        args = [str(self.database), "--claude-home", str(self.homes["claude"][0]), "--codex-home", str(self.homes["codex"][0]),
                "--from", str(START), "--to", str(START + 60)]
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(fc.main(args), 0)
        self.assertEqual(self.source_state(self.database), before)
        self.db = sqlite3.connect(self.database)

    def test_analysis_never_writes_to_its_inputs(self):
        self.sample(10)
        self.screen(10, 'ordinary prose')
        self.logs("claude", [self.claude(promptSource="typed")])
        ref = self.reference([(10, 'invented.app', '', '', 'ordinary prose')])
        self.db.commit()
        hashes = lambda: {str(p): p.read_bytes() for p in chain.from_iterable(Path(h).rglob('*') for h in chain.from_iterable(self.homes.values())) if p.is_file()}
        logs, database, reference = hashes(), self.database.read_bytes(), ref.read_bytes()
        self.report(reference=ref)
        self.assertEqual((hashes(), self.database.read_bytes(), ref.read_bytes()), (logs, database, reference))


def input_fixture(dimension, size, root):
    """Generate large values in a separate process, outside measured peak RSS."""
    root = Path(root)
    with closing(sqlite3.connect(root / 'invented-scaling-reference.sqlite')) as db, db:
        timestamp_type = 'TEXT' if dimension == 'predicate_timestamp_text' else 'REAL'
        db.execute('CREATE TABLE frames(id INTEGER,timestamp ' + timestamp_type + ',app_name TEXT,window_name TEXT,focused INTEGER,full_text TEXT)')
        db.execute('CREATE INDEX frames_time ON frames(timestamp)')
        if dimension in ('record_size', 'term_length'):
            db.execute("INSERT INTO frames VALUES(1,?,'invented.app','',1,replace(hex(zeroblob(?)),'00','x'))", (START + 10, size))
        else:
            count = size if dimension == 'row_count' else 1
            db.executemany("INSERT INTO frames VALUES(?,?,?,'',1,'ordinary prose')",
                           ((i, START + 10, 'invented.app' if dimension.startswith('predicate_') or dimension == 'app_history' else 'invented.app.' + str(i % 256)) for i in range(count)))
    if dimension in ('predicate_bundle', 'predicate_timestamp', 'predicate_timestamp_text'):
        with closing(sqlite3.connect(root / 'invented.sqlite')) as db, db:
            if dimension == 'predicate_bundle':
                # Outside the selected period, but consulted by app resolution.
                db.execute(SAMPLE_INSERT.replace("VALUES(?,?,", "VALUES(?,replace(hex(zeroblob(?)),'00','x'),"),
                           (START - 86400, size, 'invented.app', '', '', 0, 0, 0))
            db.execute(SAMPLE_INSERT, (START + 10, 'invented.app', 'invented.app', '', '', 1, 0, 0))
            db.execute(EVIDENCE_INSERT, (START + 10, 'screen', 'invented.app', None, 'ordinary prose'))
        if dimension.startswith('predicate_timestamp'):
            with closing(sqlite3.connect(root / 'invented-scaling-reference.sqlite')) as db, db:
                stamp = datetime.fromtimestamp(START + 10, timezone.utc).isoformat()
                db.execute("INSERT INTO frames VALUES(2,? || replace(hex(zeroblob(?)),'00',' '),'invented.app','',1,'ordinary prose')",
                           (stamp, size))
    if dimension == 'app_history':
        with closing(sqlite3.connect(root / 'invented.sqlite')) as db, db:
            db.executemany(SAMPLE_INSERT, ((START - size + i, 'invented.bundle', 'invented historic app ' + str(i), '', '', 0, 0, 0) for i in range(size)))
            db.execute(SAMPLE_INSERT, (START + 10, 'invented.bundle', 'invented.app', '', '', 0, 0, 0))
            db.execute(EVIDENCE_INSERT, (START + 10, 'screen', 'invented.bundle', None, 'ordinary prose'))
    if dimension == 'history_length':
        with closing(sqlite3.connect(root / 'invented.sqlite')) as db, db:
            db.execute('CREATE INDEX log_recording_history_since ON log_recording_history(since)')
            insert = 'INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,1,NULL)'
            db.executemany(insert, ((START - size + i,) for i in range(size)))
            db.executemany(insert, ((START + 100 * i / size,) for i in range(size)))
    if dimension == 'line_length':
        folder = root / 'claude/projects'
        folder.mkdir(parents=True)
        with (folder / 'invented.jsonl').open('wb') as stream:
            stream.write(b'{"message":{"content":"')
            chunk = b'x' * 65536
            for _ in range(size // len(chunk)):
                stream.write(chunk)
            stream.write(b'"}}\n')
        last_write(folder / 'invented.jsonl', START + 10)


def input_scaling_worker(dimension, size):
    import resource
    import time
    case = FidelityTests()
    case.setUp()
    try:
        case.db.commit()
        subprocess.run([sys.executable, __file__, '--input-fixture', dimension, str(size), str(case.root)], check=True)
        reference = case.root / 'invented-scaling-reference.sqlite'
        before = time.monotonic()
        with fc.readonly(case.database) as ours, fc.reference_snapshot(reference) as other:
            report = fc.analyze(ours, case.homes, START, START + 120, reference=other)
        row = case.metric(report, 'reference_frames_attributed')
        assert row['denominator'] == (size if dimension == 'row_count' else 1), row
        if dimension == 'record_size':
            assert row['partial_input'] and row['oversized_fields'] == 1, row
        if dimension in ('predicate_bundle', 'predicate_timestamp', 'predicate_timestamp_text'):
            recall = case.metric(report, 'informative_term_unweighted_recall')
            assert (recall['numerator'], recall['denominator']) == (2, 2), recall
            assert recall['partial_input'] and recall['oversized_fields'] == 1, recall
            if dimension.startswith('predicate_timestamp'):
                assert recall['unavailable_records_unplaced'] == 1, recall
        if dimension == 'term_length':
            assert case.metric(report, 'informative_term_unweighted_recall')['exact_only_terms'] == 1
        if dimension == 'app_history':
            recall = case.metric(report, 'informative_term_unweighted_recall')
            assert (recall['numerator'], recall['denominator']) == (2, 2), recall
        if dimension == 'line_length':
            assert case.metric(report, 'typed_instructions_stored', 'claude')['oversized_source_lines'] == 1
        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform != 'darwin':
            peak *= 1024
        helper = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(fc._product_mask.process.pid)], text=True)) * 1024
        print(json.dumps(dict(dimension=dimension, size=size, peak_rss_bytes=peak,
                              helper_rss_bytes=helper, seconds=round(time.monotonic() - before, 3))))
    finally:
        fc.close_mask()
        case.doCleanups()


def input_scaling_check():
    results = []
    dimensions = dict(record_size=(4 * 1024**2, 16 * 1024**2, 32 * 1024**2),
                      predicate_bundle=(4 * 1024**2, 16 * 1024**2, 32 * 1024**2),
                      predicate_timestamp=(4 * 1024**2, 16 * 1024**2, 32 * 1024**2),
                      predicate_timestamp_text=(4 * 1024**2, 16 * 1024**2, 32 * 1024**2),
                      row_count=(2048, 8192, 16384), history_length=(20000, 80000, 320000),
                      app_history=(20000, 80000, 320000),
                      term_length=(8192, 32768, 131072), line_length=(16 * 1024**2, 64 * 1024**2, 128 * 1024**2))
    for dimension, sizes in dimensions.items():
        rows = [json.loads(subprocess.check_output([sys.executable, __file__, '--input-scaling-worker', dimension, str(size)], text=True))
                for size in sizes]
        for field in ('peak_rss_bytes', 'helper_rss_bytes'):
            # Seeking the source's own time index loads an oversized key once, at about its size.
            # This is the price of not scanning the reference; real timestamps are short.
            if dimension.startswith('predicate_timestamp') and field == 'peak_rss_bytes':
                assert max(row[field] for row in rows) - min(row[field] for row in rows) < 2 * max(sizes), rows
                continue
            assert max(row[field] for row in rows) - min(row[field] for row in rows) < 20 * 1024**2, rows
        results.extend(rows)
        print(json.dumps(dict(input_scaling=dimension, rows=rows)), flush=True)
    return results


def shell_scaling_worker(size, shell):
    import resource
    with tempfile.TemporaryDirectory(prefix="fidelity-shell-scaling-") as folder:
        history = Path(folder) / "invented-history"
        with history.open("wb") as stream:
            if shell == "zsh":
                stream.write(f": {START + 10}:0;".encode())
            elif shell == "bash":
                stream.write(f"#{START + 10}\n".encode())
            chunk = b"x" * (1024 * 1024)
            for _ in range(size):
                stream.write(chunk)
            stream.write(b"\n")
        row = fc.shell_checks(fc.ReferenceInputs(shell_histories=(history,)), [], START, START + 86400,
                              lambda ts: "invented-day", ["invented-day"], Counter(), Counter())[0]
        assert row["oversized_records"] == 1 and row["partial_input"], row
        assert row["denominator"] is None, row
        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform != "darwin":
            peak *= 1024
        print(json.dumps({"shell": shell, "history_bytes": size * 1024 * 1024, "peak_rss_bytes": peak}))


def shell_scaling_check():
    results = []
    for shell in ("untimed", "zsh", "bash"):
        rows = [json.loads(subprocess.check_output([sys.executable, __file__, "--shell-scaling-worker", str(size), shell], text=True))
                for size in (16, 64, 128)]
        assert max(r["peak_rss_bytes"] for r in rows) - min(r["peak_rss_bytes"] for r in rows) < 20 * 1024 * 1024, rows
        results.extend(rows)
    return results


def scaling_worker(count):
    """Fresh-process peak RSS includes fixture construction and full analysis."""
    import resource
    case = FidelityTests()
    case.setUp()
    try:
        reference = case.root / "invented-scaling-reference.sqlite"
        text = ("toolbar inventedalpha inventedbeta inventedgamma " * 180)[:8192]
        with closing(sqlite3.connect(reference)) as db:
            db.execute("CREATE TABLE frames(id INTEGER,timestamp REAL,app_name TEXT,window_name TEXT,browser_url TEXT,focused INTEGER,full_text TEXT)")
            db.execute("CREATE INDEX frames_timestamp ON frames(timestamp)")
            for index in range(count):
                db.execute("INSERT INTO frames VALUES(?,?,?,?,?,1,?)", (index, START + index, "invented.app", "invented window", "", text))
                case.sample(index)
            db.commit()
        log = case.logs("claude", [])
        with log.open("w") as stream:
            for index in range(count // 4):
                # One word differs by more than a number, or these would all be repeated_text and leave C1 and C2 unmeasured.
                word = "".join(chr(97 + (index >> shift & 15)) for shift in (0, 4, 8, 12, 16))
                stream.write(json.dumps(case.claude(index, body=f"{BODY} {word}", promptSource="typed")) + "\n")
        last_write(log, START + count)
        case.db.commit()
        state_bytes = []
        original_workspace = fc.workspace
        @contextmanager
        def measured_workspace():
            with original_workspace() as work:
                yield work
                state_bytes.append(work.execute("PRAGMA page_count").fetchone()[0] * work.execute("PRAGMA page_size").fetchone()[0])
        with patch.object(fc, "workspace", measured_workspace), fc.readonly(case.database) as ours, fc.reference_snapshot(reference) as other:
            report = fc.analyze(ours, case.homes, START, START + 86400, reference=other)
        frame_row = case.metric(report, "reference_frames_attributed")
        assert frame_row["denominator"] == count
        assert case.metric(report, "typed_instructions_stored", "claude")["denominator"] == count // 4
        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform != "darwin":
            peak *= 1024
        helper_rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(fc._product_mask.process.pid)], text=True)) * 1024
        print(json.dumps({"frames": count, "text_bytes": len(text) * count,
                          "instructions": count // 4, "peak_rss_bytes": peak,
                          "mask_helper_rss_bytes": helper_rss, "temporary_state_bytes": max(state_bytes)}))
    finally:
        fc.close_mask()
        case.doCleanups()


def scaling_check():
    rows = []
    for count in (2048, 8192, 16384):
        rows.append(json.loads(subprocess.check_output([sys.executable, __file__, "--scaling-worker", str(count)], text=True)))
    # Allocator/SQLite/loader variance must not hide corpus-proportional growth.
    assert max(r["peak_rss_bytes"] for r in rows) - min(r["peak_rss_bytes"] for r in rows) < 20 * 1024 * 1024, rows
    assert max(r["mask_helper_rss_bytes"] for r in rows) - min(r["mask_helper_rss_bytes"] for r in rows) < 20 * 1024 * 1024, rows
    print(json.dumps({"scaling": rows, "max_peak_growth_bytes": max(r["peak_rss_bytes"] for r in rows) - min(r["peak_rss_bytes"] for r in rows)}))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == '--input-fixture':
        input_fixture(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    elif len(sys.argv) > 1 and sys.argv[1] == '--input-scaling-worker':
        input_scaling_worker(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1:] == ['--input-scaling']:
        input_scaling_check()
    elif len(sys.argv) > 1 and sys.argv[1] == "--shell-scaling-worker":
        shell_scaling_worker(int(sys.argv[2]), sys.argv[3])
    elif sys.argv[1:] == ["--shell-scaling"]:
        print(json.dumps({"shell_scaling": shell_scaling_check()}))
    elif len(sys.argv) > 1 and sys.argv[1] == "--scaling-worker":
        scaling_worker(int(sys.argv[2]))
    elif sys.argv[1:] == ["--scaling"]:
        scaling_check()
    else:
        unittest.main()
