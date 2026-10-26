#!/usr/bin/env python3
"""Invented fixtures only; never opens default recorder or agent-log locations."""

import ast
from collections import Counter, defaultdict
from contextlib import closing, contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fidelity_check as fc


START = 1969660800  # Invented aligned UTC day in 2032.
BODY = "Invented instruction with enough separate words to compare its provenance safely"


def sql_bound_violations(sql):
    """Parse SQL calls and CASE branches; an AND size test grants no guard."""
    tokens = re.findall(r"'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|[A-Za-z_]\w*|\d+|<=|>=|<>|[().,?=<>*]", sql)
    tokens = [token.lower() if not token.startswith(("'", '"')) else token for token in tokens]
    keywords = {'case', 'when', 'then', 'else', 'end', 'in', 'exists', 'select', 'values', 'on', 'key', 'over', 'and', 'or', 'not', 'conflict'}
    metadata = {'typeof', 'octet_length', 'coalesce', 'ifnull', 'nullif', 'count'}
    # Only tool-owned numeric state has an aggregate exemption. Source columns
    # with the same names can still contain oversized text in SQLite.
    numeric_state = {'instructions': {'id'}, 'input_keys': {'ts'}, 'votes': {'n'},
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


class FidelityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fidelity-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.database = self.root / "invented.sqlite"
        self.db = sqlite3.connect(self.database)
        self.addCleanup(self.db.close)
        # Reuse the real schema's SQL declarations, without running the app or
        # opening any recorder state. Only these three channels are under test.
        source = (Path(__file__).resolve().parents[1] / "Sources/Storage/Schema.swift").read_text()
        for name in ("samples", "evidence", "log_recording_history"):
            sql = re.search(r'CREATE TABLE IF NOT EXISTS ' + name + r' \(.*?\)\n\s*"""', source, re.S).group()
            self.db.execute(sql.rsplit('"""', 1)[0])
        self.db.execute("PRAGMA user_version=9")
        self.db.commit()
        self.homes = {"claude": [self.root / "claude"], "codex": [self.root / "codex"]}

    def sample(self, offset, keys=1, app="invented.app", window="invented window", document="invented document", clicks=0, scrolls=0):
        self.db.execute("INSERT INTO samples VALUES(NULL,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (START + offset, app, app, window, document, keys, clicks, scrolls, 0, 0, 0, 0))

    def logs(self, tool, lines, stem="invented-session", subagent=False):
        folder = self.homes[tool][0] / ("projects" if tool == "claude" else "sessions")
        if subagent:
            folder = folder / "subagents"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / (stem + ".jsonl")
        path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
        return path

    def claude(self, offset=10, body=BODY, **fields):
        return dict(type="user", timestamp=START + offset, sessionId="invented-session",
                    uuid="invented-" + str(offset), message={"content": body}, **fields)

    def codex(self, offset=10, **fields):
        payload = dict(type="item_completed", thread_id="invented-session", turn_id="invented-turn-" + str(offset),
                       item={"type": "UserMessage", "id": "invented-item", "content": [{"type": "text", "text": BODY}]})
        payload.update(fields)
        return dict(type="event_msg", timestamp=START + offset, payload=payload)

    def report(self, end=180, references=None, reference=None):
        self.db.commit()
        with fc.snapshot(self.database) as copy:
            if reference is not None:
                with fc.reference_snapshot(reference) as other:
                    return fc.analyze(copy, self.homes, START, START + end, references=references, reference=other)
            return fc.analyze(copy, self.homes, START, START + end, references=references)

    def metric(self, report, name, tool=None):
        return next(r for r in report["measurements"] if r["metric"] == name and r["tool"] == tool)

    def evidence(self, offset, source_id, body=BODY, source="invented-session"):
        self.db.execute("INSERT INTO evidence VALUES(NULL,?,'prompt',?,?, '', '', ?)",
                        (START + offset, source, source_id, body))

    def test_schema9_absent_channels(self):
        report = self.report()
        self.assertEqual(report["schema_version"], 9)
        for metric in ("unexplained_gap_minutes", "commits_recorded", "captures_kept"):
            row = self.metric(report, metric)
            self.assertIn("channel absent", row["reason"])
            self.assertIsNone(row["ratio"])
            self.assertIsNone(row["denominator"])

    def test_c1_marker_denominator_includes_missing_keys(self):
        self.logs("claude", [self.claude(i, promptSource="typed") for i in (10, 20, 30)])
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
        self.logs("claude", [self.claude(i, promptSource="typed") for i in (10, 20, 30)])
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

    def histories(self):
        self.db.execute("INSERT INTO log_recording_history VALUES(1,?,1,NULL)", (START,))
        self.db.execute("CREATE TABLE awake_history(since INTEGER,awake INTEGER)")
        self.db.execute("CREATE TABLE exclusion_history(since INTEGER,excluded INTEGER)")
        self.db.execute("INSERT INTO awake_history VALUES(?,1)", (START,))
        self.db.execute("INSERT INTO exclusion_history VALUES(?,0)", (START,))

    def test_c3_gaps_on_awake_not_paused_not_excluded(self):
        self.histories()
        self.sample(1)
        row = self.metric(self.report(), "unexplained_gap_minutes")
        self.assertEqual((row["numerator"], row["denominator"]), (2, 3))
        self.db.execute("INSERT INTO log_recording_history VALUES(2,?,1,?)", (START + 60, START + 120))
        self.db.execute("INSERT INTO awake_history VALUES(?,0)", (START + 120,))
        row = self.metric(self.report(), "unexplained_gap_minutes")
        self.assertEqual((row["numerator"], row["denominator"]), (0, 1))

    def test_c3_exclusion_off_and_partial_minutes(self):
        self.histories()
        self.db.execute("INSERT INTO exclusion_history VALUES(?,1)", (START + 70,))
        self.db.execute("INSERT INTO log_recording_history VALUES(2,?,0,NULL)", (START + 130,))
        row = self.metric(self.report(end=179), "unexplained_gap_minutes")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_c3_unknown_history_is_not_counted_as_gap(self):
        self.histories()
        self.db.execute("DELETE FROM awake_history")
        self.db.execute("INSERT INTO awake_history VALUES(?,1)", (START + 60,))
        row = self.metric(self.report(), "unexplained_gap_minutes")
        self.assertEqual((row["numerator"], row["denominator"], row["unknown_history_minutes"]), (2, 2, 1))

    def test_c4_real_invented_git_repository(self):
        repo = self.root / "invented-repo"
        env = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_AUTHOR_DATE": f"{START + 10} +0000", "GIT_COMMITTER_DATE": f"{START + 10} +0000"}
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), "-c", "user.name=Invented", "-c",
                                            "user.email=invented@example.invalid", "-c", "commit.gpgsign=false", *args],
                                           env=env, stderr=subprocess.DEVNULL, text=True).strip()
        repo.mkdir()
        git("init", "-q")
        git("commit", "--allow-empty", "-qm", "Invented first")
        first = git("rev-parse", "HEAD")
        git("commit", "--allow-empty", "-qm", "Invented second")
        before = {str(p.relative_to(repo)): (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in repo.rglob("*") if p.is_file()}
        self.db.execute("CREATE TABLE git_repositories(id INTEGER,path TEXT)")
        self.db.execute("CREATE TABLE git_commits(repository_id INTEGER,commit_hash TEXT)")
        self.db.execute("INSERT INTO git_repositories VALUES(1,?)", (str(repo),))
        self.db.execute("INSERT INTO git_commits VALUES(1,?)", (first,))
        row = self.metric(self.report(), "commits_recorded")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))
        after = {str(p.relative_to(repo)): (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in repo.rglob("*") if p.is_file()}
        self.assertEqual(after, before)

    def test_c4_unreadable_repository_is_partial(self):
        self.db.execute("CREATE TABLE git_repositories(id INTEGER,path TEXT)")
        self.db.execute("CREATE TABLE git_commits(repository_id INTEGER,commit_hash TEXT)")
        self.db.execute("INSERT INTO git_repositories VALUES(1,?)", (str(self.root / "invented-missing"),))
        row = self.metric(self.report(), "commits_recorded")
        self.assertIn("partial", row["reason"])
        self.assertEqual(row["repositories_unreadable"], 1)

    def test_c5_acquired_occurrences_and_loss_counters(self):
        self.db.execute("CREATE TABLE screen_captures(id INTEGER,ts INTEGER)")
        self.db.execute("CREATE TABLE screen_occurrences(capture_id INTEGER)")
        self.db.execute("CREATE TABLE screen_capture_counters(ts INTEGER,dropped_captures INTEGER,admission_losses INTEGER)")
        self.db.executemany("INSERT INTO screen_captures VALUES(?,?)", [(1, START + 10), (2, START + 20)])
        self.db.executemany("INSERT INTO screen_occurrences VALUES(?)", [(1,), (1,)])
        self.db.execute("INSERT INTO screen_capture_counters VALUES(?,1,2)", (START + 10,))
        row = self.metric(self.report(), "captures_kept")
        self.assertEqual((row["numerator"], row["denominator"], row["dropped_captures"], row["admission_losses"]), (1, 2, 1, 2))

    def test_c5_counter_deltas_only(self):
        self.db.execute("CREATE TABLE screen_capture_stats(ts INTEGER,acquired INTEGER,stored INTEGER,dropped_captures INTEGER,admission_losses INTEGER)")
        self.db.executemany("INSERT INTO screen_capture_stats VALUES(?,?,?,?,?)", [(START + 10, 5, 3, 1, 1), (START + 20, 2, 1, 1, 0)])
        row = self.metric(self.report(), "captures_kept")
        self.assertEqual((row["numerator"], row["denominator"], row["dropped_captures"]), (4, 7, 2))

    def test_unsupported_future_schema_is_explicit(self):
        self.db.execute("CREATE TABLE git_repositories(unknown INTEGER)")
        self.db.execute("CREATE TABLE git_commits(unknown INTEGER)")
        self.db.execute("CREATE TABLE screen_captures(unknown INTEGER)")
        report = self.report()
        for metric in ("commits_recorded", "captures_kept"):
            self.assertIn("unsupported schema", self.metric(report, metric)["reason"])

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
        with fc.snapshot(self.database, parent) as copy:
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
        with self.assertRaisesRegex(RuntimeError, "invented"):
            with fc.snapshot(self.database, parent):
                raise RuntimeError("invented")
        self.assertEqual(list(parent.iterdir()), [])

    def test_temp_cleanup_after_backup_failure_and_no_creation(self):
        parent = self.root / "scratch"
        parent.mkdir()
        missing = self.root / "invented-missing.sqlite"
        with self.assertRaises(sqlite3.OperationalError):
            with fc.snapshot(missing, parent):
                self.fail("must not open missing input")
        self.assertFalse(missing.exists())
        self.assertEqual(list(parent.iterdir()), [])
        bad = self.root / "invented-invalid.sqlite"
        bad.write_bytes(b"invented non-SQLite bytes")
        before = bad.stat().st_mtime_ns
        with self.assertRaises(sqlite3.DatabaseError):
            with fc.snapshot(bad, parent):
                self.fail("must not back up invalid input")
        self.assertEqual(bad.stat().st_mtime_ns, before)
        self.assertEqual(list(parent.iterdir()), [])

    def test_wal_snapshot_includes_committed_uncheckpointed_rows(self):
        self.db.execute("PRAGMA journal_mode=WAL")
        self.sample(10)
        self.db.commit()
        before = self.database.read_bytes()
        with fc.snapshot(self.database) as copy:
            self.assertEqual(copy.execute("SELECT COUNT(*) FROM samples").fetchone()[0], 1)
        self.assertEqual(self.database.read_bytes(), before)

    def test_per_day_and_exclusive_end(self):
        self.logs("claude", [self.claude(10, promptSource="typed"), self.claude(86410, promptSource="typed"),
                             self.claude(86420, promptSource="typed")])
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
        self.assertEqual(json.loads(out.getvalue())["schema_version"], 9)
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
        original = fc.snapshot
        def snap(path, **kwargs):
            return original(path, scratch, **kwargs)
        with patch.object(fc, "snapshot", side_effect=snap):
            self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        self.assertEqual(list(scratch.iterdir()), [])
        with patch.object(fc, "snapshot", side_effect=snap), \
                patch.object(fc, "url_digest", side_effect=ValueError("invented-private-input")):
            self.report(references=fc.ReferenceInputs(chrome_histories=(chrome,)))
        self.assertEqual(list(scratch.iterdir()), [])

    def test_c7_known_repository_latest_mtimes_only(self):
        repo = self.root / "invented-known-repository"
        repo.mkdir()
        (repo / ".git").mkdir()
        one, two, old = (repo / name for name in ("invented-one", "invented-two", "invented-old"))
        for path, offset in ((one, 10), (two, 20), (old, -10)):
            path.write_text("invented file contents never opened by checker")
            os.utime(path, (START + offset, START + offset))
        unrelated = self.root / "invented-unrelated-file"
        unrelated.write_text("invented")
        os.utime(unrelated, (START + 30, START + 30))
        self.sample(15, document=one.as_uri())
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (one, two, old, unrelated)}
        report = self.report()
        row = self.metric(report, "latest_file_mtimes_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 2))
        self.assertTrue(row["latest_mtime_only"])
        self.assertEqual(row["known_roots"], 1)
        for path, (content, mtime) in before.items():
            self.assertEqual(path.read_bytes(), content)
            self.assertEqual(path.stat().st_mtime_ns, mtime)
        self.assertNotIn(str(repo), json.dumps(report) + fc.summary(report))

    def test_c7_does_not_follow_symlinks_or_git_metadata(self):
        repo = self.root / "invented-repo"
        repo.mkdir()
        (repo / ".git").mkdir()
        known = repo / "invented-known"
        known.write_text("invented")
        outside = self.root / "invented-outside"
        outside.write_text("invented")
        (repo / "invented-symlink").symlink_to(outside)
        hidden = repo / ".git" / "invented-metadata"
        hidden.write_text("invented")
        for p in (known, outside, hidden):
            os.utime(p, (START + 10, START + 10))
        self.sample(10, document=str(known))
        row = self.metric(self.report(), "latest_file_mtimes_attributed")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 1))

    def test_c7_missing_known_file_is_counted(self):
        self.sample(10, document=str(self.root / "invented-missing-parent" / "invented-deleted"))
        report = self.report()
        self.assertEqual(report["diagnostics"]["known_document_paths_unavailable"], 1)
        self.assertEqual(self.metric(report, "latest_file_mtimes_attributed")["reason"], "no known filesystem roots")

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

    def test_screen_counter_denominator_includes_admission_losses(self):
        self.db.execute("CREATE TABLE screen_captures(id INTEGER,ts INTEGER)")
        self.db.execute("CREATE TABLE screen_occurrences(capture_id INTEGER)")
        self.db.execute("CREATE TABLE screen_capture_counters(ts INTEGER,acquired INTEGER,dropped_captures INTEGER,admission_losses INTEGER)")
        self.db.execute("INSERT INTO screen_captures VALUES(1,?)", (START + 10,))
        self.db.execute("INSERT INTO screen_occurrences VALUES(1)")
        self.db.execute("INSERT INTO screen_capture_counters VALUES(?,3,1,1)", (START + 10,))
        row = self.metric(self.report(), "captures_kept")
        self.assertEqual((row["numerator"], row["denominator"]), (1, 3))

    def test_cli_unexpected_error_sanitized_and_snapshot_deleted(self):
        scratch = self.root / "invented-scratch"
        scratch.mkdir()
        original = fc.snapshot
        args = [str(self.database), "--from", str(START), "--to", str(START + 60)]
        out, err = io.StringIO(), io.StringIO()
        with patch.object(fc, "snapshot", side_effect=lambda path: original(path, scratch)), \
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
        self.db.execute("INSERT INTO evidence VALUES(NULL,?,'screen',?,NULL,'','',?)", (START + offset, app, text))

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
        self.db.execute("CREATE TABLE agent_log_events(id INTEGER,ts INTEGER,role TEXT)")
        self.db.execute("CREATE TABLE agent_log_payloads(event_id INTEGER,payload TEXT)")
        self.db.execute("INSERT INTO agent_log_events VALUES(1,?,'assistant')", (START + 16,))
        self.db.execute("INSERT INTO agent_log_payloads VALUES(1,?)", (secret,))
        self.db.execute("CREATE TABLE git_commits(ts INTEGER,message TEXT)")
        self.db.execute("INSERT INTO git_commits VALUES(?,?)", (START + 17, secret))
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
        self.assertEqual({r["day"] for r in report["measurements"]}, {day})
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

    def test_c12_other_monitor_metadata_without_guessing(self):
        ref = self.reference([(10, "invented.app", "different window", "", "text")])
        self.sample(10)
        self.db.execute("ALTER TABLE samples ADD COLUMN monitor_id INTEGER")
        self.db.execute("UPDATE samples SET monitor_id=1")
        folder = self.root / "invented-monitor-bundles"
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob("window-*.json")).read_text())
        self.assertEqual(bundle["reference"][0]["comparison"]["focused_per_ours"], "other_monitor")

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

    def test_c7_roots_survive_days_and_are_walked_once(self):
        roots = [self.root / name for name in ("invented-repo-a", "invented-repo-b")]
        files = []
        for root in roots:
            root.mkdir()
            (root / ".git").mkdir()
            path = root / "invented-file"
            path.write_text("invented")
            os.utime(path, (START + 86410, START + 86410))
            files.append(path)
        self.sample(10, document=str(files[0]))
        self.sample(86410, document=str(files[1]))
        with patch.object(fc.os, "walk", wraps=os.walk) as walk:
            report = self.report(end=172800)
        rows = [r for r in report["measurements"] if r["check"] == "C7"]
        self.assertEqual([(r["numerator"], r["denominator"], r["known_roots"]) for r in rows], [(0, 0, 2), (1, 2, 2)])
        self.assertEqual(walk.call_count, 2)

    def test_c7_single_root_without_later_attribution_still_counts(self):
        repo = self.root / "invented-repo"
        repo.mkdir()
        file = repo / "invented-file"
        file.write_text("invented")
        os.utime(file, (START + 86410, START + 86410))
        self.sample(10, document=str(file))
        row = next(r for r in self.report(end=172800)["measurements"] if r["check"] == "C7" and r["day"] != datetime.fromtimestamp(START, timezone.utc).date().isoformat())
        self.assertEqual((row["numerator"], row["denominator"], row["known_roots"]), (0, 1, 1))
        self.assertIsNone(row["reason"])

    def test_c7_deleted_document_keeps_existing_repository(self):
        repo = self.root / "invented-repo"
        repo.mkdir()
        (repo / ".git").mkdir()
        sibling = repo / "invented-survivor"
        sibling.write_text("invented")
        os.utime(sibling, (START + 10, START + 10))
        self.sample(10, document=str(repo / "invented-deleted"))
        report = self.report()
        row = self.metric(report, "latest_file_mtimes_attributed")
        self.assertEqual((row["numerator"], row["denominator"], row["known_roots"]), (0, 1, 1))
        self.assertEqual(report["diagnostics"]["known_document_paths_unavailable"], 1)

    def test_c7_known_roots_cannot_enter_credential_or_symlink_ancestors(self):
        protected = self.root / ".ssh"
        protected.mkdir()
        known = protected / "invented-file"
        known.write_text("invented")
        alias = self.root / "invented-alias"
        alias.symlink_to(protected, target_is_directory=True)
        self.sample(10, document=str(known))
        self.sample(10, document=str(alias / "invented-deleted"))
        with patch.object(fc.os, "walk", wraps=os.walk) as walk:
            row = self.metric(self.report(), "latest_file_mtimes_attributed")
        self.assertEqual(row["known_roots"], 0)
        walk.assert_not_called()

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
        self.evidence(10, "claude:invented-10")
        self.evidence(11, "claude:invented-10", body="[redacted]")
        row = self.metric(self.report(), "typed_instructions_stored", "claude")
        self.assertEqual((row["numerator"], row["denominator"], row["identity_matched_content_changed"]), (2, 2, 1))

    def test_c5_mixed_unsupported_acquisition_schema_uses_counters_once(self):
        self.db.execute("CREATE TABLE screen_captures(ts INTEGER)")
        self.db.execute("CREATE TABLE screen_occurrences(capture_id INTEGER)")
        self.db.execute("CREATE TABLE screen_capture_counters(ts INTEGER,acquired INTEGER,stored INTEGER,dropped_captures INTEGER,admission_losses INTEGER)")
        self.db.execute("INSERT INTO screen_capture_counters VALUES(?,10,7,2,1)", (START + 10,))
        row = self.metric(self.report(), "captures_kept")
        self.assertEqual((row["numerator"], row["denominator"], row["dropped_captures"], row["admission_losses"]), (7, 10, 2, 1))
        self.assertIsNone(row["reason"])

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
        self.assertEqual(err.getvalue(), "Fidelity check failed: input unavailable, invalid range or unsupported data; no content emitted.\n")
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
            if line.startswith(("C1 ", "C2 ")) and "(codex)" in line:
                self.assertIn("/1", line)
                self.assertNotIn("no typed instructions", line)

    def test_reference_live_readonly_wal_and_no_backup(self):
        ref = self.reference()
        with closing(sqlite3.connect(ref)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("INSERT INTO frames(id,timestamp,app_name,focused) VALUES(1,?,'invented.app',1)", (START + 10,))
            writer.commit()
            before = ref.read_bytes(), ref.stat().st_mtime_ns
            with patch.object(fc, "snapshot", side_effect=AssertionError("must not copy reference")):
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

    def test_chrome_locked_backup_falls_back_to_private_file_copy(self):
        chrome = self.chrome([(10, "https://invented.invalid/doc")])
        self.sample(10, document="invented.invalid/doc")
        before = chrome.read_bytes(), chrome.stat().st_mtime_ns
        self.db.commit()
        with fc.readonly(self.database) as db, patch.object(fc, "snapshot", side_effect=sqlite3.OperationalError("locked")):
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
            with fc.readonly(self.database) as ours, patch.object(fc, "snapshot", side_effect=sqlite3.OperationalError()):
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
        with patch.object(fc, "snapshot", side_effect=AssertionError()), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
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
            self.report(reference=ref)


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
        self.logs('claude', [self.claude(offset, promptSource='typed') for offset in (10.25, 20.25, 30.25)])
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
            for index, stamp in enumerate(('not a timestamp', '2032-06-01T00:00:00Z' + ' ' * fc.MAX_TEXT_FIELD, None), 1):
                db.execute("INSERT INTO frames(id,timestamp,focused) VALUES(?,?,1)", (index, stamp))
        self.sample(30)
        self.db.execute("UPDATE samples SET ts='invalid'")
        report = self.report(reference=ref)
        row = self.metric(report, 'reference_frames_attributed')
        self.assertEqual(row['denominator'], 1)
        self.assertEqual((row['unavailable_records_unplaced'], row['invalid_timestamps'], row['oversized_fields']), (4, 3, 1))
        self.assertEqual(row['affected_records'], 4)
        self.assertTrue(row['partial_input'])

    def test_reference_timestamp_index_is_reused_for_range_cursors(self):
        ref = self.reference([(10, 'invented.app', '', '', 'firstterm'),
                              (20, 'invented.app', '', '', 'secondterm')])
        with fc.reference_snapshot(ref) as db, fc.workspace() as work:
            queries = []
            db.set_trace_callback(queries.append)
            for low, high in ((0, 15), (15, 30), (0, 30)):
                rows = list(fc.time_rows(db, 'frames', ['timestamp'], 'timestamp', START + low, START + high, work))
                self.assertEqual(len(rows), 2 if high - low == 30 else 1)
            scans = [query for query in queries if 'AS "rowid"' in query]
            self.assertEqual(len(scans), 1)
            self.assertIn('NOT INDEXED WHERE 1', scans[0])

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

    def test_evidence_apps_use_one_bounded_lifetime_pass(self):
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
        lifetime = [query for query in queries if 'FROM "samples" NOT INDEXED WHERE 1' in query and 'AS "bundle_id"' in query]
        self.assertEqual(len(lifetime), 1)

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
        recalls = [r for r in report['measurements'] if r['check'] == 'C10']
        self.assertEqual(len(recalls), 4)
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
            apps = fc.EvidenceApps(self.db, work, fc.InputLimits(lambda ts: 'invented-day', ['invented-day']))
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
                rows = [r for r in report['measurements'] if r['check'] == 'C10' and r['day'] == day(START + frame_offset)]
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
        self.histories()
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
        self.db.execute('CREATE TABLE agent_log_events(id INTEGER,ts INTEGER)')
        self.db.execute('CREATE TABLE agent_log_payloads(event_id INTEGER,body BLOB)')
        self.db.execute('INSERT INTO agent_log_events VALUES(1,?)', (START + 10,))
        self.db.execute('INSERT INTO agent_log_payloads VALUES(1,?)', (blob,))
        folder = self.root / 'invented-blob-bundles'
        self.report(end=300, reference=ref, references=fc.ReferenceInputs(bundle_dir=folder))
        bundle = json.loads(next(folder.glob('window-*.json')).read_text())
        payload = bundle['our_only_candidates']['agent_payloads'][0]['body']
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
                db.execute("INSERT INTO samples VALUES(NULL,?,replace(hex(zeroblob(?)),'00','x'),'invented.app','','',0,0,0,0,0,0,0)",
                           (START - 86400, size))
            db.execute("INSERT INTO samples VALUES(NULL,?,'invented.app','invented.app','','',1,0,0,0,0,0,0)", (START + 10,))
            db.execute("INSERT INTO evidence VALUES(NULL,?,'screen','invented.app',NULL,'','','ordinary prose')", (START + 10,))
        if dimension.startswith('predicate_timestamp'):
            with closing(sqlite3.connect(root / 'invented-scaling-reference.sqlite')) as db, db:
                stamp = datetime.fromtimestamp(START + 10, timezone.utc).isoformat()
                db.execute("INSERT INTO frames VALUES(2,? || replace(hex(zeroblob(?)),'00',' '),'invented.app','',1,'ordinary prose')",
                           (stamp, size))
    if dimension == 'app_history':
        with closing(sqlite3.connect(root / 'invented.sqlite')) as db, db:
            db.executemany("INSERT INTO samples VALUES(NULL,?,'invented.bundle',?,'','',0,0,0,0,0,0,0)",
                           ((START - size + i, 'invented historic app ' + str(i)) for i in range(size)))
            db.execute("INSERT INTO samples VALUES(NULL,?,'invented.bundle','invented.app','','',0,0,0,0,0,0,0)", (START + 10,))
            db.execute("INSERT INTO evidence VALUES(NULL,?,'screen','invented.bundle',NULL,'','','ordinary prose')", (START + 10,))
    if dimension == 'history_length':
        with closing(sqlite3.connect(root / 'invented.sqlite')) as db, db:
            db.execute('CREATE TABLE awake_history(since REAL,awake INTEGER)')
            db.execute('CREATE TABLE exclusion_history(since REAL,excluded INTEGER)')
            for table in ('awake_history', 'exclusion_history', 'log_recording_history'):
                db.execute('CREATE INDEX ' + table + '_since ON ' + table + '(since)')
            db.executemany('INSERT INTO log_recording_history VALUES(?,?,1,NULL)',
                           ((i + 1, START - size + i) for i in range(size)))
            db.executemany('INSERT INTO log_recording_history VALUES(?,?,1,NULL)',
                           ((size + i + 1, START + 100 * i / size) for i in range(size)))
            db.execute('INSERT INTO awake_history VALUES(?,1)', (START - 1,))
            db.execute('INSERT INTO exclusion_history VALUES(?,0)', (START - 1,))
    if dimension == 'line_length':
        folder = root / 'claude/projects'
        folder.mkdir(parents=True)
        with (folder / 'invented.jsonl').open('wb') as stream:
            stream.write(b'{"message":{"content":"')
            chunk = b'x' * 65536
            for _ in range(size // len(chunk)):
                stream.write(chunk)
            stream.write(b'"}}\n')


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
                stream.write(json.dumps(case.claude(index, promptSource="typed")) + "\n")
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
