#!/usr/bin/env python3
"""Read-only, content-free layer-1 recorder measurements. See FidelityCheck.md."""

import atexit
import argparse
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from contextlib import contextmanager
from contextlib import ExitStack
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
import hashlib
from functools import lru_cache
import json
import math
import os
from pathlib import Path
import re
import random
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


@dataclass
class ReferenceInputs:
    chrome_histories: tuple = ()
    shell_histories: tuple = ()
    tolerance: int = 5
    terminal_apps: tuple = ()
    reference_database: object = None
    bundle_dir: object = None
    bundle_count: int = 20
    seed: int = 0
    window_start: object = None
    window_end: object = None
    selected_days: tuple = ()


TERMINAL_BUNDLES = frozenset(("com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                              "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty"))

# These are measurement limits, never recorder admission rules. Oversized fields
# are unavailable, rather than potentially unsafe fragments of a credential.
MAX_TEXT_FIELD = 256 * 1024
MAX_RECORD = 1024 * 1024
MAX_TERM = 64
MAX_TERMS = 4096
MAX_APP_GROUPS = 128
MAX_BUNDLE_ROWS = 256
MAX_BUNDLES = 100


def quoted(name):
    return '"' + name.replace('"', '""') + '"'


def guarded_text(function, column, *arguments):
    # CASE guarantees that SQLite never evaluates the function on overflow text.
    args = ','.join((column, *map(str, arguments)))
    return f"CASE WHEN octet_length({column})<={MAX_TEXT_FIELD} THEN {function}({args}) END"


def real_text_sizes(db, table):
    # SQLite inserts RealAffinity before octet_length on REAL declarations,
    # defeating its overflow-page shortcut even when the stored value is TEXT.
    # Incremental blob handles expose TEXT/BLOB byte sizes without reading them.
    result = {}
    for _, column, declared, *_ in db.execute('PRAGMA table_info(' + quoted(table) + ')'):
        if not any(affinity in declared.upper() for affinity in ('REAL', 'FLOA', 'DOUB')):
            continue
        function = '__fidelity_octets_' + digest(table + ':' + column)[:16]
        if not any(row[0] == function for row in db.execute('PRAGMA function_list')):
            def size(rowid, column=column):
                try:
                    with db.blobopen(table, column, rowid, readonly=True) as value:
                        return len(value)
                except sqlite3.OperationalError as error:
                    if str(error).startswith('cannot open value of type '):
                        return 0  # NULL and numeric SQLite values have no text payload.
                    raise
            db.create_function(function, 1, size)
        result[column] = function + '(rowid)'
    return result


def bounded_where(where, sizes):
    guards = [f'{size}<={MAX_TEXT_FIELD}' for column, size in sizes.items()
              if re.search(r'\b' + re.escape(column) + r'\b', where, re.I)]
    return 'CASE WHEN ' + ' AND '.join(guards) + ' THEN (' + where + ') END' if guards else where


def bounded_columns(columns, sizes=None):
    fields = []
    expressions = columns.items() if isinstance(columns, dict) else ((name, quoted(name)) for name in columns)
    for index, (name, column) in enumerate(expressions):
        value = guarded_text('substr', column, 1, MAX_TEXT_FIELD)
        length = guarded_text('length', column)
        fields += [f"CASE WHEN typeof({column}) IN ('text','blob') THEN coalesce({value},'') ELSE {column} END AS {quoted(name)}",
                   f"CASE WHEN typeof({column}) IN ('text','blob') THEN CASE WHEN octet_length({column})>{MAX_TEXT_FIELD} THEN octet_length({column}) ELSE {length} END ELSE 0 END AS __length_{index}"]
        if sizes and name in sizes:
            size = sizes[name]
            fields[-2] = f"CASE WHEN {size}<={MAX_TEXT_FIELD} THEN " + fields[-2].rsplit(' AS ', 1)[0] + f" ELSE '' END AS {quoted(name)}"
            fields[-1] = f"CASE WHEN {size}>{MAX_TEXT_FIELD} THEN {size} ELSE " + fields[-1].rsplit(' AS ', 1)[0] + f" END AS __length_{index}"
    return ','.join(fields)


def bounded_row(row, columns):
    item, oversized = {}, []
    for index, name in enumerate(columns):
        length = row[2 * index + 1] or 0
        value = row[2 * index]
        if length > MAX_TEXT_FIELD:
            oversized.append(name)
            value = b'' if isinstance(value, bytes) else ''
        item[name] = value
    if oversized:
        item['_oversized_fields'] = oversized
    return item


def bounded_rows(db, table, where='1', parameters=(), columns=None, suffix='', scan=False):
    columns = columns or sorted(Schema(db).columns(table))
    sizes = real_text_sizes(db, table)
    query = ('SELECT ' + bounded_columns(columns, sizes) + ' FROM ' + quoted(table) +
             (' NOT INDEXED' if sizes or scan else '') + ' WHERE ' + bounded_where(where, sizes) + ' ' + suffix)
    for row in db.execute(query, parameters):
        yield bounded_row(row, columns)


def bounded_records(stream, cap=MAX_RECORD):
    """Read a bounded prefix and discard the remainder in bounded chunks."""
    while True:
        prefix = stream.readline(cap + 1)
        if not prefix:
            return
        oversized, tail, nonempty = len(prefix) > cap, prefix[-2:], bool(prefix.strip())
        chunk = prefix
        while not chunk.endswith(b'\n'):
            chunk = stream.readline(cap)
            if not chunk:
                break
            tail = (tail + chunk)[-2:]
            nonempty = nonempty or bool(chunk.strip())
        yield prefix, oversized, tail.rstrip(b'\n').endswith(b'\\'), nonempty


def within_time(first, second, tolerance):
    return abs(first - second) <= tolerance


class InputLimits:
    """Audit each source once; repeated measurement cursors never double-count."""
    def __init__(self, day_of, days, halo=60):
        self.day_of, self.days, self.halo = day_of, frozenset(days), halo
        self.counts = defaultdict(Counter)

    def affected_days(self, stamp, halo=0):
        return {self.day_of(stamp + offset) for offset in (-halo, 0, halo)} & self.days

    def audit(self, name, rows):
        for row in rows:
            fields = row.get('_oversized_fields', ())
            if not fields:
                continue
            stamp = reference_time(row.get('ts', row.get('timestamp', row.get('since'))))
            if stamp is None or name.endswith('_history'):
                affected = [None]
            else:
                affected = self.affected_days(stamp, self.halo if name in ('samples', 'evidence') else 0)
            for day in affected:
                count = self.counts[(name, day)]
                count['oversized_fields'] += len(fields)
                count['affected_records'] += 1

    def audit_timestamps(self, db, table, column):
        # Invalid dates cannot be placed in a selected day. Audit once before
        # range predicates discard them, retrieving only the bounded timestamp.
        for row in bounded_rows(db, table, columns=[column], scan=True):
            if reference_time(row[column]) is not None:
                continue
            count = self.counts[(table, None)]
            count['unavailable_records_unplaced'] += 1
            count['affected_records'] += 1
            if row.get('_oversized_fields'):
                count['oversized_fields'] += 1
            else:
                count['invalid_timestamps'] += 1

    def apply(self, item, sources):
        count = Counter()
        for source in sources:
            count.update(self.counts[(source, item.get('day'))])
            count.update(self.counts[(source, None)])
        for key, value in count.items():
            item[key] = item.get(key, 0) + value
        if count:
            previous = item.get('reason')
            note = 'partial: oversized or invalid input fields unavailable'
            item.update(partial_input=True, reason=previous + '; ' + note if previous else note)


class TimeIndex:
    """Spill all population-sized timestamp indices to a bounded-cache store."""
    def __init__(self, db, name):
        self.db, self.name = db, quoted(name)
        db.execute('CREATE TABLE IF NOT EXISTS ' + self.name + '(identity TEXT,ts REAL,PRIMARY KEY(identity,ts))')
        db.execute('DELETE FROM ' + self.name)

    def add(self, identity, stamp):
        self.db.execute('INSERT OR IGNORE INTO ' + self.name + ' VALUES(?,?)', (identity, stamp))

    def near(self, identity, stamp, tolerance):
        row = self.db.execute('SELECT ts FROM ' + self.name + ' WHERE identity=? AND ts>=? AND ts<=? LIMIT 1',
                              (identity, stamp - tolerance, stamp + tolerance)).fetchone()
        return row is not None and within_time(row[0], stamp, tolerance)


def digest(value):
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()


def epoch(value):
    if isinstance(value, (int, float)) and math.isfinite(value):
        return value
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is not None:
                return parsed.timestamp()
        except ValueError:
            pass
    return None


@contextmanager
def snapshot(database, temp_parent=None, deadline_seconds=60):
    # mode=ro is essential: opening a missing input must never create a database.
    with tempfile.TemporaryDirectory(prefix="fidelity-", dir=temp_parent) as folder:
        target = Path(folder) / "snapshot.sqlite"
        source = sqlite3.connect(Path(database).absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)
        try:
            source.execute("PRAGMA query_only=ON")
            dest = sqlite3.connect(target)
            try:
                deadline = time.monotonic() + deadline_seconds
                def progress(status, remaining, total):
                    if time.monotonic() > deadline:
                        raise TimeoutError()
                source.backup(dest, pages=256, progress=progress, sleep=.05)
            finally:
                dest.close()
        finally:
            source.close()
        db = sqlite3.connect(target.as_uri() + "?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA query_only=ON")
            yield db
        finally:
            db.close()


class Schema:
    def __init__(self, db):
        self.db = db
        self.tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    def columns(self, table):
        if table not in self.tables:
            return set()
        return {r[1] for r in self.db.execute('PRAGMA table_info("' + table + '")')}

    def has(self, table, *columns):
        return set(columns) <= self.columns(table) and table in self.tables

    def find(self, *names):
        return next((n for n in names if n in self.tables), None)

    def column(self, table, *names):
        return next((n for n in names if n in self.columns(table)), None)


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(b["text"] for b in value if isinstance(b, dict)
                         and b.get("type") in ("text", "Text", "input_text", "output_text")
                         and isinstance(b.get("text"), str))
    return ""


def shingles(text):
    words = text.split()
    return {digest(" ".join(words[i:i + 8])) for i in range(len(words) - 7)}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def is_command_call(block):
    name = str(block.get("name", "")).lower().split(".")[-1]
    return name in ("bash", "shell", "shell_command", "exec_command", "exec", "write_stdin")


@dataclass
class Instruction:
    tool: str
    session: str
    origin: str
    ts: int
    source: str
    source_id: str
    body_digest: str
    length: int
    pieces: set = field(default_factory=set)
    marker: str = ""
    app: str = ""
    sender: str = "unknown"
    queued: bool = False
    native_identity: bool = False
    source_aliases: set = field(default_factory=set)


def tool_marker(fields):
    if fields.get("parent_thread_id") or fields.get("isSidechain"):
        return "agent"
    for key in ("source", "thread_source"):
        value = fields.get(key)
        if isinstance(value, dict) and "subagent" in value:
            return "agent"
        if isinstance(value, str) and value in ("subagent", "peer", "automation", "scheduled-task"):
            return "agent"
    if any(fields.get(k) for k in ("isMeta", "isCompactSummary", "isVisibleInTranscriptOnly",
                                   "scheduledTaskId", "scheduledFireId")):
        return "non_instruction"
    if fields.get("promptSource") in ("system", "sdk"):
        return "agent"
    origin = fields.get("origin", {})
    if isinstance(origin, dict) and origin.get("kind"):
        return "human" if origin["kind"] == "human" else "agent"
    if fields.get("promptSource") in ("typed", "queued", "suggestion") or fields.get("humanTurn") is True:
        return "human"
    if fields.get("humanTurn") is False:
        return "agent"
    return ""


def combined_marker(*fields):
    markers = [tool_marker(value) for value in fields]
    return next((m for m in markers if m and m != "human"), "human" if "human" in markers else "")


MAX_LOG_LINE = 1024 * 1024


def bounded_lines(stream, diagnostics, tool):
    for raw, oversized, _, _ in bounded_records(stream, MAX_LOG_LINE):
        if oversized:
            diagnostics[tool + "_oversized_log_lines"] += 1
            continue
        yield raw.decode('utf-8')


def instruction_json(candidate):
    value = asdict(candidate)
    value["pieces"] = sorted(value["pieces"])
    value["source_aliases"] = sorted(value["source_aliases"])
    return json.dumps(value)


def decode_instruction(encoded):
    value = json.loads(encoded)
    for key in ("pieces", "source_aliases"):
        value[key] = set(value[key])
    return Instruction(**value)


class DiskCandidates:
    def __init__(self, db):
        self.db = db
        db.executescript("""
            CREATE TABLE instructions(id INTEGER PRIMARY KEY, tool TEXT, scope TEXT, identity TEXT,
              session TEXT, ts INTEGER, body TEXT, native INTEGER, payload TEXT);
            CREATE INDEX instruction_identity ON instructions(tool,scope,identity);
            CREATE INDEX instruction_group ON instructions(session,ts,body,native);
            CREATE TABLE aliases(tool TEXT, scope TEXT, identity TEXT, source TEXT,
              PRIMARY KEY(tool,scope,identity,source));
        """)

    def append(self, candidate):
        scope = "" if candidate.tool == "claude" and candidate.native_identity else candidate.session
        self.db.execute("INSERT INTO instructions VALUES(NULL,?,?,?,?,?,?,?,?)",
                        (candidate.tool, scope, candidate.source_id, candidate.session, candidate.ts,
                         candidate.body_digest, candidate.native_identity, instruction_json(candidate)))
        self.db.execute("INSERT OR IGNORE INTO aliases VALUES(?,?,?,?)",
                        (candidate.tool, scope, candidate.source_id, candidate.source))

    def finalize(self):
        self.db.execute("DELETE FROM instructions WHERE id NOT IN (SELECT min(id) FROM instructions GROUP BY tool,scope,identity)")
        self.db.execute("""DELETE FROM instructions AS a WHERE native=0 AND (
            EXISTS(SELECT 1 FROM instructions b WHERE b.session=a.session AND b.ts=a.ts AND b.body=a.body AND b.native=1)
            OR id<>(SELECT min(id) FROM instructions b WHERE b.session=a.session AND b.ts=a.ts AND b.body=a.body))""")

    def __iter__(self):
        for row in self.db.execute("SELECT tool,scope,identity,payload FROM instructions ORDER BY id"):
            candidate = decode_instruction(row[3])
            yield candidate

    def update(self, candidate):
        scope = "" if candidate.tool == "claude" and candidate.native_identity else candidate.session
        self.db.execute("UPDATE instructions SET payload=? WHERE tool=? AND scope=? AND identity=?",
                        (instruction_json(candidate), candidate.tool, scope, candidate.source_id))


class DiskOutgoing:
    def __init__(self, db):
        self.db = db
        db.executescript("""CREATE TABLE outgoing(id INTEGER PRIMARY KEY,ts INTEGER,session TEXT);
            CREATE TABLE outgoing_pieces(call INTEGER,piece TEXT);
            CREATE INDEX outgoing_piece ON outgoing_pieces(piece,call);""")

    def append(self, value):
        stamp, session, pieces = value
        identity = self.db.execute("INSERT INTO outgoing VALUES(NULL,?,?)", (stamp, session)).lastrowid
        self.db.executemany("INSERT INTO outgoing_pieces VALUES(?,?)", ((identity, p) for p in pieces))


class DiskReceived:
    def __init__(self, db):
        self.db = db
        db.execute("CREATE TABLE received(session TEXT,ts INTEGER,pieces TEXT)")
        db.execute("CREATE INDEX received_session ON received(session)")

    def __getitem__(self, session):
        owner = self
        class Session:
            def __len__(self):
                return owner.db.execute("SELECT count(*) FROM received WHERE session=?", (session,)).fetchone()[0]
            def append(self, value):
                owner.db.execute("INSERT INTO received VALUES(?,?,?)", (session, value[0], json.dumps(sorted(value[1]))))
            def __iter__(self):
                return ((r[0], set(json.loads(r[1]))) for r in owner.db.execute(
                    "SELECT ts,pieces FROM received WHERE session=?", (session,)))
        return Session()


class DiskMap:
    def __init__(self, db, name):
        self.db, self.name = db, name
        db.execute('CREATE TABLE "' + name + '"(key TEXT PRIMARY KEY,value TEXT)')
    def __setitem__(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO "' + self.name + '" VALUES(?,?)', (str(key), json.dumps(value)))
    def __contains__(self, key):
        return self.db.execute('SELECT 1 FROM "' + self.name + '" WHERE key=?', (str(key),)).fetchone() is not None
    def add(self, key):
        self[key] = True
    def pop(self, key, default=None):
        row = self.db.execute('SELECT value FROM "' + self.name + '" WHERE key=?', (str(key),)).fetchone()
        self.db.execute('DELETE FROM "' + self.name + '" WHERE key=?', (str(key),))
        return json.loads(row[0]) if row else default
    def clear(self):
        self.db.execute('DELETE FROM "' + self.name + '"')


class DiskKeys:
    def __init__(self, db, samples):
        self.db = db
        db.execute("CREATE TABLE input_keys(ts INTEGER,app TEXT,PRIMARY KEY(ts,app))")
        for sample in samples:
            app = sample["bundle_id"] or sample["app"]
            if sample["keys"] > 0 and app:
                db.execute("INSERT OR IGNORE INTO input_keys VALUES(?,?)", (sample["ts"], digest(app)))
    def get(self, stamp, default=()):
        return {r[0] for r in self.db.execute("SELECT app FROM input_keys WHERE ts=?", (stamp,))}

    def near(self, stamp):
        for app, observed in self.db.execute('SELECT app,min(ts) FROM input_keys WHERE ts>=? AND ts<=? GROUP BY app',
                                              (stamp - 1, stamp + 1)):
            if within_time(observed, stamp, 1):
                yield app

    def has(self, app, stamp):
        row = self.db.execute('SELECT ts FROM input_keys WHERE app=? AND ts>=? AND ts<=? LIMIT 1',
                              (app, stamp - 1, stamp + 1)).fetchone()
        return row is not None and within_time(row[0], stamp, 1)


def classify_disk(candidates, outgoing, received, keys):
    db = candidates.db
    db.executescript("""CREATE TABLE votes(session TEXT,tool TEXT,origin TEXT,app TEXT,n INTEGER,
        PRIMARY KEY(session,app));
        CREATE TABLE session_apps(session TEXT PRIMARY KEY,tool TEXT,origin TEXT,app TEXT);
        CREATE TABLE compare_pieces(piece TEXT PRIMARY KEY);""")
    for c in candidates:
        if c.marker in ("agent", "non_instruction", "imported") or c.queued:
            continue
        for app in keys.near(c.ts):
            db.execute("INSERT INTO votes VALUES(?,?,?,?,1) ON CONFLICT(session,app) DO UPDATE SET n=n+1",
                       (c.session, c.tool, c.origin, app))
    db.execute("""INSERT INTO session_apps SELECT session,tool,origin,app FROM votes a
        WHERE n>=2 AND n*1.0/(SELECT sum(n) FROM votes b WHERE b.session=a.session)>=.8""")
    for c in candidates:
        row = db.execute("SELECT app FROM session_apps WHERE session=?", (c.session,)).fetchone()
        if not row and c.origin:
            row = db.execute("""SELECT app FROM session_apps WHERE tool=? AND origin=? GROUP BY app
                HAVING count(*)>=5 AND count(*)*1.0/(SELECT count(*) FROM session_apps WHERE tool=? AND origin=?)>=.8""",
                (c.tool, c.origin, c.tool, c.origin)).fetchone()
        c.app = row[0] if row else ""
        if c.marker:
            c.sender = c.marker
        else:
            provenance = False
            from itertools import chain
            for stamp, pieces in chain(((c.ts, c.pieces),), received[c.session]):
                if not pieces:
                    continue
                db.execute("DELETE FROM compare_pieces")
                db.executemany("INSERT INTO compare_pieces VALUES(?)", ((p,) for p in pieces))
                provenance = db.execute("""SELECT 1 FROM outgoing_pieces p JOIN compare_pieces c ON c.piece=p.piece
                    JOIN outgoing o ON o.id=p.call WHERE o.ts<=? AND o.session<>? GROUP BY o.id
                    HAVING count(*)>=? LIMIT 1""", (stamp, c.session, len(pieces) * .5)).fetchone() is not None
                if provenance:
                    break
            c.sender = "agent" if provenance else "human" if c.app and keys.has(c.app, c.ts) else "unknown"
        candidates.update(c)


def read_logs(homes, diagnostics, work):
    """Spill lifetime identities and provenance to private, bounded-cache SQLite."""
    candidates, outgoing, received = DiskCandidates(work), DiskOutgoing(work), DiskReceived(work)
    seen_files = DiskMap(work, "seen_files")
    pending, delivered, command_ids = (DiskMap(work, name) for name in ("pending", "delivered", "command_ids"))
    for tool, roots in homes.items():
        for home in roots:
            folders = [Path(home) / "projects"] if tool == "claude" else [
                Path(home) / "sessions", Path(home) / "archived_sessions"]
            for folder in folders:
                if not folder.exists():
                    continue
                for path in folder.rglob("*.jsonl"):
                    if path.is_symlink() or not path.is_file():
                        diagnostics["symlink_log_skipped"] += 1
                        continue
                    identity = digest(path.resolve())
                    if identity in seen_files:
                        continue
                    seen_files.add(identity)
                    diagnostics[tool + "_source_files"] += 1
                    meta = {}
                    pending.clear()
                    delivered.clear()
                    command_ids.clear()
                    malformed_file = False
                    session = digest(tool + ":" + path.stem)
                    try:
                        with path.open('rb') as stream:
                            diagnostics[tool + "_files"] += 1
                            for raw in bounded_lines(stream, diagnostics, tool):
                                try:
                                    line = json.loads(raw)
                                    if not isinstance(line, dict):
                                        raise ValueError()
                                except (ValueError, UnicodeError):
                                    diagnostics["malformed_log_lines"] += 1
                                    diagnostics[tool + "_malformed_log_lines"] += 1
                                    if not malformed_file:
                                        diagnostics[tool + "_malformed_log_files"] += 1
                                        malformed_file = True
                                    continue
                                payload = line.get("payload")
                                payload = payload if isinstance(payload, dict) else {}
                                kind, stamp = line.get("type"), epoch(line.get("timestamp"))
                                if kind == "session_meta":
                                    meta = payload
                                    session = digest(tool + ":" + str(meta.get("id", path.stem)))
                                    continue
                                if tool == "claude" and line.get("sessionId"):
                                    session = digest(tool + ":" + str(line["sessionId"]))
                                if tool == "claude" and line.get("entrypoint"):
                                    meta["originator"] = str(line["entrypoint"])
                                if stamp is None:
                                    diagnostics["untimed_log_lines"] += 1
                                    continue
                                # Only outbound tool arguments establish provenance, not assistant prose.
                                calls, results = [], []
                                message = line.get("message", {})
                                message = message if isinstance(message, dict) else {}
                                content = message.get("content", [])
                                content = content if isinstance(content, (list, str)) else []
                                if isinstance(content, list):
                                    for block in content:
                                        if isinstance(block, dict) and block.get("type") == "tool_use":
                                            calls.append(block.get("input", {}))
                                            if is_command_call(block) and block.get("id"):
                                                command_ids.add(block["id"])
                                        if (isinstance(block, dict) and block.get("type") == "tool_result"
                                                and block.get("tool_use_id") in command_ids):
                                            results.append(block.get("content", ""))
                                if kind == "response_item" and payload.get("type") in ("function_call", "custom_tool_call"):
                                    calls.append(payload.get("arguments", payload.get("input", "")))
                                    if is_command_call(payload) and payload.get("call_id"):
                                        command_ids.add(payload["call_id"])
                                if (kind == "response_item" and payload.get("type") in ("function_call_output", "custom_tool_call_output")
                                        and payload.get("call_id") in command_ids):
                                    results.append(payload.get("output", ""))
                                for call in calls:
                                    if isinstance(call, str):
                                        try:
                                            call = json.loads(call)
                                        except ValueError:
                                            pass
                                    pieces = shingles(" ".join(strings(call)))
                                    if pieces:
                                        outgoing.append((stamp, session, pieces))
                                if len(received[session]) < 6:
                                    for result in results[:6 - len(received[session])]:
                                        received[session].append((stamp, shingles(" ".join(strings(result)))))
                                attachment = line.get("attachment", {})
                                attachment = attachment if isinstance(attachment, dict) else {}
                                queued_attachment = kind == "attachment" and attachment.get("type") == "queued_command"
                                if tool == "claude" and kind == "queue-operation":
                                    body = text_content(line.get("content"))
                                    key = digest(body)
                                    if line.get("operation") == "enqueue":
                                        pending[key] = (stamp, line.get("commandUuid"))
                                    elif line.get("operation") == "remove" and line.get("reason") != "absorbed_mid_turn":
                                        pending.pop(key, None)
                                    continue
                                body, native_id, marker, queued = "", None, "", False
                                if tool == "claude" and (kind == "user" or queued_attachment):
                                    fields = attachment if queued_attachment else line
                                    body = text_content(attachment.get("prompt") if queued_attachment else message.get("content"))
                                    native_id = attachment.get("source_uuid", line.get("uuid")) if queued_attachment else line.get("uuid")
                                    native_id = "claude:" + str(native_id) if native_id else None
                                    marker = combined_marker(line, fields)
                                    if "subagents" in path.relative_to(folder).parts:
                                        marker = "agent"
                                    if line.get("toolUseResult") is not None or any(
                                            isinstance(b, dict) and b.get("type") == "tool_result"
                                            for b in content if isinstance(content, list)):
                                        marker = "non_instruction"
                                    if body.lstrip().startswith(("<task-notification>", "<local-command-stdout>",
                                                                 "<local-command-stderr>", "<bash-stdout>",
                                                                 "<bash-stderr>", "[Request interrupted by user")):
                                        marker = "non_instruction"
                                    queued = queued_attachment or line.get("promptSource") == "queued"
                                    key = digest(body)
                                    if queued_attachment:
                                        stamp, original_id = pending.pop(key, (stamp, None))
                                        native_id = "claude:" + str(original_id) if original_id else native_id
                                        delivered[key] = (stamp, native_id)
                                    elif queued:
                                        pair = pending.pop(key, None) or delivered.pop(key, None)
                                        if pair:
                                            stamp = pair[0]
                                            if pair[1]:
                                                native_id = pair[1] if str(pair[1]).startswith("claude:") else "claude:" + str(pair[1])
                                    if queued:
                                        marker = marker or "human"
                                elif tool == "codex":
                                    item = payload.get("item", {})
                                    item = item if isinstance(item, dict) else {}
                                    if kind == "event_msg" and payload.get("type") == "item_completed" and item.get("type") == "UserMessage":
                                        body = text_content(item.get("content"))
                                        thread = payload.get("thread_id", meta.get("id", path.stem))
                                        turn = payload.get("turn_id", str(stamp))
                                        if item.get("id"):
                                            native_id = "codex:" + str(thread) + ":" + str(turn) + ":" + str(item["id"])
                                    elif kind == "event_msg" and payload.get("type") == "user_message":
                                        body = text_content(payload.get("message"))
                                    elif kind == "response_item" and payload.get("role") == "user":
                                        body = text_content(payload.get("content"))
                                    else:
                                        continue
                                    marker = combined_marker(meta, line, payload, item)
                                    if str(payload.get("turn_id", "")).startswith("external-import-turn-"):
                                        marker = "imported"
                                if not body.strip():
                                    continue
                                native_identity = native_id is not None
                                native_id = native_id or tool + ":legacy:" + str(stamp) + ":" + digest(body.strip())
                                origin = str(meta.get("originator", line.get("entrypoint", "")))
                                candidates.append(Instruction(tool, session, digest(origin) if origin else "", stamp, digest(path.stem),
                                                              digest(native_id), digest(body), len(body), shingles(body),
                                                              marker, queued=queued, native_identity=native_identity))
                    except (OSError, UnicodeError):
                        diagnostics["unreadable_log_files"] += 1
                        diagnostics[tool + "_unreadable_log_files"] += 1
    candidates.finalize()
    return candidates, outgoing, received


def infer_apps(candidates, keys):
    by_session = defaultdict(Counter)
    origin_sessions = defaultdict(list)
    for c in candidates:
        if c.marker in ("agent", "non_instruction", "imported") or c.queued:
            continue
        apps = set().union(*(keys.get(c.ts + offset, set()) for offset in (-1, 0, 1)))
        for app in apps:
            by_session[c.session][app] += 1
    for session, counts in by_session.items():
        app, count = counts.most_common(1)[0]
        if count >= 2 and count / sum(counts.values()) >= .8:
            origin = next((c.origin for c in candidates if c.session == session), "")
            tool = next(c.tool for c in candidates if c.session == session)
            origin_sessions[(tool, origin)].append(app)
    inferred = {}
    for session, counts in by_session.items():
        app, count = counts.most_common(1)[0]
        if count >= 2 and count / sum(counts.values()) >= .8:
            inferred[session] = app
    for c in candidates:
        if c.session in inferred:
            c.app = inferred[c.session]
        else:
            counts = Counter(origin_sessions[(c.tool, c.origin)]) if c.origin else Counter()
            if counts:
                app, count = counts.most_common(1)[0]
                if sum(counts.values()) >= 5 and count / sum(counts.values()) >= .8:
                    c.app = app


def classify(candidates, outgoing, received, keys):
    if isinstance(candidates, DiskCandidates):
        return classify_disk(candidates, outgoing, received, keys)
    infer_apps(candidates, keys)
    # Hash index avoids comparing every instruction to every outbound call.
    index = defaultdict(list)
    for number, (stamp, session, pieces) in enumerate(outgoing):
        for piece in pieces:
            index[piece].append(number)
    for c in candidates:
        if c.marker:
            c.sender = c.marker
            continue
        sources = [(c.ts, c.pieces)] + received[c.session]
        provenance = False
        for stamp, pieces in sources:
            if not pieces:
                continue
            matches = Counter(number for piece in pieces for number in index.get(piece, ())
                              if outgoing[number][0] <= stamp and outgoing[number][1] != c.session)
            if any(count / len(pieces) >= .5 for count in matches.values()):
                provenance = True
                break
        if provenance:
            c.sender = "agent"
        elif c.app and any(c.app in keys.get(c.ts + offset, ()) for offset in (-1, 0, 1)):
            c.sender = "human"


def measure(check, metric, day, numerator=None, denominator=None, tool=None, reason=None, lower=False):
    return {"check": check, "metric": metric, "day": day, "tool": tool,
            "numerator": numerator, "denominator": denominator,
            "ratio": numerator / denominator if denominator and numerator is not None else None,
            "lower_is_better": lower, "reason": reason or ("empty denominator" if not denominator else None)}


class Timeline:
    """One predecessor plus streamed in-range transitions, with constant state."""
    def __init__(self, db, table, start, end):
        self.db, self.table = db, table
        self.order = 'since,rowid'
        self.current = next(bounded_rows(db, table, 'since<?', (start,),
                                        suffix='ORDER BY since DESC,rowid DESC LIMIT 1'), None)
        self.rows = iter(bounded_rows(db, table, 'since>=? AND since<?', (start, end),
                                      suffix='ORDER BY ' + self.order))
        self.pending = next(self.rows, None)
        self.last = float('-inf')

    def at(self, stamp):
        if stamp < self.last:
            # C12 frames need not arrive in time order. One indexed predecessor
            # query avoids keeping lifetime history for random lookups.
            return next(bounded_rows(self.db, self.table, 'since<=?', (stamp,),
                                     suffix='ORDER BY since DESC,rowid DESC LIMIT 1'), None)
        self.last = stamp
        while self.pending is not None and self.pending['since'] <= stamp:
            self.current, self.pending = self.pending, next(self.rows, None)
        return self.current


def gap_checks(schema, start, end, day_of, failures, days=None):
    needed = [("log_recording_history", ("since", "enabled", "paused_until")),
              ("awake_history", ("since", "awake")), ("exclusion_history", ("since", "excluded"))]
    if not all(schema.has(t, *cols) for t, cols in needed):
        return [], "channel absent: recording, awake and exclusion histories required"
    histories = [Timeline(schema.db, t, start, end) for t, _ in needed]
    counts = defaultdict(lambda: [0, 0, 0])
    for minute in range((start + 59) // 60 * 60, end - 59, 60):
        if days is not None and day_of(minute) not in days:
            continue
        states = [[h.at(ts) for h in histories] for ts in range(minute, minute + 60)]
        if any(any(r is None for r in state) for state in states):
            counts[day_of(minute)][2] += 1
            continue
        eligible = all(rec["enabled"] and (rec["paused_until"] is None or rec["paused_until"] <= ts)
                       and awake["awake"] and not excluded["excluded"]
                       for ts, (rec, awake, excluded) in zip(range(minute, minute + 60), states))
        if eligible:
            counts[day_of(minute)][1] += 1
            if not schema.db.execute('SELECT 1 FROM samples WHERE ts>=? AND ts<? LIMIT 1',
                                     (minute, minute + 60)).fetchone():
                counts[day_of(minute)][0] += 1
                failures["unexplained_gap_minutes"] += 1
    return counts, None


def git_history(path):
    command = ["git", "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false", "-C", str(path),
               "log", "--all", "--no-show-signature", "--no-notes", "--format=%H%x09%ct"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    deadline, pending = time.monotonic() + 60, b""
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise subprocess.TimeoutExpired(command, 60)
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            pending += chunk
            while b"\n" in pending:
                line, _, pending = pending.partition(b"\n")
                commit, stamp = line.decode("ascii").split("\t")
                yield commit, int(stamp)
            if len(pending) > 1024:
                raise ValueError()
        if pending or process.wait(timeout=max(.01, deadline - time.monotonic())):
            raise ValueError()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()


def git_checks(schema, start, end, day_of, days, failures):
    repos = schema.find("git_repositories", "git_repos")
    commits = schema.find("git_commits")
    reason = None
    if repos is None or commits is None:
        reason = "channel absent"
    else:
        path_col = schema.column(repos, "path", "root_path", "repository_path")
        repo_col = schema.column(commits, "repository_id", "repo_id")
        hash_col = schema.column(commits, "commit_hash", "oid", "sha", "hash")
        if not path_col or not repo_col or not hash_col or not schema.has(repos, "id"):
            reason = "unsupported schema: Git identity columns required"
    if reason:
        return [measure("C4", "commits_recorded", day, reason=reason) for day in days]
    counts = defaultdict(lambda: [0, 0])
    unavailable = 0
    for repo in bounded_rows(schema.db, repos):
        try:
            # git log traverses a commit once even when several refs reach it.
            for commit, stamp in git_history(repo[path_col]):
                if not start <= stamp < end or day_of(stamp) not in days:
                    continue
                count = counts[day_of(stamp)]
                count[1] += 1
                stored = schema.db.execute('SELECT 1 FROM "' + commits + '" WHERE "' + repo_col +
                                           '"=? AND "' + hash_col + '"=? LIMIT 1', (repo["id"], commit)).fetchone()
                if stored:
                    count[0] += 1
                else:
                    failures["missing_git_commits"] += 1
        except (OSError, subprocess.SubprocessError, ValueError):
            unavailable += 1
    if unavailable:
        failures["unreadable_git_repositories"] += unavailable
    return [dict(measure("C4", "commits_recorded", day, *counts[day],
                         reason="partial: repositories unreadable" if unavailable else None),
                 repositories_unreadable=unavailable) for day in days]


def screen_checks(schema, start, end, day_of, days, failures):
    captures = schema.find("screen_captures", "screen_acquisitions")
    occurrences = schema.find("screen_occurrences", "screen_capture_occurrences")
    counters = schema.find("screen_capture_counters", "screen_capture_stats")
    counts = defaultdict(lambda: [0, 0, 0, 0])
    acquisition_rows = bool(captures and occurrences and schema.has(captures, "id", "ts") and schema.has(occurrences, "capture_id"))
    if acquisition_rows:
        for raw in schema.db.execute('SELECT ' + bounded_columns(['id', 'ts']) + ',EXISTS(SELECT 1 FROM "' + occurrences +
                                         '" o WHERE o.capture_id=c.id) AS kept FROM "' + captures +
                                         '" c WHERE ts>=? AND ts<?', (start, end)):
            capture = bounded_row(raw, ['id', 'ts'])
            capture['kept'] = raw['kept']
            if day_of(capture["ts"]) not in days:
                continue
            counts[day_of(capture["ts"])][1] += 1
            counts[day_of(capture["ts"])][0] += capture["kept"]
        reason = None
    elif counters and schema.has(counters, "ts", "acquired", "stored", "dropped_captures", "admission_losses"):
        for row in bounded_rows(schema.db, counters, 'ts>=? AND ts<?', (start, end)):
            if day_of(row["ts"]) not in days:
                continue
            count = counts[day_of(row["ts"])]
            for i, name in enumerate(("stored", "acquired", "dropped_captures", "admission_losses")):
                count[i] += row[name]
        reason = None
    else:
        reason = "channel absent" if not (captures or occurrences or counters) else "unsupported schema: screen acquisition counters required"
    # Counter rows are deltas, not cumulative gauges. Do not add losses to acquired again.
    if acquisition_rows and counters and schema.has(counters, "ts", "dropped_captures", "admission_losses"):
        has_acquired = schema.has(counters, "acquired")
        if has_acquired:
            for day in days:
                counts[day][1] = 0
        for row in bounded_rows(schema.db, counters, 'ts>=? AND ts<?', (start, end)):
            if day_of(row["ts"]) not in days:
                continue
            if has_acquired:
                counts[day_of(row["ts"])][1] += row["acquired"]
            counts[day_of(row["ts"])][2] += row["dropped_captures"]
            counts[day_of(row["ts"])][3] += row["admission_losses"]
    output = []
    for day in days:
        kept, acquired, dropped, admission = counts[day]
        if not reason:
            failures["screen_captures_not_kept"] += max(0, acquired - kept)
            failures["screen_dropped_captures"] += dropped
            failures["screen_admission_losses"] += admission
        row = measure("C5", "captures_kept", day, kept if not reason else None,
                      acquired if not reason else None, reason=reason)
        row.update(dropped_captures=dropped, admission_losses=admission,
                   counters_available=bool(counters),
                   denominator_basis="acquisition_counters" if counters and schema.has(counters, "acquired") else "acquisition_rows")
        if not reason and (kept > acquired or min(kept, acquired, dropped, admission) < 0):
            row["reason"] = "inconsistent screen counters"
        output.append(row)
    return output


def product_helper():
    global _product_mask
    if _product_mask is None:
        _product_mask = ProductMask()
    return _product_mask


@lru_cache(maxsize=256)
def small_web_key(value):
    return product_helper().document_key(value)


def url_digest(value):
    """Full URLs use the product function; stored keys are already native identities."""
    value = str(value or '')
    if not value or len(value) > MAX_TEXT_FIELD:
        return None
    if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*://', value):
        scheme = value.split('://', 1)[0].lower()
        if scheme not in ('http', 'https'):
            return None
        key = small_web_key(value) if len(value) <= 4096 else product_helper().document_key(value)
        return stored_web_digest(key) if key else None
    authority = value.partition('/')[0]
    if not authority or re.search(r'[\s?#]', authority):
        return None
    # Recorder keys have decoded paths, including literal ?, # and % characters.
    return stored_web_digest(value)


def stored_web_digest(value):
    host, separator, path = value.partition('/')
    return digest(host.lower() + ('/' + path.rstrip('/') if separator and path.rstrip('/') else ''))


def document_path(value):
    try:
        if value.startswith("file:"):
            url = urlsplit(value)
            if url.netloc not in ("", "localhost"):
                return None
            value = unquote(url.path)
        path = Path(value)
        return path if path.is_absolute() else None
    except (ValueError, OSError):
        return None


def near(stamps, stamp, tolerance):
    index = bisect_right(stamps, stamp + tolerance)
    return index > 0 and within_time(stamps[index - 1], stamp, tolerance)


def chrome_checks(references, samples, start, end, day_of, days, failures, diagnostics):
    with workspace() as work:
        return chrome_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work)


def chrome_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work):
    attribution = TimeIndex(work, 'chrome_attribution')
    limits = InputLimits(day_of, days)
    for row in samples:
        key = url_digest(row["document_key"])
        if key:
            attribution.add(key, row['ts'])
    counts = defaultdict(lambda: [0, 0])
    seen = set()
    unavailable = 0
    for history in references.chrome_histories:
        identity = Path(history).absolute()
        if identity in seen:
            continue
        seen.add(identity)
        try:
            with chrome_snapshot(history) as chrome:
                schema = Schema(chrome)
                if not schema.has("visits", "url", "visit_time") or not schema.has("urls", "id", "url"):
                    unavailable += 1
                    continue
                # Chrome uses microseconds since 1601; retain fractional seconds.
                projection = bounded_columns({'url': 'urls.url', 'visit_time': 'visits.visit_time'})
                rows = chrome.execute(f"""SELECT {projection} FROM visits
                    JOIN urls ON urls.id=visits.url WHERE visits.visit_time>=? AND visits.visit_time<?""",
                    ((start + 11644473600) * 1000000, (end + 11644473600) * 1000000))
                for row in rows:
                    row = bounded_row(row, ['url', 'visit_time'])
                    stamp = (row["visit_time"] - 11644473600 * 1000000) / 1000000
                    if day_of(stamp) not in days:
                        continue
                    counts[day_of(stamp)][1] += 1
                    limits.audit('chrome', [dict(row, ts=stamp)])
                    key = url_digest(row["url"])
                    found = bool(key and attribution.near(key, stamp, references.tolerance))
                    counts[day_of(stamp)][0] += found
                    if not key:
                        diagnostics["chrome_visits_without_http_url"] += 1
                    if not found:
                        failures["chrome_visits_without_document_attribution"] += 1
        except (OSError, sqlite3.Error, ValueError, TypeError):
            unavailable += 1
    if unavailable:
        diagnostics["unreadable_chrome_histories"] += unavailable
    reason = ("channel absent: Chrome history input not supplied" if not references.chrome_histories else
              "partial: Chrome histories unreadable or unsupported" if unavailable else None)
    output = [dict(measure("C6", "chrome_visits_attributed", day,
                         counts[day][0] if references.chrome_histories else None,
                         counts[day][1] if references.chrome_histories else None, reason=reason),
                 tolerance_seconds=references.tolerance, histories_unreadable=unavailable, histories_readable=len(seen) - unavailable) for day in days]
    for row in output:
        limits.apply(row, ['chrome'])
    return output


FILE_EXCLUDED_DIRS = frozenset((".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".codex", ".claude", "Keychains"))


class KnownFiles:
    """Discover roots and stat surviving files once, independently of daily attribution."""
    def __init__(self, work, samples, start, end, day_of, days, diagnostics):
        self.work, self.errors = work, 0
        work.executescript("""CREATE TABLE file_roots(path TEXT PRIMARY KEY);
            CREATE TABLE compact_roots(path TEXT PRIMARY KEY);
            CREATE TABLE file_mtimes(day TEXT,identity TEXT,ts REAL);
            CREATE INDEX file_mtime_day ON file_mtimes(day);""")
        for row in samples:
            path = document_path(row["document_key"])
            if path is None:
                continue
            try:
                # Reject excluded roots and symlink ancestors as well as descendants.
                if any(p.name in FILE_EXCLUDED_DIRS or p.is_symlink() for p in (path, *path.parents)):
                    continue
                exists = path.exists()
                if not exists:
                    diagnostics["known_document_paths_unavailable"] += 1
                parent = path if path.is_dir() else path.parent
                if not parent.is_dir():
                    continue
                root = next((p for p in (parent, *parent.parents) if (p / ".git").exists()), parent)
                work.execute("INSERT OR IGNORE INTO file_roots VALUES(?)", (str(root),))
            except OSError:
                diagnostics["known_document_paths_unavailable"] += 1
        for (value,) in work.execute(f"SELECT path FROM file_roots ORDER BY {guarded_text('length', 'path')},path"):
            root = Path(value)
            if not any(work.execute("SELECT 1 FROM compact_roots WHERE path=?", (str(p),)).fetchone()
                       for p in (root, *root.parents)):
                work.execute("INSERT INTO compact_roots VALUES(?)", (value,))
        self.root_count = work.execute("SELECT count(*) FROM compact_roots").fetchone()[0]
        def walk_error(_):
            self.errors += 1
        # Metadata only. Paths live solely in the private, disposable SQLite store.
        for (value,) in work.execute("SELECT path FROM compact_roots ORDER BY path"):
            for folder, directories, files in os.walk(value, followlinks=False, onerror=walk_error):
                directories[:] = [d for d in directories if d not in FILE_EXCLUDED_DIRS and not (Path(folder) / d).is_symlink()]
                for name in files:
                    if name in FILE_EXCLUDED_DIRS:
                        continue
                    path = Path(folder) / name
                    try:
                        if path.is_symlink() or not path.is_file():
                            continue
                        stamp = path.stat().st_mtime
                        if start <= stamp < end and day_of(stamp) in days:
                            work.execute("INSERT INTO file_mtimes VALUES(?,?,?)", (day_of(stamp), digest(str(path)), stamp))
                    except OSError:
                        self.errors += 1
        diagnostics["file_metadata_errors"] += self.errors


def file_checks(samples, day_of, days, references, failures, population):
    attribution = TimeIndex(population.work, 'file_attribution')
    for row in samples:
        path = document_path(row["document_key"])
        if path is not None:
            attribution.add(digest(str(path)), row['ts'])
    output = []
    reason = ("no known filesystem roots" if not population.root_count else
              "partial: file metadata unavailable" if population.errors else None)
    for day in days:
        matched = total = 0
        for identity, stamp in population.work.execute("SELECT identity,ts FROM file_mtimes WHERE day=?", (day,)):
            total += 1
            found = attribution.near(identity, stamp, references.tolerance)
            matched += found
            if not found:
                failures["latest_file_mtimes_without_document_attribution"] += 1
        output.append(dict(measure("C7", "latest_file_mtimes_attributed", day, matched, total, reason=reason),
                           tolerance_seconds=references.tolerance, known_roots=population.root_count,
                           latest_mtime_only=True, metadata_errors=population.errors))
    return output


MAX_HISTORY_LINE = 64 * 1024


def shell_lines(stream):
    return bounded_records(stream, MAX_HISTORY_LINE)


def shell_checks(references, samples, start, end, day_of, days, failures, diagnostics):
    with workspace() as work:
        return shell_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work)


def shell_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work):
    terminals = TERMINAL_BUNDLES | set(references.terminal_apps)
    key_times = TimeIndex(work, 'shell_attribution')
    for r in samples:
        if r['keys'] > 0 and (r['bundle_id'] in terminals or r['app'] in terminals or r.get('app_type') == 'terminal'):
            key_times.add('', r['ts'])
    counts = defaultdict(lambda: [0, 0])
    seen, unavailable, untimed, timed, oversized = set(), 0, 0, 0, 0
    oversized_days, unplaced, outside = Counter(), 0, 0
    def skipped(stamp):
        nonlocal oversized, unplaced, outside
        oversized += 1
        if stamp is None:
            unplaced += 1
        elif start <= stamp < end and day_of(stamp) in days:
            oversized_days[day_of(stamp)] += 1
        else:
            outside += 1
    for history in references.shell_histories:
        path = Path(history).absolute()
        if path in seen:
            continue
        seen.add(path)
        try:
            with path.open("rb") as stream:
                bash_stamp = None
                record_stamp = None
                continuation = continuation_oversized = False
                for line, too_large, continues, nonempty in shell_lines(stream):
                    # Commands are intentionally never retained, hashed or printed.
                    if continuation:
                        if too_large and not continuation_oversized:
                            skipped(record_stamp)
                        continuation_oversized = continuation_oversized or too_large
                        continuation = continues
                        continue
                    continuation_oversized = too_large
                    if too_large:
                        prefix_time = re.match(rb'^: (\d{1,12}):\d{1,12};', line)
                        record_stamp = int(prefix_time[1]) if prefix_time else bash_stamp
                        skipped(record_stamp)
                        bash_stamp = None
                        continuation = continues
                        continue
                    match = re.match(rb"^: (\d{1,12}):\d{1,12};", line)
                    if match:
                        stamp = int(match[1])
                        continuation = continues
                    elif re.fullmatch(rb"#\d{1,12}\s*", line):
                        bash_stamp = int(line[1:].strip())
                        continue
                    elif bash_stamp is not None:
                        stamp, bash_stamp = bash_stamp, None
                    else:
                        if nonempty:
                            untimed += 1
                        continue
                    timed += 1
                    record_stamp = stamp
                    if start <= stamp < end and day_of(stamp) in days:
                        count = counts[day_of(stamp)]
                        count[1] += 1
                        found = key_times.near('', stamp, references.tolerance)
                        count[0] += found
                        if not found:
                            failures["shell_commands_without_terminal_keys"] += 1
        except OSError:
            unavailable += 1
    diagnostics["untimed_shell_history_lines"] += untimed
    diagnostics["unreadable_shell_histories"] += unavailable
    diagnostics["oversized_shell_history_records"] += oversized
    partial = bool(unavailable or oversized)
    reason = ("channel absent: shell history input not supplied" if not references.shell_histories else
              "partial: shell histories oversized or unreadable" if partial else
              "history not timestamped" if untimed and not timed else None)
    measurable = bool(references.shell_histories and (timed or not (untimed or partial)))
    output = [dict(measure("C8", "timestamped_shell_commands_with_keys", day,
                         counts[day][0] if measurable else None,
                         counts[day][1] if measurable else None, reason=reason),
                 tolerance_seconds=references.tolerance, untimed_lines=untimed,
                 histories_unreadable=unavailable, oversized_records=oversized,
                 oversized_records_in_day=oversized_days[day], oversized_records_unplaced=unplaced,
                 oversized_records_outside_range=outside,
                 partial_input=bool(unavailable or unplaced or oversized_days[day])) for day in days]
    return output


class ProductMask:
    """Run the current product source, rather than duplicating its secret formats."""
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fidelity-mask-")
        root = Path(self.temp.name)
        source = root / "main.swift"
        product_root = Path(__file__).resolve().parents[1] / 'Sources/Core'
        recorder = (product_root / 'Recorder.swift').read_text()
        # Compile the exact current product method, with only its input shape
        # supplied here. No independently maintained URL canonicalization.
        method = recorder[recorder.index('  public static func documentKey('):
                          recorder.index('  public static func sample(', recorder.index('  public static func documentKey('))]
        source.write_text('''import Foundation
public struct FrontObservation {
  var document: String?
  var browserAddress: String?
  var isBrowser: Bool = true
}
public enum RecorderPolicy {
''' + method + '''}
struct Request: Decodable { let operation: String; let value: String }
while let line = readLine() {
  autoreleasepool {
    guard let data = line.data(using: .utf8),
          let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(2) }
    let value: String
    if request.operation == "document" {
      if let host = URL(string: request.value)?.host, !host.isEmpty {
        value = RecorderPolicy.documentKey(FrontObservation(document: nil, browserAddress: request.value))
      } else { value = "" }
    } else {
      value = Redaction.apply(request.value).text
    }
    guard let result = try? JSONEncoder().encode(value) else { exit(2) }
    print(String(decoding: result, as: UTF8.self))
    fflush(stdout)
  }
}
''')
        binary = root / "mask"
        product = Path(__file__).resolve().parents[1] / "Sources/Core/Redaction.swift"
        try:
            subprocess.run(["swiftc", "-j", "1", "-module-cache-path", str(root / "cache"),
                            str(product), str(source), "-o", str(binary)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
            self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, text=True)
        except BaseException:
            self.temp.cleanup()
            raise

    def request(self, operation, value):
        if len(value) > MAX_RECORD:
            raise ValueError()
        self.process.stdin.write(json.dumps(dict(operation=operation, value=value)) + "\n")
        self.process.stdin.flush()
        encoded = self.process.stdout.readline(12 * MAX_RECORD + 1)
        if len(encoded) > 12 * MAX_RECORD or not encoded.endswith('\n'):
            raise ValueError()
        return json.loads(encoded)

    def apply(self, value):
        return self.request('mask', value)

    def document_key(self, value):
        return self.request('document', value)

    def close(self):
        if getattr(self, "closed", False):
            return
        self.closed = True
        try:
            try:
                self.process.stdin.close()
            except OSError:
                pass  # A dead child can fail while close flushes buffered input.
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        finally:
            try:
                self.process.stdout.close()
            finally:
                self.temp.cleanup()


_product_mask = None


def close_mask():
    global _product_mask
    helper = _product_mask
    if helper is not None:
        try:
            helper.close()
        except OSError:
            pass
        finally:
            _product_mask = None
            small_web_key.cache_clear()


atexit.register(close_mask)


def mask(value):
    value = product_helper().apply(str(value))
    value = re.sub(r"(?i)(?:password|passwd|passphrase|passcode|secret(?:[_ -]key)?|api[_ -]?key|token|cookie)[\"']?\s*[:=：]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)",
                   "[secret]", value)
    # Export also hides complete authorization payloads, including Basic schemes.
    return re.sub(r"(?i)\b(?:authorization\s*[:=]\s*(?:basic|bearer)\s+|bearer\s+)[^\s\"']+",
                  "[secret]", value)


def masked_tree(value):
    if isinstance(value, str):
        if value.lstrip().startswith(("{", "[")):
            try:
                structured = json.loads(value)
                if isinstance(structured, (dict, list)):
                    return masked_tree(structured)
            except ValueError:
                pass
        return mask(value)
    if isinstance(value, bytes):
        return {"blob_length": len(value), "blob_digest": hashlib.sha256(value).hexdigest()}
    if isinstance(value, dict):
        return {mask(k): "[redacted]" if re.search(r"(?i)(?:password|passwd|passphrase|passcode|token|secret|api[_-]?key|authorization|cookie)", str(k))
                else masked_tree(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [masked_tree(v) for v in value]
    return value


def informative_terms(value, stats=None):
    normalized = unicodedata.normalize("NFKC", mask(value)).casefold().replace("[redacted]", " ").replace("[secret]", " ").replace("[email]", " ")
    words = set()
    for match in re.finditer(r"[^\W\d_]+", normalized):
        word = match.group()
        if len(word) < (2 if all("가" <= c <= "힣" for c in word) else 3) or word in words:
            continue
        if len(words) >= MAX_TERMS:
            if stats is not None:
                stats['unsupported_term_occurrences'] += 1
            continue
        words.add(word)
        if stats is not None and len(word) > MAX_TERM:
            stats['exact_only_terms'] += 1
    return words


def edit_one(a, b):
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = j = differences = 0
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            i, j = i + 1, j + 1
        else:
            differences += 1
            if differences > 1:
                return False
            if len(a) == len(b):
                i += 1
            j += 1
    return differences + (j < len(b) or i < len(a)) <= 1


def recalled_terms(reference, ours):
    index = defaultdict(set)
    for word in ours:
        if 4 <= len(word) <= MAX_TERM:
            index[word].add(word)
            for i in range(len(word)):
                index[word[:i] + word[i + 1:]].add(word)
    found = set()
    for word in reference:
        if word in ours:
            found.add(word)
        elif 5 <= len(word) <= MAX_TERM:
            options = set(index[word])
            for i in range(len(word)):
                shorter = word[:i] + word[i + 1:]
                options.update(index[shorter])
                if shorter in ours:
                    options.add(shorter)
            if any(edit_one(word, candidate) for candidate in options):
                found.add(word)
    return found


def term_identities(words):
    # Position-aware deletion digests permit edit distance one without storing
    # normalized text in the temporary index. Positions reject transpositions.
    return {digest(word): [len(word), [digest(word[:i] + word[i + 1:]) for i in range(len(word))]
                          if len(word) <= MAX_TERM else []]
            for word in words}


def intern_terms(db, words):
    identities, numbers = set(), []
    for word in sorted(words):
        identity = digest(word)
        identities.add(identity)
        row = db.execute("SELECT id FROM lexicon WHERE identity=?", (identity,)).fetchone()
        if row is None:
            signature = term_identities({word})[identity]
            number = db.execute("INSERT INTO lexicon(identity,signature) VALUES(?,?)",
                                (identity, json.dumps(signature))).lastrowid
        else:
            number = row[0]
        numbers.append(number)
    return json.dumps(numbers), identities


def load_identities(db, encoded):
    result = {}
    numbers = json.loads(encoded)
    for offset in range(0, len(numbers), 256):
        batch = numbers[offset:offset + 256]
        for row in db.execute("SELECT identity,signature FROM lexicon WHERE id IN (" + ",".join("?" for _ in batch) + ")", batch):
            result[row[0]] = json.loads(row[1])
    return result


def recalled_identities(reference, ours):
    substitutions, deletions = set(), set()
    by_length = defaultdict(set)
    for identity, (length, drops) in ours.items():
        by_length[length].add(identity)
        if length >= 4:
            substitutions.update((length, position, value) for position, value in enumerate(drops))
            deletions.update((length - 1, value) for value in drops)
    found = set(reference.keys() & ours.keys())
    for identity, (length, drops) in reference.items():
        if length >= 5 and ((length, identity) in deletions or
                any(value in by_length[length - 1] or (length, position, value) in substitutions
                    for position, value in enumerate(drops))):
            found.add(identity)
    return found


def normalized(value):
    return unicodedata.normalize("NFKC", str(value or "")).strip().casefold()


def same_document(a, b):
    if not a or not b:
        return False
    first, second = url_digest(a), url_digest(b)
    return first == second if first and second else normalized(a) == normalized(b)


@contextmanager
def readonly(database):
    db = sqlite3.connect(Path(database).absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA busy_timeout=250")
        db.execute("PRAGMA cache_size=-2048")
        db.execute("PRAGMA temp_store=FILE")
        db.execute("SELECT name FROM sqlite_master LIMIT 1").fetchone()
        yield db
    finally:
        db.close()


@contextmanager
def reference_snapshot(path):
    # The reference can be much larger than the selected period. Never back it up.
    for attempt in range(3):
        try:
            manager = readonly(path)
            db = manager.__enter__()
        except (sqlite3.Error, OSError):
            if attempt == 2:
                raise
            time.sleep(.05 * (attempt + 1))
        else:
            try:
                yield db
            finally:
                manager.__exit__(None, None, None)
            return


@contextmanager
def chrome_snapshot(path):
    try:
        manager = snapshot(path, deadline_seconds=1)
        db = manager.__enter__()
    except (sqlite3.Error, OSError, TimeoutError):
        # Some browser profiles deny SQLite's backup connection while open.
        with tempfile.TemporaryDirectory(prefix="fidelity-chrome-") as folder:
            target = Path(folder) / "History"
            for suffix in ("", "-wal", "-journal"):
                source = Path(str(path) + suffix)
                if suffix and not source.exists():
                    continue
                shutil.copyfile(source, Path(str(target) + suffix))
            # WAL recovery can write only to this disposable private copy.
            copied = sqlite3.connect(target)
            try:
                copied.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
            finally:
                copied.close()
            with readonly(target) as copied:
                if copied.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise sqlite3.DatabaseError()
                yield copied
    else:
        try:
            yield db
        finally:
            manager.__exit__(None, None, None)


def reference_time(value):
    try:
        stamp = float(value)
        return stamp if math.isfinite(stamp) else None
    except (ValueError, TypeError):
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            return parsed.timestamp() if parsed.tzinfo is not None else None
        except ValueError:
            return None


def timestamp_index(db, table, column, work):
    name = 'bounded_time_' + digest(str(id(db)) + ':' + table + ':' + column)[:16]
    if not work.execute("SELECT 1 FROM sqlite_master WHERE name=?", (name,)).fetchone():
        work.execute('CREATE TABLE ' + quoted(name) + '(record INTEGER PRIMARY KEY,ts REAL)')
        for row in bounded_rows(db, table, columns=['rowid', column], scan=True):
            stamp = reference_time(row[column])
            if stamp is not None:
                work.execute('INSERT INTO ' + quoted(name) + ' VALUES(?,?)', (row['rowid'], stamp))
        work.execute('CREATE INDEX ' + quoted(name + '_ts') + ' ON ' + quoted(name) + '(ts)')
    return quoted(name)


def time_rows(db, table, columns, column, start, end, work=None):
    """Bound both supported timestamp encodings before retrieving any text."""
    names = sorted(Schema(db).columns(table)) if columns == '*' else columns
    sizes = real_text_sizes(db, table)
    query = 'SELECT ' + bounded_columns(names, sizes) + ' FROM ' + quoted(table) + ' NOT INDEXED WHERE '
    if work is not None:
        # Source timestamp indices can materialize oversized keys while seeking.
        # Build a bounded numeric index once, then retrieve source rows by rowid.
        index = timestamp_index(db, table, column, work)
        for (record,) in work.execute('SELECT record FROM ' + index + ' WHERE ts>=? AND ts<? ORDER BY record', (start, end)):
            raw = db.execute(query + 'rowid=?', (record,)).fetchone()
            if raw is not None:
                yield bounded_row(raw, names)
        return
    condition = quoted(column) + '>=? AND ' + quoted(column) + '<?'
    # A one-off cursor scans guarded values. Repeated analysis cursors use the
    # private numeric index above, never a source index with unbounded text keys.
    lo = datetime.fromtimestamp(start - 14 * 3600, timezone.utc).date().isoformat()
    hi = (datetime.fromtimestamp(end + 14 * 3600, timezone.utc).date() + timedelta(days=1)).isoformat()
    for low, high, iso in ((start, end, False), (lo, hi, True)):
        where = condition
        parameters = (low, high)
        if iso:
            instant = guarded_text('julianday', quoted(column))
            where += f" AND {instant}>=julianday(?,'unixepoch') AND {instant}<julianday(?,'unixepoch')"
            parameters += (start, end)
        where = f'CASE WHEN octet_length({quoted(column)})<={MAX_TEXT_FIELD} THEN ({where}) END'
        for row in db.execute(query + bounded_where(where, sizes), parameters):
            row = bounded_row(row, names)
            stamp = reference_time(row[column])
            if stamp is not None and start <= stamp < end:
                yield row


def reference_rows(db, table, start, end, days=None, day_of=None, diagnostics=None, text=True, work=None):
    schema = Schema(db)
    if not schema.has(table, "timestamp"):
        return
    permitted = ("id", "timestamp", "app_name", "window_name", "browser_url", "focused",
                 "text_source", "monitor_id") if table == "frames" else (
                     "id", "timestamp", "event_type", "app_name", "window_title", "element_role", "element_name")
    if text and table == "frames":
        permitted += ("full_text", "accessibility_text")
    columns = [name for name in permitted if name in schema.columns(table)]
    ranges = [(start, end)]
    if days is not None:
        ranges = []
        def boundary(target):
            low, high = int(start), int(end)
            while low < high:
                middle = (low + high) // 2
                if day_of(middle) < target:
                    low = middle + 1
                else:
                    high = middle
            return low
        for day in days:
            next_day = (datetime.fromisoformat(day) + timedelta(days=1)).date().isoformat()
            low, high = boundary(day), boundary(next_day)
            if high > low:
                ranges.append((low, high))
    for low, high in ranges:
        for row in time_rows(db, table, columns, "timestamp", low, high, work):
            item = dict(row)
            stamp = reference_time(item["timestamp"])
            if table != "frames" or item.get("focused") in (1, True, "1"):
                item["ts"] = int(stamp)
                item["timestamp_seconds"] = stamp
                yield item


def frame_text(frame):
    return "\n".join(str(frame.get(name) or "") for name in ("full_text", "accessibility_text"))


class QueryRows:
    def __init__(self, db, table, start, end, condition="1", parameters=()):
        self.db, self.table, self.start, self.end = db, table, start, end
        self.condition, self.parameters = condition, parameters

    def __iter__(self):
        return bounded_rows(self.db, self.table, 'ts>=? AND ts<? AND ' + self.condition,
                            (self.start, self.end, *self.parameters))

    def between(self, start, end):
        return QueryRows(self.db, self.table, start, end, self.condition, self.parameters)


class ReferenceFrames:
    def __init__(self, db, start, end, days, day_of, work):
        self.db, self.start, self.end, self.days, self.day_of = db, start, end, days, day_of
        self.work = work

    def __iter__(self):
        return reference_rows(self.db, "frames", self.start, self.end, self.days, self.day_of, text=False, work=self.work)

    def between(self, start, end):
        return reference_rows(self.db, "frames", start, end, self.days, self.day_of, work=self.work)


def neighborhood(samples, start, end):
    return samples.between(start, end) if isinstance(samples, QueryRows) else (
        r for r in samples if start <= r["ts"] < end)


def tolerance_rows(samples, stamp, tolerance):
    # Query a coarse inclusive neighborhood, then apply the exact predicate.
    return (r for r in neighborhood(samples, math.floor(stamp - tolerance),
                                   math.ceil(stamp + tolerance) + 1)
            if within_time(r['ts'], stamp, tolerance))


class EvidenceApps:
    """Resolve screen sources against the app name observed at evidence time."""
    def __init__(self, db, work, limits):
        self.work = work
        work.execute('CREATE TABLE evidence_apps(source TEXT,ts REAL,app TEXT,PRIMARY KEY(source,ts,app)) WITHOUT ROWID')
        if not Schema(db).has('samples', 'ts', 'app', 'bundle_id'):
            return
        # One bounded lifetime pass; only opaque identities and timestamps spill.
        for row in bounded_rows(db, 'samples', columns=['ts', 'bundle_id', 'app'], scan=True):
            # A predecessor outside the selected days can affect any later day.
            limits.audit('evidence_apps', [dict(row, ts=None)])
            source, app, stamp = normalized(row['bundle_id']), normalized(row['app']), reference_time(row['ts'])
            if not source or stamp is None or 'bundle_id' in row.get('_oversized_fields', ()):
                continue
            work.execute('INSERT OR IGNORE INTO evidence_apps VALUES(?,?,?)',
                         (digest(source), stamp, digest(app) if app else ''))

    def at(self, source, stamp):
        identity = digest(normalized(source))
        # Two rows suffice to detect conflicting names at the latest timestamp.
        # Never use a future observation or pick an arbitrary same-time alias.
        rows = self.work.execute('SELECT ts,app FROM evidence_apps WHERE source=? AND ts<=? ORDER BY ts DESC,app DESC LIMIT 2',
                                 (identity, stamp)).fetchall()
        if not rows or not rows[0][1] or (len(rows) == 2 and rows[0][0] == rows[1][0]):
            return identity  # Unmapped/direct app-name sources retain their own identity.
        return rows[0][1]


def reference_checks(ours, reference, samples, start, end, day_of, days, failures, options, diagnostics=None, work=None, evidence_apps=None):
    absent = "channel absent: reference recorder input not supplied"
    if reference is None:
        return [measure(check, metric, day, reason=absent) for day in days for check, metric in
                (("C9", "reference_frames_attributed"), ("C10", "informative_term_weighted_recall"),
                 ("C10", "informative_term_unweighted_recall"), ("C11", "reference_input_observed"))], [], [], []
    schema, own_schema = Schema(reference), Schema(ours)
    frames = ReferenceFrames(reference, start, end, days, day_of, work)
    frame_channel = schema.has("frames", "timestamp", "focused", "app_name", "window_name")
    input_channel = schema.has("ui_events", "timestamp", "event_type", "app_name")
    own_samples = own_schema.has("samples", "ts", "app", "window", "document_key", "keys", "clicks", "scrolls")
    evidence_available = own_schema.has("evidence", "ts", "kind", "source", "text")
    evidence = QueryRows(ours, "evidence", start - 60, end + 60) if evidence_available else []
    work.executescript("""
        CREATE TABLE lexicon(id INTEGER PRIMARY KEY, identity TEXT UNIQUE, signature TEXT);
        CREATE TABLE terms(day TEXT, app TEXT, ts REAL, words TEXT);
        CREATE TABLE frequency(day TEXT, word TEXT, n INTEGER, PRIMARY KEY(day,word));
        CREATE TABLE screens(app TEXT, ts REAL, words TEXT);
        CREATE INDEX screens_time ON screens(app,ts);
        CREATE TABLE clicks(app TEXT, ts INTEGER, capacity INTEGER, PRIMARY KEY(app,ts));
        CREATE TABLE events(identity TEXT PRIMARY KEY, ts REAL, payload TEXT);
        CREATE TABLE recall(day TEXT,app TEXT,weighted_found REAL,weighted_total REAL,found INTEGER,total INTEGER,
            PRIMARY KEY(day,app));
    """)
    term_limits = defaultdict(Counter)
    affected = InputLimits(day_of, days)
    for row in evidence:
        if row["kind"] == "screen":
            stats = Counter()
            encoded = intern_terms(work, informative_terms(row['text'], stats))[0]
            for day in affected.affected_days(row['ts'], 60):
                term_limits[day].update(stats)
            work.execute("INSERT INTO screens VALUES(?,?,?)", (evidence_apps.at(row["source"], row["ts"]), row["ts"], encoded))
    if own_samples:
        for row in samples:
            work.execute("INSERT INTO clicks VALUES(?,?,?) ON CONFLICT(app,ts) DO UPDATE SET capacity=max(capacity,excluded.capacity)",
                         (digest(normalized(row["app"])), row["ts"], max(0, row["clicks"])))
    attribution, disagreements, inputs = defaultdict(lambda: [0, 0]), defaultdict(Counter), defaultdict(lambda: [0, 0])
    frame_counts = Counter()
    for frame in reference_rows(reference, "frames", start, end, days, day_of, diagnostics, work=work):
        day, app_name = day_of(frame["ts"]), normalized(frame.get("app_name"))
        has_nearby = has_app = found = False
        for r in tolerance_rows(samples, frame['timestamp_seconds'], 1):
            has_nearby = True
            if app_name and normalized(r['app']) == app_name:
                has_app = True
                found |= bool((r['window'] and normalized(r['window']) == normalized(frame.get('window_name')))
                              or same_document(r['document_key'], frame.get('browser_url')))
        attribution[day][1] += 1
        attribution[day][0] += found
        if not found:
            category = "ours_missing" if not has_nearby else "app_differs" if not has_app else "window_or_document_differs"
            disagreements[day][category] += 1
            if own_samples:
                failures["reference_" + category] += 1
        encoded, words = intern_terms(work, informative_terms(frame_text(frame), term_limits[day]))
        frame_counts[day] += 1
        work.execute("INSERT INTO terms VALUES(?,?,?,?)", (day, digest(app_name) if app_name else "", frame["timestamp_seconds"], encoded))
        work.executemany("INSERT INTO frequency VALUES(?,?,1) ON CONFLICT(day,word) DO UPDATE SET n=n+1",
                         ((day, word) for word in words))
    event_names = {"click": "click", "mouse_click": "click", "mouseclick": "click",
                   "window_focus": "window_focus", "windowfocus": "window_focus", "focus": "window_focus",
                   "app_switch": "app_switch", "appswitch": "app_switch", "application_switch": "app_switch"}
    for event in reference_rows(reference, "ui_events", start, end, days, day_of, diagnostics, work=work):
        identity = digest(event["id"]) if event.get("id") is not None else digest(json.dumps(event, sort_keys=True))
        safe = {"ts": event["ts"], "timestamp_seconds": event["timestamp_seconds"],
                "kind": event_names.get(normalized(event.get("event_type")).replace("-", "_")),
                "app_id": digest(normalized(event["app_name"])) if event.get("app_name") else "",
                "window_id": digest(normalized(event["window_title"])) if event.get("window_title") else ""}
        work.execute("INSERT OR IGNORE INTO events VALUES(?,?,?)", (identity, event["timestamp_seconds"], json.dumps(safe)))
    for stored_event in work.execute("SELECT payload FROM events ORDER BY ts,identity"):
        event = json.loads(stored_event[0])
        kind = event["kind"]
        if kind is None:
            if diagnostics is not None:
                diagnostics["reference_unrecognized_input_events"] += 1
            continue
        app, stamp = event["app_id"], event["timestamp_seconds"]
        if kind == "click":
            # Earliest remaining capacity gives a maximum ordered interval match.
            capacity = work.execute("SELECT ts FROM clicks WHERE app=? AND ts>=? AND ts<=? AND capacity>0 ORDER BY ts LIMIT 1",
                                    (app, stamp - 1, stamp + 1)).fetchone() if app else None
            found = capacity is not None and within_time(capacity[0], stamp, 1)
            if found:
                work.execute("UPDATE clicks SET capacity=capacity-1 WHERE app=? AND ts=?", (app, capacity[0]))
        else:
            found = any(app and digest(normalized(r['app'])) == app and
                        (kind == 'app_switch' or not event['window_id'] or
                         digest(normalized(r['window'])) == event['window_id'])
                        for r in tolerance_rows(samples, stamp, 1))
        count = inputs[(day_of(stamp), kind)]
        count[1] += 1
        count[0] += found
        if not found and own_samples:
            failures["reference_" + kind + "_unobserved"] += 1
    for row in work.execute("SELECT day,app,ts,words FROM terms ORDER BY day,app,ts"):
        day, app, stamp, encoded = row
        words, found = load_identities(work, encoded), set()
        if app:
            for screen in work.execute("SELECT words,ts FROM screens WHERE app=? AND ts>=? AND ts<=?", (app, stamp - 60, stamp + 60)):
                if within_time(screen[1], stamp, 60):
                    found.update(recalled_identities(words, load_identities(work, screen[0])))
        count = [0., 0., 0, 0]
        for word in sorted(words):
            frequency = work.execute("SELECT n FROM frequency WHERE day=? AND word=?", (day, word)).fetchone()[0]
            weight = math.log(frame_counts[day] / frequency)
            count[1] += weight
            if word in found:
                count[0] += weight
            elif evidence_available and weight > 0:
                failures["reference_informative_terms_missing"] += 1
        count[2] += len(found)
        count[3] += len(words)
        work.execute('''INSERT INTO recall VALUES(?,?,?,?,?,?) ON CONFLICT(day,app) DO UPDATE SET
            weighted_found=weighted_found+excluded.weighted_found,weighted_total=weighted_total+excluded.weighted_total,
            found=found+excluded.found,total=total+excluded.total''', (day, app or digest(''), *count))
    output = []
    for day in days:
        reason = "channel absent: reference frames" if not frame_channel else "channel absent: samples" if not own_samples else None
        row = measure("C9", "reference_frames_attributed", day, *attribution[day], reason=reason)
        if reason:
            row.update(numerator=None, ratio=None)
        row["disagreements"] = dict(disagreements[day])
        output.append(row)
        groups = work.execute('SELECT count(*) FROM recall WHERE day=?', (day,)).fetchone()[0]
        app_rows = [(row[0], row[1:], 1) for row in work.execute(
            'SELECT app,weighted_found,weighted_total,found,total FROM recall WHERE day=? ORDER BY app LIMIT ?', (day, MAX_APP_GROUPS))]
        if groups > MAX_APP_GROUPS:
            overflow = work.execute('''SELECT sum(weighted_found),sum(weighted_total),sum(found),sum(total) FROM recall
                WHERE day=? AND app NOT IN (SELECT app FROM recall WHERE day=? ORDER BY app LIMIT ?)''',
                (day, day, MAX_APP_GROUPS)).fetchone()
            app_rows.append((digest('aggregated app groups'), overflow, groups - MAX_APP_GROUPS))
        if not app_rows:
            app_rows = [(None, [0., 0., 0, 0], 0)]
        for app_id, count, combined in app_rows:
            reason = ("channel absent: reference screen text" if not frame_channel or not (
                schema.has("frames", "full_text") or schema.has("frames", "accessibility_text")) else
                "channel absent: screen evidence" if not own_schema.has("evidence", "ts", "kind", "source", "text") else None)
            for metric, values in (("informative_term_weighted_recall", count[:2]), ("informative_term_unweighted_recall", count[2:])):
                row = measure("C10", metric, day, *values, reason=reason)
                row.update(app_id=app_id, tolerance_seconds=60, weighting="log_inverse_frame_frequency")
                row.update(app_group_count=combined)
                row.update(term_limits[day])
                if term_limits[day]:
                    note = 'partial: exact-only or unsupported terms'
                    row.update(partial_input=True, reason=reason + '; ' + note if reason else note)
                if reason:
                    row.update(numerator=None, ratio=None)
                output.append(row)
        for kind in ("click", "window_focus", "app_switch"):
            reason = "channel absent: reference input events" if not input_channel else "channel absent: samples" if not own_samples else None
            row = measure("C11", "reference_input_observed", day, *inputs[(day, kind)], reason=reason)
            if reason:
                row.update(numerator=None, ratio=None)
            row["event_kind"] = kind
            output.append(row)
    return output, frames, evidence, samples


def rows_in_window(db, table, start, end, export_limits=None):
    schema = Schema(db)
    column = schema.column(table, "ts", "timestamp", "committed_ts", "commit_ts", "committer_ts", "event_ts", "committed_at")
    if column is None:
        return [], "channel absent" if table not in schema.tables else "unsupported timestamp column"
    limits = Counter()
    rows = take_records(time_rows(db, table, "*", column, start, end), limits, table)
    if export_limits is not None:
        export_limits.update(limits)
    return rows, 'partial: ' + json.dumps(+limits, sort_keys=True) if +limits else 'available'


def select_windows(frames, samples, options, day_of, range_start=None, range_end=None):
    with workspace() as work:
        work.executescript("""CREATE TABLE own_windows(ts INTEGER PRIMARY KEY);
            CREATE TABLE candidates(ts INTEGER,app TEXT,n INTEGER,PRIMARY KEY(ts,app));
            CREATE TABLE selection(ts INTEGER PRIMARY KEY,stratum TEXT,priority REAL);
            CREATE TABLE strata(identity TEXT PRIMARY KEY,priority REAL);""")
        for row in samples:
            if row['app']:
                work.execute('INSERT OR IGNORE INTO own_windows VALUES(?)', (row['ts'] // 300 * 300,))
        for frame in frames:
            stamp = frame['ts'] // 300 * 300
            if (range_start is not None and stamp < range_start or
                    range_end is not None and stamp + 300 > range_end or
                    options.window_start is not None and stamp < options.window_start or
                    options.window_end is not None and stamp + 300 > options.window_end):
                continue
            if work.execute('SELECT 1 FROM own_windows WHERE ts=?', (stamp,)).fetchone():
                work.execute('INSERT INTO candidates VALUES(?,?,1) ON CONFLICT(ts,app) DO UPDATE SET n=n+1',
                             (stamp, digest(normalized(frame.get('app_name')))))
        rng = random.Random(options.seed)
        for stamp, app in work.execute("""SELECT a.ts,a.app FROM candidates a WHERE a.app=(
                SELECT b.app FROM candidates b WHERE b.ts=a.ts ORDER BY n DESC,app LIMIT 1) ORDER BY ts"""):
            stratum = day_of(stamp) + ':' + app
            work.execute('INSERT INTO selection VALUES(?,?,?)', (stamp, stratum, rng.random()))
            work.execute('INSERT OR IGNORE INTO strata VALUES(?,?)', (stratum, rng.random()))
        available = work.execute('SELECT count(*) FROM selection').fetchone()[0]
        selected = []
        while len(selected) < min(options.bundle_count, MAX_BUNDLES):
            progress = False
            for (stratum,) in work.execute('SELECT identity FROM strata ORDER BY priority,identity'):
                row = work.execute('SELECT ts FROM selection WHERE stratum=? ORDER BY priority,ts LIMIT 1', (stratum,)).fetchone()
                if row is not None:
                    selected.append(row[0])
                    work.execute('DELETE FROM selection WHERE ts=?', (row[0],))
                    progress = True
                    if len(selected) >= min(options.bundle_count, MAX_BUNDLES):
                        break
            if not progress:
                break
        return sorted(selected), available


def take_records(rows, limits, channel):
    result, size = [], 0
    for row in rows:
        fields = row.get('_oversized_fields', ())
        limits[channel + '_oversized_fields'] += len(fields)
        encoded_size = len(json.dumps(row, ensure_ascii=False, default=masked_tree).encode('utf-8'))
        if len(result) >= MAX_BUNDLE_ROWS or size + encoded_size > MAX_RECORD:
            limits[channel + '_skipped_records'] += 1
            continue
        size += encoded_size
        result.append(row)
    return result


def private_json(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)


def export_bundles(db, frames, evidence, samples, options, day_of, start, end, work, evidence_apps):
    selected, available = select_windows(frames, samples, options, day_of, start, end)
    metadata = {"seed": options.seed, "requested": options.bundle_count, "available_windows": available,
                "window_from_ts": options.window_start, "window_to_ts": options.window_end,
                "selected_windows": [{"start_ts": t, "end_ts": t + 300} for t in selected],
                "mode": "same_time" if options.window_start is not None else "historical_baseline",
                "exported": 0, "reason": "bundle export not requested"}
    if options.bundle_dir is None:
        return metadata
    root = Path(options.bundle_dir)
    made = False
    if root.is_symlink():
        raise ValueError()
    if not root.exists():
        root.mkdir(mode=0o700)
        made = True
    if root.stat().st_mode & 0o077 or any(root.iterdir()):
        raise ValueError()
    created, export_days = [], defaultdict(Counter)
    try:
        history = Timeline(db, "log_recording_history", start, end) if Schema(db).has("log_recording_history", "since", "enabled", "paused_until") else None
        for stamp in selected:
            export_limits = Counter()
            nearby_samples = take_records(neighborhood(samples, stamp - 1, stamp + 301), export_limits, 'samples')
            window_samples = [r for r in nearby_samples if stamp <= r["ts"] < stamp + 300]
            nearby_evidence = take_records(neighborhood(evidence, stamp - 60, stamp + 360), export_limits, 'evidence')
            screen_times = defaultdict(list)
            for row in nearby_evidence:
                if row["kind"] == "screen":
                    screen_times[evidence_apps.at(row["source"], row["ts"])].append(row["ts"])
            for times in screen_times.values():
                times.sort()
            focused = []
            for frame in take_records((frames.between(stamp, stamp + 300) if isinstance(frames, ReferenceFrames) else
                          (r for r in frames if stamp <= r["ts"] < stamp + 300)), export_limits, 'frames'):
                nearby = [r for r in nearby_samples if within_time(r['ts'], frame['timestamp_seconds'], 1)]
                same = [r for r in nearby if normalized(r["app"]) == normalized(frame.get("app_name"))]
                is_focused = any(r["window"] and normalized(r["window"]) == normalized(frame.get("window_name")) for r in same)
                other_monitor = any(r.get("monitor_id") is not None and frame.get("monitor_id") is not None
                                    and r["monitor_id"] != frame["monitor_id"] for r in nearby)
                state = history.at(frame['timestamp_seconds']) if history else None
                focused.append({"frame": frame, "comparison": {
                    "focused_per_ours": "yes" if is_focused else "other_monitor" if other_monitor else "no" if nearby else "unknown",
                    "screen_evidence_within_60s": near(screen_times[digest(normalized(frame.get("app_name")))], frame.get("timestamp_seconds", frame["ts"]), 60),
                    "matching_document": any(same_document(r["document_key"], frame.get("browser_url")) for r in same),
                    "document_comparison_available": bool(frame.get("browser_url")) and any(r["document_key"] for r in same),
                    "our_samples_within_1s": len(nearby), "same_app_within_1s": bool(same),
                    "recording_enabled": state["enabled"] if state else None,
                    "paused": state["paused_until"] > frame['timestamp_seconds'] if state and state["paused_until"] is not None else False if state else None,
                    "excluded_per_ours": any(r.get("excluded") for r in same) if same else None,
                    "monitor_metadata_available": any(r.get("monitor_id") is not None for r in nearby) and frame.get("monitor_id") is not None}})
            agents, agent_status = rows_in_window(db, "agent_log_events", stamp, stamp + 300, export_limits)
            commits, git_status = rows_in_window(db, "git_commits", stamp, stamp + 300, export_limits)
            payloads = []
            schema = Schema(db)
            if agents and schema.has("agent_log_payloads", "event_id"):
                ids = {row.get("id") for row in agents}
                payloads = take_records((r for identity in ids for r in bounded_rows(db, 'agent_log_payloads', 'event_id=?', (identity,))), export_limits, 'agent_payloads')
            own_evidence = [r for r in nearby_evidence if stamp <= r["ts"] < stamp + 300]
            halo = [r for r in nearby_evidence if r["kind"] == "screen" and not stamp <= r["ts"] < stamp + 300]
            bundle = {"bundle_version": 1, "seed": options.seed, "start_ts": stamp, "end_ts": stamp + 300,
                      "comparison_mode": metadata["mode"], "reference": focused,
                      "ours": {"samples": window_samples, "evidence": own_evidence,
                               "screen_evidence_context": halo,
                               "context_note": "Context rows lie outside the selected window and support only within-60-second comparisons."},
                      "our_only_candidates": {"prompts": [r for r in own_evidence if r["kind"] == "prompt"],
                                               "agent_session_events": agents, "agent_payloads": payloads, "commits": commits},
                      "channel_status": {"agent_events": agent_status, "git_commits": git_status},
                      "input_limits": dict(+export_limits), "partial_input": bool(+export_limits),
                      "judgment": None, "masking_policy": "product_swift_redaction_plus_authorization_v2"}
            export_days[day_of(stamp)].update(+export_limits)
            filename = "window-" + str(stamp) + ".json"
            created.append(root / filename)
            private_json(created[-1], masked_tree(bundle))
        manifest = {"format": "fidelity-local-bundles-v1", "seed": options.seed,
                    "windows": metadata["selected_windows"], "files": [p.name for p in created]}
        created.append(root / ".fidelity-bundles.json")
        private_json(created[-1], manifest)
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        if made:
            root.rmdir()
        raise
    metadata.update(exported=len(selected), reason=None if selected else "no shared focused windows")
    metadata['limits_by_day'] = [dict(day=day, **count) for day, count in export_days.items() if count]
    metadata['partial_input'] = bool(metadata['limits_by_day'])
    return metadata


def delete_bundles(directory):
    root = Path(directory)
    if root.is_symlink() or root.stat().st_mode & 0o077:
        raise ValueError()
    manifest_path = root / ".fidelity-bundles.json"
    if manifest_path.is_symlink():
        raise ValueError()
    with manifest_path.open('rb') as stream:
        encoded = stream.read(MAX_RECORD + 1)
    if len(encoded) > MAX_RECORD:
        raise ValueError()
    manifest = json.loads(encoded)
    if manifest.get("format") != "fidelity-local-bundles-v1":
        raise ValueError()
    files = manifest.get("files", [])
    if not all(isinstance(name, str) and re.fullmatch(r"window-\d+\.json", name) for name in files):
        raise ValueError()
    for name in files:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError()
    for name in files:
        (root / name).unlink()
    manifest_path.unlink()
    if not any(root.iterdir()):
        root.rmdir()
    return len(files)


@contextmanager
def workspace():
    with tempfile.TemporaryDirectory(prefix="fidelity-analysis-") as folder:
        path = Path(folder) / "state.sqlite"
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        os.close(fd)
        db = sqlite3.connect(path)
        try:
            db.execute("PRAGMA cache_size=-2048")
            db.execute("PRAGMA temp_store=FILE")
            db.execute("PRAGMA journal_mode=OFF")
            yield db
        finally:
            db.close()


def allocate_prompts(work):
    """Maximum-cardinality matching, preserving exact identity priority during fallback."""
    for phase in (0, 1):
        for (identity,) in work.execute("SELECT instruction FROM prompt_inputs ORDER BY ts,instruction"):
            if work.execute("SELECT 1 FROM assignments WHERE instruction=?", (identity,)).fetchone():
                continue
            work.execute("DELETE FROM augment_inputs")
            work.execute("DELETE FROM augment_prompts")
            work.execute("INSERT INTO augment_inputs(instruction) VALUES(?)", (identity,))
            free = None
            while free is None:
                row = work.execute("SELECT instruction FROM augment_inputs WHERE visited=0 ORDER BY rowid LIMIT 1").fetchone()
                if row is None:
                    break
                current = row[0]
                work.execute("UPDATE augment_inputs SET visited=1 WHERE instruction=?", (current,))
                assigned = work.execute("SELECT phase FROM assignments WHERE instruction=?", (current,)).fetchone()
                edge_phase = assigned[0] if assigned else phase
                for prompt, owner in work.execute("""SELECT e.prompt,a.instruction FROM prompt_edges e
                        LEFT JOIN assignments a ON a.prompt=e.prompt
                        WHERE e.phase=? AND e.instruction=?
                        AND NOT EXISTS(SELECT 1 FROM augment_prompts v WHERE v.prompt=e.prompt)
                        ORDER BY e.prompt""", (edge_phase, current)):
                    work.execute("INSERT INTO augment_prompts VALUES(?,?)", (prompt, current))
                    if owner is None:
                        free = prompt
                        break
                    work.execute("INSERT OR IGNORE INTO augment_inputs(instruction) VALUES(?)", (owner,))
            # Reverse the augmenting path, freeing each previous assignment in turn.
            while free is not None:
                parent = work.execute("SELECT parent FROM augment_prompts WHERE prompt=?", (free,)).fetchone()[0]
                old = work.execute("SELECT prompt,phase FROM assignments WHERE instruction=?", (parent,)).fetchone()
                work.execute("DELETE FROM assignments WHERE instruction=?", (parent,))
                work.execute("""INSERT INTO assignments SELECT i.instruction,p.body=i.body,p.length=i.length,p.id,?
                    FROM prompt_inputs i JOIN prompts p ON p.id=? WHERE i.instruction=?""", (old[1] if old else phase, free, parent))
                free = old[0] if old else None


def analyze(db, homes, start, end, tz=timezone.utc, references=None, reference=None):
    with workspace() as work:
        return analyze_streamed(db, homes, start, end, tz, references, reference, work)


def analyze_streamed(db, homes, start, end, tz, references, reference, work):
    schema, diagnostics, failures = Schema(db), Counter(), Counter()
    day_of = lambda stamp: datetime.fromtimestamp(stamp, tz).date().isoformat()
    days = []
    current = datetime.fromtimestamp(start, tz).date()
    last = datetime.fromtimestamp(end - 1, tz).date()
    while current <= last:
        days.append(current.isoformat())
        current += timedelta(days=1)
    references = references or ReferenceInputs()
    if references.selected_days:
        days = [day for day in days if day in references.selected_days]
    edge = max(60 if reference is not None else 1, references.tolerance)
    limits = InputLimits(day_of, days, edge)
    for table in ('samples', 'evidence', 'git_repositories', 'git_repos', 'git_commits',
                  'screen_captures', 'screen_acquisitions', 'screen_capture_counters', 'screen_capture_stats',
                  'log_recording_history', 'awake_history', 'exclusion_history'):
        if table not in schema.tables:
            continue
        columns = schema.columns(table)
        timestamp = schema.column(table, 'ts', 'since')
        if timestamp:
            limits.audit_timestamps(db, table, timestamp)
        if 'since' in columns:
            limits.audit(table, bounded_rows(db, table, 'since<?', (start,),
                                             suffix='ORDER BY since DESC,rowid DESC LIMIT 1'))
            limits.audit(table, bounded_rows(db, table, 'since>=? AND since<?', (start, end)))
        elif 'ts' in columns:
            limits.audit(table, QueryRows(db, table, start - edge, end + edge))
        else:
            limits.audit(table, bounded_rows(db, table))
    if reference is not None:
        for table in ('frames', 'ui_events'):
            if Schema(reference).has(table, 'timestamp'):
                limits.audit_timestamps(reference, table, 'timestamp')
            limits.audit(table, reference_rows(reference, table, start, end, days, day_of, work=work))
    sample_columns = ("ts", "bundle_id", "app", "window", "document_key", "keys", "clicks", "scrolls")
    samples_available = schema.has("samples", *sample_columns)
    edge = max(60 if reference is not None else 1, references.tolerance)
    samples = QueryRows(db, "samples", start - edge, end + edge) if samples_available else []
    keys = DiskKeys(work, neighborhood(samples, start - 1, end + 1))
    candidates, outgoing, received = read_logs(homes, diagnostics, work)
    classify(candidates, outgoing, received, keys)
    def selected():
        return (c for c in candidates if start <= c.ts < end and day_of(c.ts) in days)
    classifications = Counter(c.sender + ("_queued" if c.queued and c.sender == "human" else "") for c in selected())
    def typed():
        return (c for c in selected() if c.sender == "human" and not c.queued)
    evidence_available = schema.has("evidence", "ts", "kind", "source", "source_id", "text")
    work.executescript("""CREATE TABLE prompts(id INTEGER PRIMARY KEY, ts INTEGER, source TEXT, identity TEXT,
        body TEXT,length INTEGER,legacy INTEGER,used INTEGER DEFAULT 0);
        CREATE INDEX prompt_identity ON prompts(source,identity,ts);
        CREATE INDEX prompt_body ON prompts(source,body,ts);
        CREATE TABLE assignments(instruction TEXT PRIMARY KEY,equal_digest INTEGER,equal_length INTEGER,prompt INTEGER,phase INTEGER);""")
    if evidence_available:
        for row in bounded_rows(db, 'evidence', "kind='prompt' AND ts>=? AND ts<?", (start - 1, end + 1),
                                columns=['rowid', 'ts', 'source', 'source_id', 'text']):
            legacy = row["source_id"] is None or ":legacy:" in row["source_id"]
            work.execute("INSERT INTO prompts VALUES(?,?,?,?,?,?,?,0)",
                         (row['rowid'], row["ts"], digest(row["source"]), digest(row["source_id"]),
                          None if row.get('_oversized_fields') else digest(row["text"]), len(row["text"]), legacy))
    def instruction_key(c):
        return digest(c.tool + c.session + c.source_id)
    work.executescript("""CREATE TABLE prompt_inputs(instruction TEXT PRIMARY KEY,ts INTEGER,body TEXT,length INTEGER);
        CREATE TABLE prompt_edges(phase INTEGER,instruction TEXT,prompt INTEGER,
            PRIMARY KEY(phase,instruction,prompt));
        CREATE TABLE augment_inputs(instruction TEXT PRIMARY KEY,visited INTEGER DEFAULT 0);
        CREATE TABLE augment_prompts(prompt INTEGER PRIMARY KEY,parent TEXT);
        CREATE UNIQUE INDEX assigned_prompt ON assignments(prompt);""")
    for c in typed():
        identity = instruction_key(c)
        work.execute("INSERT INTO prompt_inputs VALUES(?,?,?,?)", (identity, c.ts, c.body_digest, c.length))
        scope = '' if c.tool == 'claude' and c.native_identity else c.session
        query = "SELECT id,ts FROM prompts WHERE ts>=? AND ts<=? AND source IN (SELECT source FROM aliases WHERE tool=? AND scope=? AND identity=?) AND "
        for phase, condition, value in ((0, "identity=?", c.source_id),
                                         (1, "body=?" + (" AND legacy=1" if c.native_identity else ""), c.body_digest)):
            for prompt, stamp in work.execute(query + condition, (c.ts - 1, c.ts + 1, c.tool, scope, c.source_id, value)):
                if within_time(stamp, c.ts, 1):
                    work.execute("INSERT OR IGNORE INTO prompt_edges VALUES(?,?,?)", (phase, identity, prompt))
    allocate_prompts(work)
    measurements = []
    for day in days:
        for tool in ("claude", "codex"):
            def instructions():
                return (c for c in typed() if c.tool == tool and day_of(c.ts) == day)
            instruction_count = sum(1 for c in instructions())
            captured = stored = equal = same_length = 0
            for c in instructions():
                found = c.app and keys.has(c.app, c.ts)
                captured += bool(found)
                if samples_available and not found:
                    failures["instruction_app_unresolved" if not c.app else "instruction_without_keys"] += 1
                match = work.execute("SELECT equal_digest,equal_length FROM assignments WHERE instruction=?", (instruction_key(c),)).fetchone()
                stored += match is not None
                equal += match[0] if match else 0
                same_length += match[1] if match else 0
                if evidence_available and match is None:
                    failures["missing_prompt_evidence"] += 1
            reason = None if instruction_count else ("no typed instructions" if diagnostics[tool + "_files"] else "no readable agent logs")
            row = measure("C1", "typed_instructions_with_keys", day,
                                        captured if samples_available else None, instruction_count, tool,
                                        "channel absent: samples" if not samples_available else reason)
            row.update(classified_by_tool_marker=sum(c.marker == "human" for c in instructions()),
                       classified_by_input=sum(not c.marker for c in instructions()),
                       session_app_unresolved=sum(not c.app for c in instructions()))
            measurements.append(row)
            row = measure("C2", "typed_instructions_stored", day,
                          stored if evidence_available else None, instruction_count, tool,
                          "channel absent: prompt evidence" if not evidence_available else reason)
            row.update(equal_digest=equal, equal_length=same_length,
                       identity_matched_content_changed=stored - equal)
            measurements.append(row)
            unavailable = diagnostics[tool + "_unreadable_log_files"]
            malformed = diagnostics[tool + "_malformed_log_files"]
            oversized = diagnostics[tool + "_oversized_log_lines"]
            for item in measurements[-2:]:
                item.update(source_files=diagnostics[tool + "_source_files"],
                            readable_source_files=diagnostics[tool + "_source_files"] - unavailable,
                            unavailable_source_files=unavailable,
                            malformed_source_files=malformed, oversized_source_lines=oversized,
                            oversized_source_lines_unplaced=oversized,
                            partial_input=bool(unavailable or malformed or oversized))
                if item["partial_input"]:
                    item["reason"] = "partial: agent logs malformed, oversized or unreadable"
    work.execute("CREATE TABLE input_seconds(day TEXT,ts INTEGER,app INTEGER,window INTEGER,document INTEGER,PRIMARY KEY(day,ts))")
    for row in samples:
        if start <= row["ts"] < end and day_of(row["ts"]) in days and any(row[name] > 0 for name in ("keys", "clicks", "scrolls")):
            flags = [bool(value and value.strip()) for value in (row["bundle_id"] or row["app"], row["window"], row["document_key"])]
            work.execute("""INSERT INTO input_seconds VALUES(?,?,?,?,?) ON CONFLICT(day,ts) DO UPDATE SET
                app=max(app,excluded.app),window=max(window,excluded.window),document=max(document,excluded.document)""",
                         (day_of(row["ts"]), row["ts"], *flags))
    for day in days:
        denominator = work.execute("SELECT count(*) FROM input_seconds WHERE day=?", (day,)).fetchone()[0]
        for name in ("app", "window", "document", "any_attribution"):
            condition = name + "=0" if name != "any_attribution" else "(app=0 OR window=0 OR document=0)"
            missing = work.execute("SELECT count(*) FROM input_seconds WHERE day=? AND " + condition, (day,)).fetchone()[0]
            if name != "any_attribution":
                failures["input_seconds_missing_" + name] += missing
            measurements.append(measure("C3", "input_seconds_missing_" + name, day,
                                        missing if samples_available else None, denominator,
                                        reason=None if samples_available else "channel absent: samples", lower=True))
    gaps, reason = gap_checks(schema, start, end, day_of, failures, days) if samples_available else ([], "channel absent: samples")
    for day in days:
        missing, eligible, unknown = gaps.get(day, [0, 0, 0]) if not reason else (None, None, None)
        measurements.append(dict(measure("C3", "unexplained_gap_minutes", day, missing, eligible,
                                         reason=reason, lower=True), unknown_history_minutes=unknown))
    measurements.extend(git_checks(schema, start, end, day_of, days, failures))
    measurements.extend(screen_checks(schema, start, end, day_of, days, failures))
    external_failures = failures if samples_available else Counter()
    external = []
    population = KnownFiles(work, samples, start, end, day_of, days, diagnostics)
    for day in days:
        day_start = max(start, int(datetime.fromisoformat(day).replace(tzinfo=tz).timestamp()))
        day_end = min(end, int((datetime.fromisoformat(day) + timedelta(days=1)).replace(tzinfo=tz).timestamp()))
        # Reusable cursor views keep attribution indices bounded to one day.
        day_samples = samples.between(day_start - references.tolerance, day_end + references.tolerance) if isinstance(samples, QueryRows) else []
        external.extend(chrome_checks(references, day_samples, day_start, day_end, day_of, [day], external_failures, diagnostics))
        external.extend(file_checks(day_samples, day_of, [day], references, external_failures, population))
        external.extend(shell_checks(references, day_samples, day_start, day_end, day_of, [day], external_failures, diagnostics))
    if not samples_available:
        for row in external:
            row.update(numerator=None, ratio=None, reason="channel absent: samples")
    measurements.extend(external)
    evidence_apps = EvidenceApps(db, work, limits) if reference is not None else None
    comparison, focused, raw_evidence, _ = reference_checks(db, reference, samples, start, end, day_of, days, failures, references, diagnostics, work, evidence_apps=evidence_apps)
    measurements.extend(comparison)
    if reference is not None:
        bundles = export_bundles(db, focused, raw_evidence, samples, references, day_of, start, end, work, evidence_apps)
    else:
        bundles = {"seed": references.seed, "requested": references.bundle_count,
                   "exported": 0, "selected_windows": [], "reason": "reference recorder unavailable"}
    dependencies = {
        'C1': ('samples',), 'C2': ('evidence',),
        'C3': ('samples', 'log_recording_history', 'awake_history', 'exclusion_history'),
        'C4': ('git_repositories', 'git_repos', 'git_commits'),
        'C5': ('screen_captures', 'screen_acquisitions', 'screen_capture_counters', 'screen_capture_stats'),
        'C6': ('samples',), 'C7': ('samples',), 'C8': ('samples',),
        'C9': ('samples', 'frames'), 'C10': ('evidence', 'frames', 'evidence_apps'), 'C11': ('samples', 'ui_events')}
    for row in measurements:
        limits.apply(row, dependencies[row['check']])
    bundles['input_limits'] = [dict(source=source, day=day, **count)
                              for (source, day), count in limits.counts.items() if count]
    bundles['partial_input'] = bool(bundles['input_limits']) or bundles.get('partial_input', False)
    worst = []
    for day in days:
        values = [r for r in measurements if r["day"] == day and r["ratio"] is not None]
        # Keep denominators separate; worst ranks by the worst individual defect ratio.
        if values:
            row = max(values, key=lambda r: r["ratio"] if r["lower_is_better"] else 1 - r["ratio"])
            worst.append({"day": day, "check": row["check"], "metric": row["metric"],
                          "defect_ratio": row["ratio"] if row["lower_is_better"] else 1 - row["ratio"],
                          "numerator": row["numerator"], "denominator": row["denominator"]})
    return {"report_version": 1, "schema_version": db.execute("PRAGMA user_version").fetchone()[0],
            "start_ts": start, "end_ts": end, "timezone": str(tz),
            "selected_days": days,
            "classifications": dict(classifications), "diagnostics": dict(diagnostics),
            "sample_export": bundles,
            "measurements": measurements,
            "worst_days": sorted(worst, key=lambda r: (-r["defect_ratio"], r["day"]))[:5],
            "top_failure_categories": [{"category": k, "count": v} for k, v in failures.most_common(5) if v]}


def summary(report):
    lines = ["Layer 1 fidelity; counts retain their own denominators."]
    groups = defaultdict(list)
    for row in report["measurements"]:
        groups[(row["check"], row["metric"], row["tool"])].append(row)
    for (check, metric, tool), rows in groups.items():
        available = [r for r in rows if r["numerator"] is not None and r["denominator"] is not None]
        numerator = sum(r["numerator"] for r in available)
        denominator = sum(r["denominator"] for r in available)
        ratio = f"{numerator / denominator:.1%}" if denominator else "n/a"
        reasons = sorted({r["reason"] for r in rows if r["reason"] and not (denominator and r["reason"] in ("no typed instructions", "empty denominator"))})
        lines.append(f"{check} {metric}" + (f" ({tool})" if tool else "") +
                     f": {numerator}/{denominator} ({ratio})" + ("; " + "; ".join(reasons) if reasons else ""))
    lines.append("Worst days: " + (", ".join(f"{r['day']} {r['metric']} {r['numerator']}/{r['denominator']}"
                                            for r in report["worst_days"]) or "unavailable"))
    lines.append("Top failure categories: " + (", ".join(f"{r['category']}={r['count']}"
                                                        for r in report["top_failure_categories"]) or "none measured"))
    lines.append("Sender classifications: " + (", ".join(f"{k}={v}" for k, v in sorted(report["classifications"].items())) or "none"))
    warnings = {k: v for k, v in report["diagnostics"].items() if v and not k.endswith("_files")}
    if warnings:
        lines.append("Input diagnostics: " + ", ".join(f"{k}={v}" for k, v in sorted(warnings.items())))
    return "\n".join(lines)


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes user-provided paths or invalid values.
        self.exit(2, "Invalid arguments; use --help for the accepted format.\n")


def main(argv=None):
    parser = SafeParser(description=__doc__)
    parser.add_argument("database", type=Path, nargs="?")
    parser.add_argument("--claude-home", type=Path, action="append")
    parser.add_argument("--codex-home", type=Path, action="append")
    parser.add_argument("--from", dest="start", help="inclusive ISO date/time or Unix seconds")
    parser.add_argument("--to", dest="end", help="exclusive ISO date/time or Unix seconds")
    parser.add_argument("--timezone", default="UTC", help="IANA zone for dates and day buckets; default UTC")
    parser.add_argument("--chrome-history", type=Path, action="append", default=[], help="Chrome profile History SQLite; repeatable, opt-in")
    parser.add_argument("--shell-history", type=Path, action="append", default=[], help="zsh extended or timestamped bash history; repeatable, opt-in")
    parser.add_argument("--tolerance-seconds", type=int, default=5, help="C6-C8 time tolerance; default 5; C1/C2 stay at 1 second")
    parser.add_argument("--terminal-app", action="append", default=[], help="additional terminal bundle ID; repeatable")
    parser.add_argument("--reference-database", type=Path, help="optional reference recorder database; no default")
    parser.add_argument("--bundle-dir", type=Path, help="new or empty private folder for masked local C12 bundles")
    parser.add_argument("--bundle-count", "--sample-count", type=int, default=20)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--window-from", help="inclusive same-time comparison boundary")
    parser.add_argument("--window-to", help="exclusive same-time comparison boundary")
    parser.add_argument("--days", help="comma-separated selected ISO dates")
    parser.add_argument("--delete-bundles", type=Path, help="delete only this tool's manifested local bundles")
    args = parser.parse_args(argv)
    try:
        if args.delete_bundles is not None:
            count = delete_bundles(args.delete_bundles)
            print(json.dumps({"bundles_deleted": count}))
            return 0
        if args.database is None or not (args.start or args.window_from) or not (args.end or args.window_to):
            raise ValueError()
        tz = ZoneInfo(args.timezone)
        def boundary(value):
            try:
                return int(value)
            except ValueError:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                return int((parsed.replace(tzinfo=tz) if parsed.tzinfo is None else parsed).timestamp())
        start, end = boundary(args.start or args.window_from), boundary(args.end or args.window_to)
        if end <= start:
            raise ValueError()
        if args.tolerance_seconds < 0 or not 0 <= args.bundle_count <= MAX_BUNDLES:
            raise ValueError()
        if bool(args.window_from) != bool(args.window_to):
            raise ValueError()
        window_start = boundary(args.window_from) if args.window_from else None
        window_end = boundary(args.window_to) if args.window_to else None
        if window_start is not None and window_end <= window_start:
            raise ValueError()
        selected_days = tuple(datetime.fromisoformat(day).date().isoformat() for day in args.days.split(",")) if args.days else ()
        homes = {"claude": args.claude_home or [Path.home() / ".claude"],
                 "codex": args.codex_home or [Path.home() / ".codex"]}
        with readonly(args.database) as db, ExitStack() as stack:
            references = ReferenceInputs(tuple(args.chrome_history), tuple(args.shell_history),
                                         args.tolerance_seconds, tuple(args.terminal_app), args.reference_database,
                                         args.bundle_dir, args.bundle_count, args.seed, window_start, window_end, selected_days)
            reference, reference_error = None, False
            if args.reference_database is not None:
                try:
                    reference = stack.enter_context(reference_snapshot(args.reference_database))
                except (sqlite3.Error, OSError):
                    reference_error = True
            for attempt in range(3):
                try:
                    report = analyze(db, homes, start, end, tz, references, reference)
                    break
                except sqlite3.Error:
                    if reference is None:
                        raise
                    stack.close()
                    if attempt == 2:
                        reference, reference_error = None, True
                        report = analyze(db, homes, start, end, tz, references)
                        break
                    time.sleep(.05 * (attempt + 1))
                    try:
                        reference = stack.enter_context(reference_snapshot(args.reference_database))
                    except (sqlite3.Error, OSError):
                        reference, reference_error = None, True
            if reference_error:
                report["diagnostics"]["reference_database_unavailable_after_retries"] = 1
                for row in report["measurements"]:
                    if row["check"] in ("C9", "C10", "C11"):
                        row["reason"] = "reference recorder unavailable after retries"
        # One JSON document on stdout, plain-text summary on stderr. No output files
        # are opened, so an output path cannot accidentally overwrite an input.
        encoded = json.dumps(report, indent=2, sort_keys=True)
        plain = summary(report)
        close_mask()
        print(encoded)
        print(plain, file=sys.stderr)
        return 0
    except KeyboardInterrupt:
        close_mask()
        print("Fidelity check cancelled; temporary stores removed.", file=sys.stderr)
        return 130
    except Exception:
        close_mask()
        print("Fidelity check failed: input unavailable, invalid range or unsupported data; no content emitted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
