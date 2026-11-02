#!/usr/bin/env python3
"""Read-only, content-free layer-1 recorder measurements. See FidelityCheck.md."""

import atexit
import argparse
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict, deque
from contextlib import closing, contextmanager
from contextlib import ExitStack
import ctypes
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
import errno
import hashlib
from functools import lru_cache
from itertools import chain, groupby
import json
import math
import os
from pathlib import Path
import re
import random
import select
import shutil
import signal
import sqlite3
import stat
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
    all_logs: bool = False
    log_lookback: int = 86400
    copy_time: object = None
    copy_time_basis: str = "unknown"


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
# A screen capture happens while its app is focused, so its name is in a sample
# seconds away. One day of margin keeps this read independent of lifetime samples.
APP_NAME_LOOKBACK = 86400
# RestPolicy.inputAgeSeconds: the recorder stops writing this long after the last input.
REST_AFTER_INPUT = 300
# Reference event types a person makes. Focus and app changes can come from a program.
REFERENCE_PERSON_EVENTS = frozenset(("click", "mouse_click", "mouseclick", "key", "keypress", "key_press", "keydown",
                                     "text", "typing", "scroll"))
# A tool marked these lines as not a person's.
NOT_A_PERSON_MARKERS = ("agent", "non_instruction", "imported")
# Text sent in through a terminal carries the same typed marker as a person's. This many uses of one
# text template in the logs read make it repeated_text. A guess: never fitted to real data.
REPEATED_TEXT_MIN = 3
# Shorter text repeats by nature ("continue"), so it is never judged. The same size as a shingle.
TEMPLATE_MIN_WORDS = 8
# One message written as several lines of a log need not carry one exact time, and a false third
# use would take a person's instruction out of C1, so equal text this close in a session is one use.
SAME_LINE_SECONDS = 2
# What can add up to a finding about the person. A Chrome visit can load itself and a shell line can
# be a script's, so those two are shown by source and take no part in totals or ranks.
ACTIVITY_TOTAL_SOURCES = frozenset(("reference_input", "typed_instruction"))
ACTIVITY_SOURCES = ("reference_input", "typed_instruction", "shell_history", "chrome_visit")


class Progress:
    """One content-free stderr line per stage, so a long run can be told from a hung one."""
    enabled = False
    began = time.monotonic()
    last = began

    @classmethod
    def start(cls):
        cls.enabled, cls.began, cls.last = True, time.monotonic(), time.monotonic()

    @classmethod
    def stage(cls, name):
        if cls.enabled:
            cls.last = time.monotonic()
            print(f"fidelity: {name} ({cls.last - cls.began:.0f}s)", file=sys.stderr, flush=True)

    @classmethod
    def tick(cls, name, count):
        """At most one line a minute from inside a long stage."""
        if cls.enabled and time.monotonic() - cls.last >= 60:
            cls.stage(f"{name}: {count} done")


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
        # With an index, only non-numbers are read: text and blobs sort after every
        # number, so this seeks past the lifetime rows instead of visiting them.
        name = quoted(column)
        if timestamp_index_name(db, table, column):
            rows = chain(bounded_rows(db, table, name + '>=?', ('',), columns=[column]),
                         bounded_rows(db, table, name + '>=? AND ' + name + '<?', (float('inf'), ''), columns=[column]),
                         bounded_rows(db, table, name + ' IS NULL', columns=[column]))
        else:
            rows = bounded_rows(db, table, columns=[column], scan=True)
        self.count_unusable(table, column, rows)

    def count_unusable(self, table, column, rows):
        for row in rows:
            if reference_time(row[column]) is not None:
                continue
            count = self.counts[(table, None)]
            count['unavailable_records_unplaced'] += 1
            count['affected_records'] += 1
            if row.get('_oversized_fields'):
                count['oversized_fields'] += 1
            else:
                count['invalid_timestamps'] += 1

    def audit_window_timestamps(self, db, table, column, start, end):
        # The rest of a reference is never visited, so only values its seek reaches can be seen.
        self.count_unusable(table, column, window_candidates(db, table, [column], column, start, end))

    def apply(self, item, sources):
        count = Counter()
        for source in sources:
            if item.get('day') is not None:
                count.update(self.counts[(source, item['day'])])
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


SHORT_ID = re.compile(r"(?<![A-Za-z0-9])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{6,}(?![A-Za-z0-9])")


def text_template(text):
    """A digest of this text with its numbers and ids gone, or None when it has too few words to
    judge. Only the digest leaves this function, so no template text is ever written anywhere."""
    plain = re.sub(r"[0-9]+", "#", SHORT_ID.sub("#", HASH_LIKE.sub("#", text)))
    words = plain.casefold().split()
    if sum(any(letter.isalpha() for letter in word) for word in words) < TEMPLATE_MIN_WORDS:
        return None
    return digest(" ".join(words))


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
    template: str = ""
    repeated: bool = False


def repeated_text(candidate):
    """Its text is a template seen too often for typing, and neither a tool marker nor provenance
    says who sent it. A person pasting one long text that often lands here too."""
    return candidate.repeated and candidate.sender in ("human", "unknown")


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
            CREATE TABLE early_instructions(session TEXT, tool TEXT, origin TEXT, ts INTEGER, body TEXT, template TEXT,
              PRIMARY KEY(session,ts,body));
            CREATE TABLE text_lines(template TEXT, tool TEXT, scope TEXT, identity TEXT, session TEXT, ts INTEGER,
              body TEXT, native INTEGER, PRIMARY KEY(tool,scope,identity));
            CREATE INDEX text_line_group ON text_lines(session,ts,body,native);
        """)

    def append(self, candidate):
        scope = "" if candidate.tool == "claude" and candidate.native_identity else candidate.session
        self.db.execute("INSERT INTO instructions VALUES(NULL,?,?,?,?,?,?,?,?)",
                        (candidate.tool, scope, candidate.source_id, candidate.session, candidate.ts,
                         candidate.body_digest, candidate.native_identity, instruction_json(candidate)))
        self.db.execute("INSERT OR IGNORE INTO aliases VALUES(?,?,?,?)",
                        (candidate.tool, scope, candidate.source_id, candidate.source))

    def append_early(self, candidate):
        """An instruction before the window: it can name its session's app, and is not measured."""
        self.db.execute("INSERT OR IGNORE INTO early_instructions VALUES(?,?,?,?,?,?)",
                        (candidate.session, candidate.tool, candidate.origin, candidate.ts, candidate.body_digest, candidate.template))

    def count_text(self, candidate):
        """One line of any date in the logs read. Copies of a line are one use, by finalize's rule."""
        if candidate.template and candidate.marker not in NOT_A_PERSON_MARKERS:
            scope = "" if candidate.tool == "claude" and candidate.native_identity else candidate.session
            self.db.execute("INSERT OR IGNORE INTO text_lines VALUES(?,?,?,?,?,?,?,?)",
                            (candidate.template, candidate.tool, scope, candidate.source_id, candidate.session, candidate.ts,
                             candidate.body_digest, candidate.native_identity))

    def is_repeated(self, template):
        return bool(template) and self.db.execute("SELECT 1 FROM repeated_templates WHERE template=?", (template,)).fetchone() is not None

    def finalize(self):
        self.db.execute("DELETE FROM instructions WHERE id NOT IN (SELECT min(id) FROM instructions GROUP BY tool,scope,identity)")
        self.db.execute("""DELETE FROM instructions AS a WHERE native=0 AND (
            EXISTS(SELECT 1 FROM instructions b WHERE b.session=a.session AND b.ts=a.ts AND b.body=a.body AND b.native=1)
            OR id<>(SELECT min(id) FROM instructions b WHERE b.session=a.session AND b.ts=a.ts AND b.body=a.body))""")
        self.db.execute("""DELETE FROM text_lines AS a WHERE native=0 AND EXISTS(SELECT 1 FROM text_lines b
            WHERE b.session=a.session AND b.ts>=a.ts-? AND b.ts<=a.ts+? AND b.body=a.body AND (b.native=1 OR b.rowid<a.rowid))""",
                        (SAME_LINE_SECONDS, SAME_LINE_SECONDS))
        self.db.execute("CREATE TABLE repeated_templates(template TEXT PRIMARY KEY)")
        self.db.execute("INSERT INTO repeated_templates SELECT template FROM text_lines GROUP BY template HAVING count(*)>=?", (REPEATED_TEXT_MIN,))

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
            CREATE TABLE outgoing_pieces(call INTEGER,piece TEXT);""")

    def append(self, value):
        stamp, session, pieces = value
        identity = self.db.execute("INSERT INTO outgoing VALUES(NULL,?,?)", (stamp, session)).lastrowid
        self.db.executemany("INSERT INTO outgoing_pieces VALUES(?,?)", ((identity, p) for p in pieces))

    def finish(self):
        # One sorted build is far cheaper than a random insert per shingle in a small cache.
        self.db.execute("CREATE INDEX outgoing_piece ON outgoing_pieces(piece,call)")


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


def person_amount(row, *names):
    """How much of these input counts a person certainly made in this second.

    The recorder stores only person events in these columns, see ActivityStorage.insertSample,
    and such rows have `observed_ts`. A row without it can be older or converted, and its
    counts may include program-made ones, which `synthetic` counts along with key-ups, so
    only what is above `synthetic` is certainly a person's.
    """
    amount = sum(int(row[name]) for name in names)
    if row.get("synthetic") and row.get("observed_ts") is None:
        return max(0, amount - row["synthetic"])
    return amount


class DiskKeys:
    def __init__(self, db, samples):
        self.db = db
        db.execute("CREATE TABLE input_keys(ts INTEGER,app TEXT,PRIMARY KEY(ts,app))")
        for sample in samples:
            app = sample["bundle_id"] or sample["app"]
            if person_amount(sample, "keys") > 0 and app:
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
    def traced(stamp, pieces, session):
        if not pieces:
            return False
        db.execute("DELETE FROM compare_pieces")
        db.executemany("INSERT INTO compare_pieces VALUES(?)", ((p,) for p in pieces))
        # CROSS JOIN fixes the order. Left alone, the planner serves GROUP BY by walking every
        # outgoing call for each comparison, which took hours on thousands of logs.
        return db.execute("""SELECT 1 FROM compare_pieces c CROSS JOIN outgoing_pieces p ON p.piece=c.piece
            CROSS JOIN outgoing o ON o.id=p.call WHERE o.ts<=? AND o.session<>? GROUP BY o.id
            HAVING count(*)>=? LIMIT 1""", (stamp, session, len(pieces) * .5)).fetchone() is not None
    # The session's early outputs give one answer however many instructions it has.
    outputs_traced, classified = {}, 0
    def vote(session, tool, origin, stamp):
        for app in keys.near(stamp):
            db.execute("INSERT INTO votes VALUES(?,?,?,?,1) ON CONFLICT(session,app) DO UPDATE SET n=n+1",
                       (session, tool, origin, app))
    # A notice's keys are someone else's, so repeated text does not say which app a session is in.
    for c in candidates:
        if c.marker in NOT_A_PERSON_MARKERS or c.queued or candidates.is_repeated(c.template):
            continue
        vote(c.session, c.tool, c.origin, c.ts)
    for session, tool, origin, stamp in db.execute("""SELECT session,tool,origin,ts FROM early_instructions
            WHERE template NOT IN (SELECT template FROM repeated_templates)""").fetchall():
        vote(session, tool, origin, stamp)
    db.execute("""INSERT INTO session_apps SELECT session,tool,origin,app FROM votes a
        WHERE n>=2 AND n*1.0/(SELECT sum(n) FROM votes b WHERE b.session=a.session)>=.8""")
    for c in candidates:
        row = db.execute("SELECT app FROM session_apps WHERE session=?", (c.session,)).fetchone()
        if not row and c.origin:
            row = db.execute("""SELECT app FROM session_apps WHERE tool=? AND origin=? GROUP BY app
                HAVING count(*)>=5 AND count(*)*1.0/(SELECT count(*) FROM session_apps WHERE tool=? AND origin=?)>=.8""",
                (c.tool, c.origin, c.tool, c.origin)).fetchone()
        c.app = row[0] if row else ""
        c.repeated = candidates.is_repeated(c.template)
        if c.marker:
            c.sender = c.marker
        else:
            if c.session not in outputs_traced:
                outputs_traced[c.session] = any(traced(stamp, pieces, c.session) for stamp, pieces in received[c.session])
            provenance = traced(c.ts, c.pieces, c.session) or outputs_traced[c.session]
            c.sender = "agent" if provenance else "human" if c.app and keys.has(c.app, c.ts) else "unknown"
        candidates.update(c)
        classified += 1
        Progress.tick("classify instructions", classified)


def first_log_time(path):
    """The first dated line, or None when a bounded head has none."""
    try:
        with path.open('rb') as stream:
            for number, (raw, oversized, _, _) in enumerate(bounded_records(stream, MAX_LOG_LINE)):
                if number >= 32:
                    return None
                if oversized:
                    continue
                try:
                    line = json.loads(raw)
                except (ValueError, UnicodeError):
                    continue
                stamp = epoch(line.get("timestamp")) if isinstance(line, dict) else None
                if stamp is not None:
                    return stamp
    except OSError:
        pass
    return None


@dataclass
class LogScope:
    """Which logs are read and which instructions are kept. See FidelityCheck.md."""
    start: int = None
    end: int = None
    lookback: int = 86400
    all_logs: bool = True

    def skip_reason(self, path):
        """Why this log is not read, or None when it is."""
        if self.all_logs:
            return None
        try:
            # A line cannot be newer than its file's last write.
            if path.stat().st_mtime < self.start - self.lookback:
                return "last_written"
        except OSError:
            return None  # Reading it records the failure in the diagnostics.
        first = first_log_time(path)
        return "first_line" if first is not None and first >= self.end else None

    def keeps(self, stamp):
        # One second of margin: instructions at the window's edges still get classified.
        return self.start is None or self.start - 1 <= stamp < self.end + 1

    def votes_only(self, stamp):
        """Before the window but near it: says which app a session is in, is not measured."""
        return self.start is not None and self.start - self.lookback <= stamp < self.start - 1


def read_logs(homes, diagnostics, work, scope=None):
    """Spill identities and provenance from the logs in scope to private, bounded-cache SQLite."""
    scope = scope or LogScope()
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
                    skipped = scope.skip_reason(path)
                    if skipped:
                        diagnostics[tool + "_log_files_outside_scope"] += 1
                        if skipped == "first_line":
                            diagnostics[tool + "_log_files_starting_after_window"] += 1
                        continue
                    diagnostics[tool + "_source_files"] += 1
                    Progress.tick("read agent logs", diagnostics[tool + "_source_files"])
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
                                keeps, early = scope.keeps(stamp), scope.votes_only(stamp)
                                native_identity = native_id is not None
                                native_id = native_id or tool + ":legacy:" + str(stamp) + ":" + digest(body.strip())
                                origin = str(meta.get("originator", line.get("entrypoint", "")))
                                candidate = Instruction(tool, session, digest(origin) if origin else "", stamp, digest(path.stem),
                                                        digest(native_id), digest(body), len(body), shingles(body) if keeps else set(),
                                                        marker, queued=queued, native_identity=native_identity,
                                                        template=text_template(body) or "")
                                # Lines of any date count, so a notice is known in a narrow window too.
                                candidates.count_text(candidate)
                                if keeps:
                                    candidates.append(candidate)
                                elif early and not queued and marker not in NOT_A_PERSON_MARKERS:
                                    candidates.append_early(candidate)
                    except (OSError, UnicodeError):
                        diagnostics["unreadable_log_files"] += 1
                        diagnostics[tool + "_unreadable_log_files"] += 1
    candidates.finalize()
    outgoing.finish()
    return candidates, outgoing, received


def infer_apps(candidates, keys):
    by_session = defaultdict(Counter)
    origin_sessions = defaultdict(list)
    for c in candidates:
        if c.marker in NOT_A_PERSON_MARKERS or c.queued:
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


class Forgotten:
    """Ranges the person erased with `privacy forget`; their missing rows are not loss."""
    def __init__(self, schema, start, end):
        self.ranges = []
        if schema.has('forgotten_ranges', 'start_ts', 'end_ts'):
            self.ranges = [tuple(row) for row in schema.db.execute(
                'SELECT start_ts,end_ts FROM forgotten_ranges WHERE start_ts<? AND end_ts>?', (end, start))]

    def covers(self, stamp):
        return any(low <= stamp < high for low, high in self.ranges)


class ActivitySignals:
    """Seconds an independent source shows the person active. Times only, in private state."""
    # Seconds a row may sit from the signal: log clocks agree closely, others use the tolerance.
    def __init__(self, work, tolerance):
        self.work, self.tolerances = work, dict(reference_input=1, typed_instruction=1,
                                                shell_history=tolerance, chrome_visit=tolerance)
        # Source to {input: read without failure}. A source with no entry was never asked for.
        self.inputs = defaultdict(dict)
        self.visit_transitions = {}
        work.execute("CREATE TABLE activity_signals(ts INTEGER,source TEXT,PRIMARY KEY(ts,source)) WITHOUT ROWID")

    def add(self, source, stamp):
        self.work.execute("INSERT OR IGNORE INTO activity_signals VALUES(?,?)", (int(stamp // 1), source))

    def input_read(self, source, identity, readable):
        """Inputs are read once a day, and one failure makes that input unreadable."""
        self.inputs[source][identity] = self.inputs[source].get(identity, True) and readable

    def coverage(self, source, low, high):
        """What this source can speak for between these times, and which sources cannot say the rest."""
        inputs = self.inputs.get(source)
        if inputs is None:
            return dict(requested=False, readable=None, first_second=None, last_second=None, seconds=0, cannot_speak_for_rest=None)
        first, last, seconds = self.work.execute("SELECT min(ts),max(ts),count(*) FROM activity_signals WHERE source=? AND ts>=? AND ts<?",
                                                 (source, low, high)).fetchone()
        return dict(requested=True, readable=any(inputs.values()), first_second=first, last_second=last, seconds=seconds,
                    cannot_speak_for_rest=last is None or high - last > REST_AFTER_INPUT)

    def by_second(self):
        rows = self.work.execute("SELECT ts,source FROM activity_signals ORDER BY ts").fetchall()
        return iter([(stamp, [row[1] for row in same]) for stamp, same in groupby(rows, key=lambda row: row[0])])


def gap_counts():
    return dict(missing=0, expected=0, runs=0, longest=0, over_five=0, no_row=0, spans=0, longest_span=0,
                active=0, active_missing=0, implied_expected=0, implied_missing=0,
                sources=defaultdict(lambda: [0, 0]))


def gap_checks(schema, start, end, day_of, failures, days=None, signals=None, copy_time=None):
    """Every second of the window, one forward pass, so the cost follows the window.

    Four separate questions. `missing`: RestPolicy writes a row each second until
    REST_AFTER_INPUT after the last input, and a stored input row proves one of those.
    `no_row`: seconds in a long span with no row, where rest, sleep and loss look alike.
    `active_missing`: a source outside the recorder shows the person active and no row exists.
    The last row against the copy's own time says whether the copy can see past a stop.
    """
    if not schema.has("log_recording_history", "since", "enabled", "paused_until"):
        return {}, {}, "channel absent: recording history required"
    db = schema.db
    history, forgotten = Timeline(db, "log_recording_history", start, end), Forgotten(schema, start, end)
    newest = db.execute('SELECT ts FROM samples WHERE ts<? ORDER BY ts DESC LIMIT 1', (float('inf'),)).fetchone()
    last_stored = int(newest[0] // 1) if newest else None
    # A row past a copy's own time cannot exist, so a stop is only visible up to that time.
    horizon = max(last_stored if last_stored is not None else start - 1,
                  int(copy_time // 1) if copy_time is not None else start - 1)
    counts = defaultdict(gap_counts)

    def selected(stamp):
        return days is None or day_of(stamp) in days

    def recording(stamp):
        state = history.at(stamp)
        return state is not None and state["enabled"] and (state["paused_until"] is None or state["paused_until"] <= stamp)

    synthetic = "synthetic" if schema.has("samples", "synthetic") else "0"
    observed = "observed_ts" if schema.has("samples", "observed_ts") else "NULL"
    moved = "moved" if schema.has("samples", "moved") else "0"
    # The same rule as person_amount, for the product's byPerson (RecorderLoop.observeInputActivity).
    rows = db.execute(f"""SELECT ts,CASE WHEN {synthetic}>0 AND {observed} IS NULL
            THEN keys+clicks+scrolls+{moved}>{synthetic} ELSE keys>0 OR clicks>0 OR scrolls>0 OR {moved} END
        FROM samples WHERE ts>=? AND ts<? ORDER BY ts""", (start - REST_AFTER_INPUT - 1, end + 1))
    seconds = ((stamp, any(row[1] for row in same)) for stamp, same in groupby(rows, key=lambda row: int(row[0] // 1)))
    row_second, row_person = next(seconds, (None, False))
    last_input = last_signal = last_row = None
    tail_explained = 0
    while row_second is not None and row_second < start:
        if row_person:
            last_input = row_second
        row_second, row_person = next(seconds, (None, False))
    pending_signals = signals.by_second() if signals is not None else iter(())
    signal_second, signal_sources = next(pending_signals, (None, ()))

    def row_near(stamp, tolerance):
        return db.execute("SELECT 1 FROM samples WHERE ts>=? AND ts<? LIMIT 1", (stamp - tolerance, stamp + tolerance + 1)).fetchone() is not None

    run_first, run_days, run_missing = None, Counter(), Counter()

    def close_run(after):
        # A run at the window's edge may continue past it; that part is not visible here.
        nonlocal run_first, run_days, run_missing
        if run_first is None:
            return
        length = after - run_first
        for day, part in run_days.items():
            if length > REST_AFTER_INPUT:
                count = counts[day]
                count.update(no_row=count['no_row'] + part, spans=count['spans'] + 1,
                             longest_span=max(count['longest_span'], length))
        for day, part in run_missing.items():
            count = counts[day]
            # The whole silent span, not just the 300 s of it that a stored input can prove.
            count.update(missing=count['missing'] + part, expected=count['expected'] + part, runs=count['runs'] + 1,
                         longest=max(count['longest'], length), over_five=count['over_five'] + (part > 5))
            failures["unexplained_gap_seconds"] += part
        run_first, run_days, run_missing = None, Counter(), Counter()

    for stamp in range(start, end):
        Progress.tick("gap seconds", stamp - start)
        has_row, person = row_second == stamp, row_person and row_second == stamp
        if has_row:
            row_second, row_person = next(seconds, (None, False))
        sources = ()
        if signal_second == stamp:
            sources = signal_sources
            signal_second, signal_sources = next(pending_signals, (None, ()))
        if has_row:
            close_run(stamp)
            last_row, tail_explained = stamp, 0
            if (last_input is not None and stamp <= last_input + REST_AFTER_INPUT or person) and selected(stamp):
                counts[day_of(stamp)]['expected'] += 1
            if person:
                last_input = stamp
        visible = stamp <= horizon
        explained = not has_row and (not recording(stamp) or forgotten.covers(stamp))
        tail_explained += explained
        if not visible or explained:
            close_run(stamp)
        elif not has_row:
            if run_first is None:
                run_first = stamp
            if selected(stamp):
                day = day_of(stamp)
                run_days[day] += 1
                if last_input is not None and stamp <= last_input + REST_AFTER_INPUT:
                    run_missing[day] += 1
        if sources:
            total_sources = ACTIVITY_TOTAL_SOURCES.intersection(sources)
            if total_sources:
                last_signal = stamp
            if visible and (has_row or not explained) and selected(stamp):
                count = counts[day_of(stamp)]
                count['active'] += bool(total_sources)
                silent = False
                for source in sources:
                    empty = not row_near(stamp, signals.tolerances[source])
                    silent = silent or (empty and source in total_sources)
                    count['sources'][source][0] += 1
                    count['sources'][source][1] += empty
                if silent:
                    count['active_missing'] += 1
                    failures["person_active_seconds_without_row"] += 1
        if last_signal is not None and stamp <= last_signal + REST_AFTER_INPUT and visible and (has_row or not explained) and selected(stamp):
            count = counts[day_of(stamp)]
            count['implied_expected'] += 1
            count['implied_missing'] += not has_row
    close_run(end)
    tail = dict(after_last_row=end - (last_row + 1) if last_row is not None else end - start,
                last_row_in_window=last_row is not None, explained=tail_explained,
                last_stored_after_window=last_stored is not None and last_stored >= end,
                copy_after_window_end=None if copy_time is None else copy_time >= end,
                after_copy_time=None if copy_time is None else max(0, end - max(start, int(copy_time // 1) + 1)))
    return counts, tail, None


def git_history(path, since=None):
    command = ["git", "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false", "-C", str(path),
               "log", "--all", "--no-show-signature", "--no-notes", "--format=%H%x09%ct"]
    if since is not None:
        command.insert(-1, f"--since-as-filter=@{since}")
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
    """Commits Git can reach in the window, against what the recorder stored."""
    reason = None
    if not schema.has("git_repositories", "id", "identity", "common_dir", "reopen_blocked"):
        reason = "channel absent: git_repositories required"
    elif not schema.has("git_commits", "repo_id", "hash", "complete"):
        reason = "channel absent: git_commits required"
    if reason:
        return [measure("C4", "commits_recorded", day, reason=reason) for day in days]
    db = schema.db
    tombstones = schema.has("git_tombstones", "hash")
    counts = defaultdict(lambda: Counter(stored=0, reachable=0, incomplete=0, forgotten=0))
    unavailable = masked = blocked = readable = 0
    for repo in bounded_rows(db, "git_repositories", columns=["id", "identity", "common_dir", "reopen_blocked"]):
        if repo["reopen_blocked"]:
            blocked += 1  # The recorder was told not to read it again; missing commits are by design.
            continue
        # The stored path is masked text. When masking changed it, it no longer names the folder.
        if repo["identity"] != digest(repo["common_dir"]):
            masked += 1
            continue
        try:
            for commit, stamp in git_history(repo["common_dir"], start):
                if not start <= stamp < end or day_of(stamp) not in days:
                    continue
                count = counts[day_of(stamp)]
                if tombstones and db.execute("SELECT 1 FROM git_tombstones WHERE hash=?", (commit,)).fetchone():
                    count["forgotten"] += 1  # Erased by the person; not a loss.
                    continue
                count["reachable"] += 1
                stored = db.execute("SELECT complete FROM git_commits WHERE repo_id=? AND hash=?", (repo["id"], commit)).fetchone()
                if stored and stored[0] == 1:
                    count["stored"] += 1
                else:
                    count["incomplete"] += stored is not None
                    failures["missing_git_commits"] += 1
            readable += 1
        except (OSError, subprocess.SubprocessError, ValueError):
            unavailable += 1
    if unavailable or masked:
        failures["unreadable_git_repositories"] += unavailable + masked
    note = "partial: repositories unreadable or their stored path masked" if unavailable or masked else None
    output = []
    for day in days:
        count = counts[day]
        output.append(dict(measure("C4", "commits_recorded", day, count["stored"], count["reachable"],
                                   reason=note or ("no readable registered repositories" if not readable else None)),
                           repositories_readable=readable, repositories_unreadable=unavailable,
                           repositories_path_masked=masked, repositories_blocked=blocked,
                           commits_incomplete=count["incomplete"], commits_forgotten=count["forgotten"],
                           partial_input=bool(unavailable or masked)))
    return output


NO_ACQUISITION_RECORD = ("no acquisition record: no accessibility probe attempt on this day, and outside a probe run "
                         "the current schema stores only kept captures; drop counts are then only in the running recorder's status")
NO_TEXT_ATTEMPTS = "no attempt on this day returned text: see refused_by_design, capture_failed and other_statuses"
UNLINKED_CAPTURES = ("attempts returned text with no linked occurrence, which is not a loss by itself: refused after arrival, "
                     "refused by policy when stored, discarded at suspend, not linked within 60 s, failed to store after hand-off, "
                     "or stored without its link")
# AXProbeOCRRefusal. A drop is lost text; a failure is an acquisition that returned nothing; the rest are the design.
OCR_FAILURES = frozenset(("failed", "permission", "unavailable"))
OCR_DESIGNED_REFUSALS = frozenset(("no_person_input", "key_changed", "superseded", "busy", "expired", "recording_off",
                                   "excluded_app", "secure_input", "own_app", "settings_unreadable", "capture_generation"))
OCR_OTHER_STATUSES = frozenset(("pending", "empty", "failed", "busy", "superseded", "settings_unreadable", "not_acquired",
                                "acquired_without_snapshot"))
PROBE_DROP_EVENTS = ("droppedOCR", "ocr_dropped", "pendingDropped", "overload_dropped")


def stored_capture_at(db, stamp, app_identity, linked):
    """A screen occurrence this attempt could be: same second, same app, no attempt linked to it.
    ActivityStorage links only attempts still pending or in watchdog, so a stored capture can look lost."""
    for row in bounded_rows(db, "evidence", "kind='screen' AND ts=?", (stamp,), columns=["id", "source"]):
        if digest(normalized(row["source"])) == app_identity and row["id"] not in linked:
            return True
    return False


def probe_run_counters(schema, run_ids, start, end):
    """Whole-run drop counts. A run can outlast the window, so these are never a daily rate."""
    if not schema.has("ax_probe_flow", "run_id", "event", "total"):
        return measure("C5", "probe_run_drop_counters", None, reason="channel absent: ax_probe_flow")
    db, runs, totals = schema.db, set(run_ids), Counter({event: 0 for event in PROBE_DROP_EVENTS})
    if schema.has("ax_probe_runs", "id", "start_ts"):
        runs.update(row["id"] for row in bounded_rows(db, "ax_probe_runs", "start_ts>=? AND start_ts<?", (start, end), columns=["id"]))
    for run in runs:
        for row in bounded_rows(db, "ax_probe_flow", "run_id=?", (run,), columns=["event", "total"]):
            if row["event"] in PROBE_DROP_EVENTS:
                totals[row["event"]] += row["total"]
    return dict(measure("C5", "probe_run_drop_counters", None,
                        reason="whole-run counts for runs touching the window: not a rate and not split by day"),
                probe_runs=len(runs), counters=dict(totals), ranked=False)


def screen_checks(schema, start, end, day_of, days, failures):
    """Were acquired captures kept, what became of the others, and can stored ones still be read."""
    db = schema.db
    outcomes = defaultdict(lambda: dict(linked=0, dropped=0, unlinked=0, unlinked_stored=0, designed=0, failed=0, unreadable=0,
                                        reasons=Counter(), statuses=Counter()))
    linked, unlinked, run_ids = set(), [], set()
    if schema.has("ax_probe_attempts", "run_id", "ts", "mapping_key", "evidence_id", "payload"):
        for row in bounded_rows(db, "ax_probe_attempts", "ts>=? AND ts<?", (start, end),
                                columns=["run_id", "ts", "mapping_key", "evidence_id", "payload"]):
            day = day_of(row["ts"])
            if day not in days:
                continue
            run_ids.add(row["run_id"])
            count = outcomes[day]
            try:
                payload = json.loads(row["payload"])
                status, reason = payload.get("ocrStatus"), payload.get("ocr_refusal_reason")
            except (ValueError, AttributeError):
                count["unreadable"] += 1
                continue
            if reason == "dropped":
                count["dropped"] += 1
            elif reason in OCR_FAILURES:
                count["failed"] += 1
            elif reason in OCR_DESIGNED_REFUSALS:
                count["designed"] += 1
                count["reasons"][reason] += 1
            elif status == "completed":
                # Only these attempts prove a capture returned text the recorder then had to keep.
                if row["evidence_id"] is not None:
                    count["linked"] += 1
                    linked.add(row["evidence_id"])
                else:
                    unlinked.append((row["ts"], row["mapping_key"], day))
            else:
                count["statuses"][status if status in OCR_OTHER_STATUSES else "other"] += 1
    for stamp, app, day in unlinked:
        if stored_capture_at(db, stamp, app, linked):
            outcomes[day]["unlinked_stored"] += 1
        else:
            outcomes[day]["unlinked"] += 1
    readable, stored, empty_text = Counter(), Counter(), Counter()
    payloads = schema.has("screen_payloads", "evidence_id", "text_hash") and schema.has("collection_blobs", "hash", "content")
    if payloads and schema.has("evidence", "ts", "kind", "text"):
        # An empty blob is a capture that found no words: a picture or a blank window, or OCR that read
        # nothing, and this cannot say which. A blob that is gone is damage. Only that one is a defect.
        for stamp, present, blob in db.execute(f"""SELECT e.ts,coalesce(octet_length(b.content),0)>0 OR coalesce(octet_length(e.text),0)>0,
                b.hash IS NOT NULL FROM evidence e
                LEFT JOIN screen_payloads p ON p.evidence_id=e.id LEFT JOIN collection_blobs b ON b.hash=p.text_hash
                WHERE e.kind='screen' AND e.ts>=? AND e.ts<?""", (start, end)):
            if day_of(stamp) in days:
                stored[day_of(stamp)] += 1
                readable[day_of(stamp)] += present
                empty_text[day_of(stamp)] += bool(blob and not present)
    output = []
    for day in days:
        count = outcomes[day]
        acquired = count["linked"] + count["dropped"] + count["unlinked"] + count["unlinked_stored"]
        failures["screen_captures_dropped"] += count["dropped"]
        failures["screen_captures_unlinked_unknown"] += count["unlinked"]
        no_blob = stored[day] - readable[day] - empty_text[day]
        failures["screen_occurrences_no_blob"] += no_blob
        attempted = count["designed"] or count["failed"] or count["unreadable"] or count["statuses"]
        notes = [] if acquired else [NO_TEXT_ATTEMPTS if attempted else NO_ACQUISITION_RECORD]
        if count["unlinked"] or count["unlinked_stored"]:
            notes.append(UNLINKED_CAPTURES)
        if count["unreadable"]:
            notes.append("partial: probe attempts unreadable")
        details = dict(denominator_basis="ax_probe_attempts", dropped=count["dropped"], unlinked_unknown=count["unlinked"],
                       unlinked_with_stored_capture=count["unlinked_stored"], refused_by_design=count["designed"],
                       refusal_reasons=dict(count["reasons"]), capture_failed=count["failed"],
                       other_statuses=dict(count["statuses"]), unreadable_attempts=count["unreadable"],
                       partial_input=bool(count["unreadable"]))
        reason = "; ".join(notes) or None
        # Stored comes first and does not rank: its gap is dropped plus unlinked_unknown, which rank themselves.
        output.append(dict(measure("C5", "acquired_captures_stored", day, count["linked"] + count["unlinked_stored"] if acquired else None,
                                   acquired or None, reason=reason), ranked=False, **details))
        output.append(dict(measure("C5", "acquired_captures_linked", day, count["linked"] if acquired else None,
                                   acquired or None, reason=reason), ranked=False, **details))
        output.append(dict(measure("C5", "acquired_captures_dropped", day, count["dropped"] if acquired else None,
                                   acquired or None, reason=reason, lower=True), **details))
        output.append(dict(measure("C5", "acquired_captures_unlinked_unknown", day, count["unlinked"] if acquired else None,
                                   acquired or None, reason=reason, lower=True), **details))
        absent = None if payloads else "channel absent: screen payload tables"
        output.append(dict(measure("C5", "screen_occurrences_with_text", day,
                                   readable[day] if payloads else None, stored[day] if payloads else None, reason=absent),
                           empty_text=empty_text[day], no_blob=no_blob, ranked=False))
        output.append(measure("C5", "screen_occurrences_no_blob", day, no_blob if payloads else None,
                              stored[day] if payloads else None, reason=absent, lower=True))
    output.append(probe_run_counters(schema, run_ids, start, end))
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


def visit_transition_counts():
    return dict(reload=0, subframe=0, auto_toplevel=0, redirect=0, unavailable=0)


def count_visit_transition(counts, transition):
    """Chromium's PageTransition: a core type in the low byte, redirect flags in the top two bits.
    A redirect is a flag on a visit of some type, so these overlap and do not add up."""
    if not isinstance(transition, int):
        counts["unavailable"] += 1
        return
    core = transition & 0xFF
    counts["reload"] += core == 8
    counts["subframe"] += core in (3, 4)
    counts["auto_toplevel"] += core == 6
    counts["redirect"] += bool(transition & 0xC0000000)


def chrome_checks(references, samples, start, end, day_of, days, failures, diagnostics, signals=None):
    with workspace() as work:
        return chrome_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work, signals)


def chrome_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work, signals=None):
    attribution = TimeIndex(work, 'chrome_attribution')
    limits = InputLimits(day_of, days)
    for row in samples:
        key = url_digest(row["document_key"])
        if key:
            attribution.add(key, row['ts'])
    counts = defaultdict(lambda: [0, 0])
    transitions = defaultdict(visit_transition_counts)
    seen = set()
    unavailable = 0
    for history in references.chrome_histories:
        identity = Path(history).absolute()
        if identity in seen:
            continue
        seen.add(identity)
        failed_before = unavailable
        try:
            with chrome_snapshot(history) as chrome:
                schema = Schema(chrome)
                if not schema.has("visits", "url", "visit_time") or not schema.has("urls", "id", "url"):
                    raise ValueError()
                # Chrome uses microseconds since 1601; retain fractional seconds.
                columns = {'url': 'urls.url', 'visit_time': 'visits.visit_time'}
                if schema.has("visits", "transition"):
                    columns['transition'] = 'visits.transition'
                projection = bounded_columns(columns)
                rows = chrome.execute(f"""SELECT {projection} FROM visits
                    JOIN urls ON urls.id=visits.url WHERE visits.visit_time>=? AND visits.visit_time<?""",
                    ((start + 11644473600) * 1000000, (end + 11644473600) * 1000000))
                for row in rows:
                    row = bounded_row(row, list(columns))
                    stamp = (row["visit_time"] - 11644473600 * 1000000) / 1000000
                    if day_of(stamp) not in days:
                        continue
                    counts[day_of(stamp)][1] += 1
                    count_visit_transition(transitions[day_of(stamp)], row.get("transition"))
                    if signals is not None:
                        signals.add("chrome_visit", stamp)
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
        if signals is not None:
            signals.input_read("chrome_visit", str(identity), unavailable == failed_before)
    if unavailable:
        diagnostics["unreadable_chrome_histories"] += unavailable
    if signals is not None:
        signals.visit_transitions.update((day, transitions[day]) for day in days)
    reason = ("channel absent: Chrome history input not supplied" if not references.chrome_histories else
              "partial: Chrome histories unreadable or unsupported" if unavailable else None)
    output = [dict(measure("C6", "chrome_visits_attributed", day,
                         counts[day][0] if references.chrome_histories else None,
                         counts[day][1] if references.chrome_histories else None, reason=reason),
                 tolerance_seconds=references.tolerance, histories_unreadable=unavailable, histories_readable=len(seen) - unavailable,
                 visit_transitions=transitions[day]) for day in days]
    for row in output:
        limits.apply(row, ['chrome'])
    return output


# Tool output in these folders changes without a person touching a document.
FILE_EXCLUDED_DIRS = frozenset((".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".codex", ".claude", "Keychains",
                                "node_modules", ".build", "DerivedData", "__pycache__", ".venv"))


NO_FILE_DOCUMENTS = ("no app in this window reports file documents: every document key is a web address or an app's "
                     "own name, so C7 cannot measure here")


class KnownFiles:
    """Files a person had open in the window, each asked about once. No folder is ever walked,
    so the cost follows the window and files nobody opened cannot enter the denominator."""
    def __init__(self, work, samples, start, end, day_of, days, diagnostics):
        self.work, self.errors, self.known, self.keys_seen, self.keys_not_a_path = work, 0, 0, 0, 0
        # Paths live solely in this private, disposable store.
        work.executescript("""CREATE TABLE file_documents(key TEXT PRIMARY KEY,identity TEXT);
            CREATE TABLE file_identities(identity TEXT PRIMARY KEY);
            CREATE TABLE file_mtimes(identity TEXT PRIMARY KEY,day TEXT,ts REAL);
            CREATE INDEX file_mtime_day ON file_mtimes(day);""")
        for row in samples:
            value = row["document_key"]
            if not start <= row["ts"] < end or not value:
                continue
            if work.execute("SELECT 1 FROM file_documents WHERE key=?", (value,)).fetchone():
                continue
            path = document_path(value)
            self.keys_seen += 1
            self.keys_not_a_path += path is None
            identity = self._ask(path, start, end, day_of, days, diagnostics)
            work.execute("INSERT INTO file_documents VALUES(?,?)", (value, identity))
            Progress.tick("document files", self.known)
        diagnostics["file_metadata_errors"] += self.errors

    def _ask(self, path, start, end, day_of, days, diagnostics):
        if path is None:
            return None
        try:
            # The same file can be named through a symlink and in either Unicode form.
            if any(part in FILE_EXCLUDED_DIRS for part in path.parts):
                diagnostics["document_paths_excluded"] += 1
                return None
            real = os.path.realpath(path)
            if any(part in FILE_EXCLUDED_DIRS for part in Path(real).parts):
                diagnostics["document_paths_excluded"] += 1
                return None
            info = os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            diagnostics["known_document_paths_unavailable"] += 1
            return None
        except (OSError, ValueError):
            self.errors += 1
            return None
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            diagnostics["document_paths_not_regular_files"] += 1
            return None
        if real != str(path):
            diagnostics["document_paths_through_symlink"] += 1
        identity = digest(unicodedata.normalize("NFC", real))
        if self.work.execute("INSERT OR IGNORE INTO file_identities VALUES(?)", (identity,)).rowcount:
            self.known += 1
            stamp = info.st_mtime
            if start <= stamp < end and day_of(stamp) in days:
                self.work.execute("INSERT INTO file_mtimes VALUES(?,?,?)", (identity, day_of(stamp), stamp))
        return identity

    def identity(self, value):
        row = self.work.execute("SELECT identity FROM file_documents WHERE key=?", (value,)).fetchone()
        return row[0] if row else None


def file_checks(samples, day_of, days, references, diagnostics, population):
    """Not ranked: an agent can write a file the person had open, and the two look the same here."""
    attribution = TimeIndex(population.work, 'file_attribution')
    for row in samples:
        identity = population.identity(row["document_key"])
        if identity is not None:
            attribution.add(identity, row['ts'])
    output = []
    reason = (NO_FILE_DOCUMENTS if population.keys_seen and population.keys_seen == population.keys_not_a_path else
              "no known documents: no sample in the window has a document key naming a usable file" if not population.known else
              "partial: file metadata unavailable" if population.errors else None)
    for day in days:
        matched = total = 0
        for identity, stamp in population.work.execute("SELECT identity,ts FROM file_mtimes WHERE day=?", (day,)):
            total += 1
            found = attribution.near(identity, stamp, references.tolerance)
            matched += found
            if not found:
                diagnostics["open_document_changes_without_attribution"] += 1
        output.append(dict(measure("C7", "open_document_changes_attributed", day, matched, total, reason=reason),
                           tolerance_seconds=references.tolerance, documents_known=population.known,
                           document_keys_seen=population.keys_seen, document_keys_not_a_path=population.keys_not_a_path,
                           latest_mtime_only=True, metadata_errors=population.errors, ranked=False))
    return output


MAX_HISTORY_LINE = 64 * 1024


def shell_lines(stream):
    return bounded_records(stream, MAX_HISTORY_LINE)


def shell_checks(references, samples, start, end, day_of, days, failures, diagnostics, signals=None):
    with workspace() as work:
        return shell_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work, signals)


def shell_checks_indexed(references, samples, start, end, day_of, days, failures, diagnostics, work, signals=None):
    terminals = TERMINAL_BUNDLES | set(references.terminal_apps)
    key_times = TimeIndex(work, 'shell_attribution')
    for r in samples:
        if person_amount(r, 'keys') > 0 and (r['bundle_id'] in terminals or r['app'] in terminals or r.get('app_type') == 'terminal'):
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
        failed_before = unavailable
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
                        if signals is not None:
                            signals.add("shell_history", stamp)
                        found = key_times.near('', stamp, references.tolerance)
                        count[0] += found
                        if not found:
                            failures["shell_commands_without_terminal_keys"] += 1
        except OSError:
            unavailable += 1
        if signals is not None:
            signals.input_read("shell_history", str(path), unavailable == failed_before)
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
    return mask_labelled(product_helper().apply(str(value)))


def mask_labelled(value):
    """The rules added on top of the product's. Stored text has already had the product's."""
    value = re.sub(r"(?i)(?:password|passwd|passphrase|passcode|secret(?:[_ -]key)?|api[_ -]?key|token|cookie)[\"']?\s*[:=：]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)",
                   "[secret]", value)
    # Export also hides complete authorization payloads, including Basic schemes.
    return re.sub(r"(?i)\b(?:authorization\s*[:=]\s*(?:basic|bearer)\s+|bearer\s+)[^\s\"']+",
                  "[secret]", value)


# Columns that hold real numbers: our tables' number columns, the reference's and a bundle's own.
# SQLite stores a card number as an integer in a text-like column with number affinity, so a
# number anywhere else gets the same mask as text.
NUMERIC_COLUMNS = frozenset(("id", "ts", "keys", "clicks", "scrolls", "moved", "synthetic", "keeping_awake", "excluded", "observed_ts",
                             "device", "inode", "byte_offset", "timestamp_known", "byte_count", "payload_id",
                             "repo_id", "author_ts", "complete",
                             "timestamp", "focused", "monitor_id", "timestamp_seconds",
                             "bundle_version", "seed", "start_ts", "end_ts", "our_samples_within_1s"))


def masked_tree(value, from_text=False, column=None):
    """`from_text`: this value was parsed out of a text field, so even a number under a known
    column's name was once text. `column`: the key this value sits under."""
    if isinstance(value, str):
        if value.lstrip().startswith(("{", "[")):
            try:
                structured = json.loads(value)
                if isinstance(structured, (dict, list)):
                    return masked_tree(structured, True)
            except ValueError:
                pass
        return mask(value)
    if isinstance(value, bytes):
        return {"blob_length": len(value), "blob_digest": hashlib.sha256(value).hexdigest()}
    if isinstance(value, dict):
        return {mask(k): "[redacted]" if re.search(r"(?i)(?:password|passwd|passphrase|passcode|token|secret|api[_-]?key|authorization|cookie)", str(k))
                else masked_tree(v, from_text, k) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [masked_tree(v, from_text, column) for v in value]
    if isinstance(value, (int, float)) and not isinstance(value, bool) and (from_text or column not in NUMERIC_COLUMNS):
        text = json.dumps(value)
        hidden = mask(text)
        return value if hidden == text else hidden
    return value


def informative_terms(value, stats=None, stored_masked=False):
    masked = mask_labelled(str(value)) if stored_masked else mask(value)
    normalized = unicodedata.normalize("NFKC", masked).casefold().replace("[redacted]", " ").replace("[secret]", " ").replace("[email]", " ")
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


# Identifiers inside stored text, which are not words anyone read.
HASH_LIKE = re.compile(r"\b(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{16,}|[A-Za-z0-9+_=-]{40,})\b")
# Fields the log reader keeps to describe a line rather than to hold its words.
AGENT_LOG_METADATA = frozenset((
    "type", "timestamp", "role", "uuid", "commandUuid", "source_uuid", "parentUuid", "isMeta", "isCompactSummary",
    "isVisibleInTranscriptOnly", "isSidechain", "thread_id", "turn_id", "id", "kind", "subagent", "reason", "origin",
    "source", "thread_source", "parent_thread_id", "promptSource", "humanTurn", "commandMode", "scheduledTaskId",
    "scheduledFireId", "operation", "tool_use_id", "call_id", "name", "sessionId", "signature"))


def without_identifiers(text):
    return HASH_LIKE.sub(" ", text)


def agent_values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for child in value:
            yield from agent_values(child)
    elif isinstance(value, dict):
        for key, child in value.items():
            if key not in AGENT_LOG_METADATA:
                yield from agent_values(child)


def agent_log_text(payload):
    """The words of one stored log line: its values without keys, line metadata or identifiers."""
    try:
        parsed = json.loads(payload)
    except (ValueError, TypeError):
        return without_identifiers(str(payload))  # Unparsed lines are stored as masked plain text.
    return without_identifiers("\n".join(agent_values(parsed)))


def ax_blob(db, attempt, identity):
    """One stored blob, read only through its attempt's own reference. None when too large."""
    parts, size = [], 0
    for (chunk,) in db.execute("SELECT " + guarded_text('substr', 'c.text', 1, MAX_TEXT_FIELD) + """ FROM ax_probe_chunks c
            JOIN ax_probe_refs r ON r.hash=c.hash AND r.attempt_row=? WHERE c.hash=? ORDER BY c.ordinal""", (attempt, identity)):
        size += len(chunk or '')
        if chunk is None or size > MAX_RECORD:
            return None
        parts.append(chunk)
    return "".join(parts)


def ax_attempt_text(db, row, stats):
    """What the accessibility tree said: attribute text only. The stored tree is JSON whose keys
    and content hashes are structure, and attribute and role names are not on the screen."""
    try:
        header = json.loads(row["payload"])
    except ValueError:
        stats["unreadable_attempts"] += 1
        return ""
    if not isinstance(header, dict) or (header.get("ax") or {}).get("status") == "pending":
        return ""
    references, inline = [], []
    if header.get("axTextRef"):
        references.append(header["axTextRef"])
    for (identity,) in db.execute("SELECT hash FROM ax_probe_parts WHERE attempt_row=? ORDER BY ordinal", (row["id"],)):
        part = ax_blob(db, row["id"], identity)
        try:
            nodes = json.loads(part) if part is not None else None
        except ValueError:
            nodes = None
        if nodes is None:
            stats["unreadable_attempts"] += 1
            continue
        for node in nodes:
            for attribute in node.get("attributes", ()):
                if attribute.get("textRef"):
                    references.append(attribute["textRef"])
                elif attribute.get("text"):
                    inline.append(attribute["text"])  # Attempts stored before content moved to blobs.
    size, texts = sum(map(len, inline)), inline
    for identity in dict.fromkeys(references):
        text = ax_blob(db, row["id"], identity)
        if text is None or size + len(text) > MAX_RECORD:
            stats["oversized_fields"] += 1
            continue
        size += len(text)
        texts.append(text)
    return without_identifiers("\n".join(texts))


class TermWindow:
    """The terms of one text channel in the frame's moving window. Each row is added and removed
    once, so a frame costs its own terms, not its neighbours' text. Same rule as recalled_identities."""
    def __init__(self, rows, terms):
        self.rows, self.terms = rows, terms
        self.current, self.counts = deque(), Counter()
        self.same, self.substitutions, self.longer_by_one = Counter(), Counter(), Counter()
        self.pending = next(rows, None)

    @staticmethod
    def _bump(counter, key, amount):
        counter[key] += amount
        if not counter[key]:
            del counter[key]

    def _change(self, numbers, amount):
        for number in numbers:
            self._bump(self.counts, number, amount)
            if self.counts[number] == (1 if amount > 0 else 0):
                identity, length, drops = self.terms(number)
                self._bump(self.same, identity, amount)
                if length >= 4:
                    for position, value in enumerate(drops):
                        self._bump(self.substitutions, (length, position, value), amount)
                        self._bump(self.longer_by_one, (length - 1, value), amount)

    def advance(self, stamp, tolerance):
        while self.pending is not None and self.pending[0] <= stamp + tolerance:
            if self.pending[0] >= stamp - tolerance:
                numbers = json.loads(self.pending[1])
                self.current.append((self.pending[0], numbers))
                self._change(numbers, 1)
            self.pending = next(self.rows, None)
        while self.current and self.current[0][0] < stamp - tolerance:
            self._change(self.current.popleft()[1], -1)

    def has(self, identity, length, drops):
        if identity in self.same:
            return True
        return length >= 5 and ((length, identity) in self.longer_by_one or any(
            value in self.same or (length, position, value) in self.substitutions
            for position, value in enumerate(drops)))


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


class CloneUnavailable(OSError):
    """The input cannot be cloned here. A real copy of a large database is never the fallback."""


def clone_file(source, target):
    try:
        clone = ctypes.CDLL(None, use_errno=True).clonefile
    except (OSError, AttributeError):
        raise CloneUnavailable(errno.ENOTSUP, "clone unavailable") from None
    if clone(os.fsencode(str(source)), os.fsencode(str(target)), 0) != 0:
        code = ctypes.get_errno()
        kind = CloneUnavailable if code in (errno.EXDEV, errno.ENOTSUP) else OSError
        raise kind(code, "clone failed")


def wal_salt(path):
    """Identifies one generation of a write-ahead log; a restart changes it."""
    try:
        with open(path, 'rb') as stream:
            header = stream.read(32)
    except FileNotFoundError:
        return None
    return header[16:24] if len(header) == 32 else None


def file_state(*paths):
    """Size and modification time of each file, or None for one that is not there."""
    states = []
    for path in paths:
        try:
            info = os.stat(path)
            states.append((info.st_size, info.st_mtime_ns))
        except FileNotFoundError:
            states.append(None)
    return states


@contextmanager
def private_clone(database, attempts=3):
    """An APFS clone in a private folder, deleted on success, failure and interrupt.

    Nothing is written next to the source and none of its locks are needed. A clone
    costs no blocks until the source changes. The main file goes first: its log still
    holds every page it could be missing, unless the log restarted between the two
    clones, which the salt check catches. A database with no log has no such pages, so
    its main file and journal must be unchanged across the clone, or it is taken again.
    Log text and the clone stay in this folder.
    """
    database = Path(database).absolute()
    with tempfile.TemporaryDirectory(prefix="fidelity-clone-") as folder:
        target = Path(folder) / "clone.sqlite"
        log, journal = Path(str(database) + "-wal"), Path(str(database) + "-journal")
        for attempt in range(attempts):
            for leftover in Path(folder).iterdir():
                leftover.unlink()
            before, unchanged = wal_salt(log), file_state(database, log, journal)
            clone_file(database, target)
            for source, suffix in ((log, "-wal"), (journal, "-journal")):
                if source.exists():
                    clone_file(source, str(target) + suffix)
            stable = log.exists() or file_state(database, log, journal) == unchanged
            if stable and wal_salt(str(target) + "-wal") == before:
                break
            time.sleep(.05 * (attempt + 1))
        else:
            raise OSError(errno.EAGAIN, "source changed during every clone")
        for item in Path(folder).iterdir():
            item.chmod(0o600)
        if Path(str(target) + "-journal").exists():
            # A rollback in progress at clone time can only be undone by writing, here to the clone.
            with closing(sqlite3.connect(target)) as copy:
                copy.execute("SELECT name FROM sqlite_master LIMIT 1").fetchone()
        yield target


def open_clone(path):
    """A read-only connection to a private clone, and the stack that removes both.
    Nothing stays behind a failed open, whatever interrupted it."""
    stack = ExitStack()
    try:
        return stack, stack.enter_context(readonly(stack.enter_context(private_clone(path))))
    except BaseException:
        stack.close()
        raise


@contextmanager
def reference_snapshot(path):
    # A live recorder can hold its lock for as long as it likes, so its file is never opened.
    for attempt in range(3):
        try:
            stack, db = open_clone(path)
        except CloneUnavailable:
            raise
        except (sqlite3.Error, OSError):
            if attempt == 2:
                raise
            time.sleep(.05 * (attempt + 1))
            continue
        with stack:
            yield db
        return


@contextmanager
def primary_snapshot(path, private_copy=False):
    # A read-only open of a WAL database leaves side files beside it, so the file is opened where
    # it lies only when the person says this path is a private copy. The tool cannot tell.
    try:
        stack, db = open_clone(path)
    except CloneUnavailable:
        if not private_copy:
            raise
        stack = ExitStack()
        db = stack.enter_context(readonly(path))
    with stack:
        yield db


@contextmanager
def chrome_snapshot(path):
    """A browser's history is small, so on another volume a private byte copy stands in for a clone.
    The profile itself is never opened, so nothing appears beside it."""
    try:
        stack, db = open_clone(path)
    except CloneUnavailable:
        stack = None
    if stack is not None:
        with stack:
            yield db
        return
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


def timestamp_index_name(db, table, column):
    """A whole-table index that starts with this column, or None."""
    for row in db.execute('PRAGMA index_list(' + quoted(table) + ')').fetchall():
        first = db.execute('PRAGMA index_info(' + quoted(row[1]) + ')').fetchone()
        if not row[4] and first is not None and first[2] == column:
            return row[1]
    return None


def timestamp_index(db, table, column, work, start, end):
    """Rowids and numeric times of the selected window, in private state, so that repeated
    reads for one bundle neither rescan text timestamps nor touch the source's other rows."""
    name = 'bounded_time_' + digest(str(id(db)) + ':' + table + ':' + column)[:16]
    if not work.execute("SELECT 1 FROM sqlite_master WHERE name=?", (name,)).fetchone():
        work.execute('CREATE TABLE ' + quoted(name) + '(record INTEGER PRIMARY KEY,ts REAL)')
        for row in windowed_source_rows(db, table, ['rowid', column], column, start, end):
            work.execute('INSERT OR IGNORE INTO ' + quoted(name) + ' VALUES(?,?)', (row['rowid'], reference_time(row[column])))
        work.execute('CREATE INDEX ' + quoted(name + '_ts') + ' ON ' + quoted(name) + '(ts)')
    return quoted(name)


def window_candidates(db, table, names, column, start, end):
    """Seek the source's own time index for both timestamp encodings, then retrieve bounded rows."""
    sizes = real_text_sizes(db, table)
    index = timestamp_index_name(db, table, column)
    name = quoted(column)
    source = quoted(table) + (' INDEXED BY ' + quoted(index) if index else ' NOT INDEXED')
    query = 'SELECT ' + bounded_columns(names, sizes) + ' FROM ' + source + ' WHERE ' + name + '>=? AND ' + name + '<?'
    # Text timestamps sort by their own offset, so bound them generously by date, then exactly.
    lo = datetime.fromtimestamp(start - 14 * 3600, timezone.utc).date().isoformat()
    hi = (datetime.fromtimestamp(end + 14 * 3600, timezone.utc).date() + timedelta(days=1)).isoformat()
    for low, high in ((start, end), (lo, hi)):
        for raw in db.execute(query, (low, high)):
            yield bounded_row(raw, names)


def windowed_source_rows(db, table, names, column, start, end):
    for row in window_candidates(db, table, names, column, start, end):
        stamp = reference_time(row[column])
        if stamp is not None and start <= stamp < end:
            yield row


def time_rows(db, table, columns, column, start, end, work=None, bounds=None):
    """Bound both supported timestamp encodings before retrieving any text."""
    names = sorted(Schema(db).columns(table)) if columns == '*' else columns
    if work is None:
        yield from windowed_source_rows(db, table, names, column, start, end)
        return
    sizes = real_text_sizes(db, table)
    query = 'SELECT ' + bounded_columns(names, sizes) + ' FROM ' + quoted(table) + ' NOT INDEXED WHERE rowid=?'
    index = timestamp_index(db, table, column, work, *(bounds or (start, end)))
    for (record,) in work.execute('SELECT record FROM ' + index + ' WHERE ts>=? AND ts<? ORDER BY record', (start, end)):
        raw = db.execute(query, (record,)).fetchone()
        if raw is not None:
            yield bounded_row(raw, names)


def reference_rows(db, table, start, end, days=None, day_of=None, diagnostics=None, text=True, work=None, bounds=None):
    schema = Schema(db)
    # Without a time index, the only way to the window is a full scan, which is never done.
    if not schema.has(table, "timestamp") or timestamp_index_name(db, table, "timestamp") is None:
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
        for row in time_rows(db, table, columns, "timestamp", low, high, work, bounds):
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
        return type(self)(self.db, self.table, start, end, self.condition, self.parameters)


class EvidenceRows(QueryRows):
    """Evidence as summaries read it: screen text lives in a blob, and `evidence.text` is empty."""
    def __iter__(self):
        schema = Schema(self.db)
        if not (schema.has("screen_payloads", "evidence_id", "text_hash") and schema.has("collection_blobs", "hash", "content")):
            yield from super().__iter__()
            return
        columns = {name: 'e.' + quoted(name) for name in sorted(schema.columns("evidence"))}
        columns["__blob_text"] = "b.content"
        names = list(columns)
        query = ('SELECT ' + bounded_columns(columns) + ',b.hash IS NOT NULL AS __has_blob FROM evidence e '
                 'LEFT JOIN screen_payloads p ON p.evidence_id=e.id LEFT JOIN collection_blobs b ON b.hash=p.text_hash '
                 'WHERE e.ts>=? AND e.ts<? AND ' + self.condition)
        for raw in self.db.execute(query, (self.start, self.end, *self.parameters)):
            row = bounded_row(raw, names)
            blob = row.pop("__blob_text")
            if raw[-1]:
                row["text"] = blob
            fields = [("text" if name == "__blob_text" else name) for name in row.get("_oversized_fields", ())
                      if raw[-1] or name != "__blob_text"]
            if fields:
                row["_oversized_fields"] = fields
            else:
                row.pop("_oversized_fields", None)
            yield row


class ReferenceFrames:
    def __init__(self, db, start, end, days, day_of, work):
        self.db, self.start, self.end, self.days, self.day_of = db, start, end, days, day_of
        self.work = work

    def __iter__(self):
        return reference_rows(self.db, "frames", self.start, self.end, self.days, self.day_of, text=False, work=self.work,
                              bounds=(self.start, self.end))

    def between(self, start, end):
        return reference_rows(self.db, "frames", start, end, self.days, self.day_of, work=self.work,
                              bounds=(self.start, self.end))


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
    def __init__(self, db, work, limits, start, end):
        self.work = work
        work.execute('CREATE TABLE evidence_apps(source TEXT,ts REAL,app TEXT,PRIMARY KEY(source,ts,app)) WITHOUT ROWID')
        if not Schema(db).has('samples', 'ts', 'app', 'bundle_id'):
            return
        # One bounded pass over the window; only opaque identities and timestamps spill.
        for row in bounded_rows(db, 'samples', 'ts>=? AND ts<?', (start - 60 - APP_NAME_LOOKBACK, end + 60),
                                columns=['ts', 'bundle_id', 'app']):
            # A predecessor outside the selected days can affect any later day.
            limits.audit('evidence_apps', [dict(row, ts=None)])
            source, app, stamp = normalized(row['bundle_id']), normalized(row['app']), reference_time(row['ts'])
            if not source or stamp is None or 'bundle_id' in row.get('_oversized_fields', ()):
                continue
            work.execute('INSERT OR IGNORE INTO evidence_apps VALUES(?,?,?)',
                         (digest(source), stamp, digest(app) if app else ''))

    def at(self, source, stamp):
        return self.at_identity(digest(normalized(source)), stamp)

    def at_identity(self, identity, stamp):
        # Two rows suffice to detect conflicting names at the latest timestamp.
        # Never use a future observation or pick an arbitrary same-time alias.
        rows = self.work.execute('SELECT ts,app FROM evidence_apps WHERE source=? AND ts<=? ORDER BY ts DESC,app DESC LIMIT 2',
                                 (identity, stamp)).fetchall()
        if not rows or not rows[0][1] or (len(rows) == 2 and rows[0][0] == rows[1][0]):
            return identity  # Unmapped/direct app-name sources retain their own identity.
        return rows[0][1]


# Metric suffix per C10 text channel. The plain name stays stored screen text, what summaries read.
TEXT_CHANNELS = {"screen": "", "ax_probe": "_ax_probe", "agent_log": "_agent_log", "all": "_all"}
RECALL_TOLERANCE = 60


def load_own_text(ours, own_schema, start, end, evidence, evidence_apps, affected, term_limits, work):
    """Every channel's text around the window, as term numbers, one record at a time."""
    counts = Counter()
    def store(channel, app, stamp, words, stats):
        encoded = intern_terms(work, words)[0]
        for day in affected.affected_days(stamp, RECALL_TOLERANCE):
            term_limits[(day, channel)].update(stats)
        work.execute("INSERT INTO texts VALUES(?,?,?,?)", (channel, app, stamp, encoded))
        counts[channel] += 1
    for row in evidence:
        if row["kind"] == "screen":
            stats = Counter()
            store("screen", evidence_apps.at(row["source"], row["ts"]), row["ts"], informative_terms(row["text"], stats), stats)
    Progress.stage("C10 screen text read")
    if own_schema.has("ax_probe_attempts", "id", "ts", "mapping_key", "payload") and own_schema.has("ax_probe_parts", "attempt_row", "hash") \
            and own_schema.has("ax_probe_chunks", "hash", "text") and own_schema.has("ax_probe_refs", "attempt_row", "hash"):
        for row in bounded_rows(ours, "ax_probe_attempts", "ts>=? AND ts<?", (start - RECALL_TOLERANCE, end + RECALL_TOLERANCE),
                                columns=["id", "ts", "mapping_key", "payload"]):
            stats = Counter()
            text = ax_attempt_text(ours, row, stats)
            if text.strip():
                # mapping_key is the product's hash of the lowercased bundle ID, the same value as this identity.
                store("ax_probe", evidence_apps.at_identity(row["mapping_key"], row["ts"]), row["ts"],
                      informative_terms(text, stats, stored_masked=True), stats)
                Progress.tick("C10 accessibility text", counts["ax_probe"])
    Progress.stage("C10 accessibility text read")
    if own_schema.has("agent_log_events", "ts", "payload_id") and own_schema.has("agent_log_payloads", "id", "payload"):
        # Logs repeat a line's payload rarely, but when they do its terms are not worked out twice.
        @lru_cache(maxsize=1024)
        def known(identity, text):
            stats = Counter()
            return informative_terms(agent_log_text(text), stats, stored_masked=True), stats
        columns = {"ts": "e.ts", "payload_id": "e.payload_id", "payload": "p.payload"}
        query = ("SELECT " + bounded_columns(columns) + """ FROM agent_log_events e
            JOIN agent_log_payloads p ON p.id=e.payload_id WHERE e.ts>=? AND e.ts<?""")
        for raw in ours.execute(query, (start - RECALL_TOLERANCE, end + RECALL_TOLERANCE)):
            row = bounded_row(raw, list(columns))
            words, stats = known(row["payload_id"], row["payload"])
            # A log line names no app, so this channel is compared with every frame.
            store("agent_log", "", row["ts"], words, stats)
            Progress.tick("C10 agent log text", counts["agent_log"])
    Progress.stage("C10 agent log text read")
    return counts


def reference_checks(ours, reference, samples, start, end, day_of, days, failures, options, diagnostics=None, work=None, evidence_apps=None, signals=None):
    absent = "channel absent: reference recorder input not supplied"
    if reference is None:
        return [measure(check, metric, day, reason=absent) for day in days for check, metric in
                (("C9", "reference_frames_attributed"),
                 *(("C10", metric + TEXT_CHANNELS[channel]) for channel in TEXT_CHANNELS
                   for metric in ("informative_term_weighted_recall", "informative_term_unweighted_recall")),
                 ("C11", "reference_input_observed"))], [], [], []
    schema, own_schema = Schema(reference), Schema(ours)
    frames = ReferenceFrames(reference, start, end, days, day_of, work)
    frame_indexed = bool(schema.has("frames", "timestamp") and timestamp_index_name(reference, "frames", "timestamp"))
    input_indexed = bool(schema.has("ui_events", "timestamp") and timestamp_index_name(reference, "ui_events", "timestamp"))
    frame_channel = frame_indexed and schema.has("frames", "focused", "app_name", "window_name")
    input_channel = input_indexed and schema.has("ui_events", "event_type", "app_name")
    no_index = "unsupported schema: reference timestamp index required, and a full scan is never done"
    own_samples = own_schema.has("samples", "ts", "app", "window", "document_key", "keys", "clicks", "scrolls")
    evidence_available = own_schema.has("evidence", "ts", "kind", "source", "text")
    evidence = EvidenceRows(ours, "evidence", start - RECALL_TOLERANCE, end + RECALL_TOLERANCE) if evidence_available else []
    work.executescript("""
        CREATE TABLE lexicon(id INTEGER PRIMARY KEY, identity TEXT UNIQUE, signature TEXT);
        CREATE TABLE terms(day TEXT, app TEXT, ts REAL, words TEXT);
        CREATE TABLE frequency(day TEXT, word TEXT, n INTEGER, PRIMARY KEY(day,word));
        CREATE TABLE texts(channel TEXT, app TEXT, ts REAL, words TEXT);
        CREATE INDEX texts_time ON texts(channel,app,ts);
        CREATE TABLE clicks(app TEXT, ts INTEGER, capacity INTEGER, PRIMARY KEY(app,ts));
        CREATE TABLE events(identity TEXT PRIMARY KEY, ts REAL, payload TEXT);
        CREATE TABLE recall(day TEXT,app TEXT,channel TEXT,weighted_found REAL,weighted_total REAL,found INTEGER,total INTEGER,
            PRIMARY KEY(day,app,channel));
    """)
    term_limits = defaultdict(Counter)
    affected = InputLimits(day_of, days)
    text_rows = load_own_text(ours, own_schema, start, end, evidence, evidence_apps, affected, term_limits, work)
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
        encoded, words = intern_terms(work, informative_terms(frame_text(frame), term_limits[(day, "reference")]))
        frame_counts[day] += 1
        work.execute("INSERT INTO terms VALUES(?,?,?,?)", (day, digest(app_name) if app_name else "", frame["timestamp_seconds"], encoded))
        work.executemany("INSERT INTO frequency VALUES(?,?,1) ON CONFLICT(day,word) DO UPDATE SET n=n+1",
                         ((day, word) for word in words))
    event_names = {"click": "click", "mouse_click": "click", "mouseclick": "click",
                   "window_focus": "window_focus", "windowfocus": "window_focus", "focus": "window_focus",
                   "app_switch": "app_switch", "appswitch": "app_switch", "application_switch": "app_switch"}
    for event in reference_rows(reference, "ui_events", start, end, days, day_of, diagnostics, work=work):
        if signals is not None and normalized(event.get("event_type")).replace("-", "_") in REFERENCE_PERSON_EVENTS:
            signals.add("reference_input", event["timestamp_seconds"])
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
    Progress.stage("C10 recall")
    @lru_cache(maxsize=8192)
    def term(number):
        identity, signature = work.execute("SELECT identity,signature FROM lexicon WHERE id=?", (number,)).fetchone()
        length, drops = json.loads(signature)
        return identity, length, tuple(drops)
    @lru_cache(maxsize=65536)
    def term_weight(day, identity):
        frequency = work.execute("SELECT n FROM frequency WHERE day=? AND word=?", (day, identity)).fetchone()[0]
        return math.log(frame_counts[day] / frequency)
    windows, group = {}, None
    for number, (day, app, stamp, encoded) in enumerate(work.execute("SELECT day,app,ts,words FROM terms ORDER BY day,app,ts")):
        if group != (day, app):
            group = (day, app)
            windows = {}
            for channel in ("screen", "ax_probe"):
                if app:
                    windows[channel] = TermWindow(iter(work.execute(
                        "SELECT ts,words FROM texts WHERE channel=? AND app=? AND ts>=? ORDER BY ts",
                        (channel, app, stamp - RECALL_TOLERANCE))), term)
            windows["agent_log"] = TermWindow(iter(work.execute(
                "SELECT ts,words FROM texts WHERE channel='agent_log' AND ts>=? ORDER BY ts",
                (stamp - RECALL_TOLERANCE,))), term)
        for window in windows.values():
            window.advance(stamp, RECALL_TOLERANCE)
        count = {channel: [0., 0., 0, 0] for channel in TEXT_CHANNELS}
        for word in json.loads(encoded):
            identity, length, drops = term(word)
            weight = term_weight(day, identity)
            hits = {channel for channel, window in windows.items() if window.has(identity, length, drops)}
            if hits:
                hits.add("all")
            for channel, values in count.items():
                values[1] += weight
                values[3] += 1
                if channel in hits:
                    values[0] += weight
                    values[2] += 1
            if "screen" not in hits and evidence_available and weight > 0:
                failures["reference_informative_terms_missing"] += 1
        for channel, values in count.items():
            work.execute('''INSERT INTO recall VALUES(?,?,?,?,?,?,?) ON CONFLICT(day,app,channel) DO UPDATE SET
                weighted_found=weighted_found+excluded.weighted_found,weighted_total=weighted_total+excluded.weighted_total,
                found=found+excluded.found,total=total+excluded.total''', (day, app or digest(''), channel, *values))
        Progress.tick("C10 recall frames", number + 1)
    output = []
    for day in days:
        reason = (no_index if schema.has("frames", "timestamp") and not frame_indexed else
                  "channel absent: reference frames" if not frame_channel else
                  "channel absent: samples" if not own_samples else None)
        row = measure("C9", "reference_frames_attributed", day, *attribution[day], reason=reason)
        if reason:
            row.update(numerator=None, ratio=None)
        row["disagreements"] = dict(disagreements[day])
        output.append(row)
        for channel, suffix in TEXT_CHANNELS.items():
            groups = work.execute('SELECT count(*) FROM recall WHERE day=? AND channel=?', (day, channel)).fetchone()[0]
            app_rows = [(row[0], row[1:], 1) for row in work.execute(
                'SELECT app,weighted_found,weighted_total,found,total FROM recall WHERE day=? AND channel=? ORDER BY app LIMIT ?',
                (day, channel, MAX_APP_GROUPS))]
            if groups > MAX_APP_GROUPS:
                overflow = work.execute('''SELECT sum(weighted_found),sum(weighted_total),sum(found),sum(total) FROM recall
                    WHERE day=? AND channel=? AND app NOT IN (SELECT app FROM recall WHERE day=? AND channel=? ORDER BY app LIMIT ?)''',
                    (day, channel, day, channel, MAX_APP_GROUPS)).fetchone()
                app_rows.append((digest('aggregated app groups'), overflow, groups - MAX_APP_GROUPS))
            if not app_rows:
                app_rows = [(None, [0., 0., 0, 0], 0)]
            limits_here = Counter(term_limits[(day, "reference")])
            for source in (TEXT_CHANNELS if channel == "all" else (channel,)):
                limits_here.update(term_limits[(day, source)])
            for app_id, count, combined in app_rows:
                reason = (no_index if schema.has("frames", "timestamp") and not frame_indexed else
                          "channel absent: reference screen text" if not frame_channel or not (
                              schema.has("frames", "full_text") or schema.has("frames", "accessibility_text")) else
                          "channel absent: screen evidence" if channel == "screen" and not own_schema.has("evidence", "ts", "kind", "source", "text") else
                          None)
                empty = channel != "all" and not reason and not text_rows[channel]
                for metric, values in (("informative_term_weighted_recall", count[:2]), ("informative_term_unweighted_recall", count[2:])):
                    row = measure("C10", metric + suffix, day, *values, reason=reason or (f"no {channel} text in this window" if empty else None))
                    row.update(app_id=app_id, tolerance_seconds=RECALL_TOLERANCE, weighting="log_inverse_frame_frequency",
                               text_source=channel, text_rows=sum(text_rows.values()) if channel == "all" else text_rows[channel],
                               app_matched=channel != "agent_log")
                    row.update(app_group_count=combined)
                    row.update(limits_here)
                    if limits_here:
                        note = 'partial: exact-only or unsupported terms'
                        row.update(partial_input=True, reason=row['reason'] + '; ' + note if row['reason'] else note)
                    if reason:
                        row.update(numerator=None, ratio=None)
                    output.append(row)
        for kind in ("click", "window_focus", "app_switch"):
            reason = (no_index if schema.has("ui_events", "timestamp") and not input_indexed else
                      "channel absent: reference input events" if not input_channel else
                      "channel absent: samples" if not own_samples else None)
            row = measure("C11", "reference_input_observed", day, *inputs[(day, kind)], reason=reason)
            if reason:
                row.update(numerator=None, ratio=None)
            row["event_kind"] = kind
            output.append(row)
    return output, frames, evidence, samples


def rows_in_window(db, table, start, end, export_limits=None):
    schema = Schema(db)
    if not schema.has(table, "ts"):
        return [], "channel absent" if table not in schema.tables else "unsupported timestamp column"
    limits = Counter()
    rows = take_records(time_rows(db, table, "*", "ts", start, end), limits, table)
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
                state = history.at(frame['timestamp_seconds']) if history else None
                focused.append({"frame": frame, "comparison": {
                    "focused_per_ours": "yes" if is_focused else "no" if nearby else "unknown",
                    "screen_evidence_within_60s": near(screen_times[digest(normalized(frame.get("app_name")))], frame.get("timestamp_seconds", frame["ts"]), 60),
                    "matching_document": any(same_document(r["document_key"], frame.get("browser_url")) for r in same),
                    "document_comparison_available": bool(frame.get("browser_url")) and any(r["document_key"] for r in same),
                    "our_samples_within_1s": len(nearby), "same_app_within_1s": bool(same),
                    "recording_enabled": state["enabled"] if state else None,
                    "paused": state["paused_until"] > frame['timestamp_seconds'] if state and state["paused_until"] is not None else False if state else None,
                    "excluded_per_ours": any(r.get("excluded") for r in same) if same else None}})
            agents, agent_status = rows_in_window(db, "agent_log_events", stamp, stamp + 300, export_limits)
            commits, git_status = rows_in_window(db, "git_commits", stamp, stamp + 300, export_limits)
            payloads = []
            schema = Schema(db)
            if agents and schema.has("agent_log_payloads", "id", "payload"):
                ids = sorted({row["payload_id"] for row in agents if "payload_id" in row})
                payloads = take_records((r for identity in ids for r in bounded_rows(db, 'agent_log_payloads', 'id=?', (identity,))), export_limits, 'agent_payloads')
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


# How text starts when a tool wrote it. Only describes what got stored; it decides nothing,
# because a person can quote a notice and a tool can write plain prose. Counted, never shown.
MACHINE_NOTICE = re.compile(r"\s*(?:<[A-Za-z][\w:-]*[\s>/]|\[Request interrupted|Caveat:|Base directory for this skill:|"
                            r"This session is being continued|Continue from where you left off)")


# Who wrote a stored prompt, from its log line. Tool marker first, then provenance, then whether the
# same template keeps coming back. Keys never decide here, because C13 is about keys, and neither
# does how the text starts. `marked_typed` says a turn came through the input box, not that a person
# wrote it: text sent in through a terminal gets the same marker.
PROMPT_GROUPS = ("marked_typed", "queued", "repeated_text", "agent", "machine_notice", "unknown")
UNSAID_PROMPT_GROUP = "unknown: no log line in scope, or its line has no tool marker and no provenance"


def prompt_group(candidate):
    if candidate.marker in ("non_instruction", "imported"):
        return "machine_notice"
    if candidate.marker == "agent" or candidate.sender == "agent":
        return "agent"
    if repeated_text(candidate):
        return "repeated_text"
    if candidate.marker == "human":
        return "queued" if candidate.queued else "marked_typed"
    return "unknown"


def prompt_matches(work, candidate, phase):
    """Stored prompts for this log line, by the identity rule C2 uses: same source, within a
    second, and native identity for phase 0, or equal text with a legacy side for phase 1."""
    scope = '' if candidate.tool == 'claude' and candidate.native_identity else candidate.session
    query = "SELECT id,ts FROM prompts WHERE ts>=? AND ts<=? AND source IN (SELECT source FROM aliases WHERE tool=? AND scope=? AND identity=?) AND "
    condition, value = (("identity=?", candidate.source_id) if phase == 0 else
                        ("body=?" + (" AND legacy=1" if candidate.native_identity else ""), candidate.body_digest))
    return [prompt for prompt, stamp in work.execute(query + condition, (candidate.ts - 1, candidate.ts + 1, candidate.tool, scope, candidate.source_id, value))
            if within_time(stamp, candidate.ts, 1)]


def stored_prompt_rows(work, candidates, keys):
    """C13: stored prompts with no key input, grouped by what their log lines say."""
    work.execute("CREATE TABLE prompt_lines(prompt INTEGER PRIMARY KEY,grp TEXT,app TEXT)")
    for phase in (0, 1):
        for c in candidates:
            for prompt in prompt_matches(work, c, phase):
                work.execute("INSERT OR IGNORE INTO prompt_lines VALUES(?,?,?)", (prompt, prompt_group(c), c.app))
    counts = defaultdict(Counter)
    for stamp, day, like_notice, group, app in work.execute("SELECT f.ts,f.day,f.like_notice,l.grp,l.app FROM prompt_facts f "
                                                                "LEFT JOIN prompt_lines l ON l.prompt=f.prompt").fetchall():
        count = counts[(day, group or "unknown")]
        count["stored"] += 1
        count["without_keys"] += not any(True for _ in keys.near(stamp))
        count["like_notice"] += like_notice
        count["unjoined"] += group is None
        if not app:
            count["same_app_unresolved"] += 1
        elif not keys.has(app, stamp):
            count["without_keys_same_app"] += 1
    return counts


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


OUTAGE_BLIND = ("only the 300 s after a stored input can be expected here, so this cannot see an outage: "
                "read no_row_seconds_unknown, seconds_after_last_row and person_active_seconds_without_row")
UNKNOWN_SPANS = "unknown: rest, sleep and loss look alike here, so this is not a rate of loss"
NO_SIGNALS = ("no source that counts here shows anything on this day: reference input or typed instructions. "
              "Chrome visits and shell history are only in by_source")


def day_bounds(day, tz, start, end):
    """The part of the window in this day."""
    return (max(start, int(datetime.fromisoformat(day).replace(tzinfo=tz).timestamp())),
            min(end, int((datetime.fromisoformat(day) + timedelta(days=1)).replace(tzinfo=tz).timestamp())))


def person_active_row(gap, reason, signals, low, high, day):
    """A zero here is only as good as what each source could see, so the row says that too."""
    sources = {source: signals.coverage(source, low, high) for source in ACTIVITY_SOURCES}
    unreadable = [source for source in ACTIVITY_SOURCES if not all(signals.inputs.get(source, {}).values())]
    usable = [source for source in ACTIVITY_TOTAL_SOURCES if sources[source]["readable"] and sources[source]["seconds"]]
    # Instructions are sparse by nature, so only `sources` says a long silence from them.
    stopped = sorted(source for source in ACTIVITY_TOTAL_SOURCES - {"typed_instruction"} if sources[source]["requested"] and sources[source]["cannot_speak_for_rest"])
    notes = [reason] if reason else []
    if unreadable:
        notes.append("partial: requested but not fully readable: " + ", ".join(unreadable))
    if not usable and not reason:
        notes.append(NO_SIGNALS)
    elif stopped and not reason:
        notes.append(f"last signal more than {REST_AFTER_INPUT} s before the end, so these cannot speak for the rest: " + ", ".join(stopped))
    measured = usable and not reason
    return dict(measure("C3", "person_active_seconds_without_row", day, gap['active_missing'] if measured else None,
                        gap['active'] if measured else None, reason="; ".join(notes) or None, lower=True),
                by_source={source: dict(seconds=seen, without_row=empty) for source, (seen, empty) in sorted(gap['sources'].items())},
                sources=sources, partial_input=bool(unreadable),
                visit_transitions=signals.visit_transitions.get(day, visit_transition_counts()),
                implied_expected_seconds=gap['implied_expected'], implied_seconds_without_row=gap['implied_missing'],
                implied_rule_seconds=REST_AFTER_INPUT)


def gap_rows(schema, samples_available, start, end, day_of, days, failures, signals, references, tz):
    """C3's four answers about silence. Only a measure with a meaning of its own can rank."""
    gaps, tail, reason = gap_checks(schema, start, end, day_of, failures, days, signals, references.copy_time) if samples_available else ({}, {}, "channel absent: samples")
    output = []
    for day in days:
        gap = gaps.get(day, gap_counts())
        blind = gap['no_row'] or tail.get('after_last_row', 0) > REST_AFTER_INPUT
        output.append(dict(measure("C3", "unexplained_gap_seconds", day, gap['missing'] if not reason else None,
                                   gap['expected'] if not reason else None, reason=reason or (OUTAGE_BLIND if blind else None), lower=True),
                           gap_runs=gap['runs'], longest_gap_seconds=gap['longest'], gap_runs_over_5_seconds=gap['over_five'],
                           rest_after_input_seconds=REST_AFTER_INPUT, machine_sleep_distinguished=False))
        output.append(dict(measure("C3", "no_row_seconds_unknown", day, gap['no_row'] if not reason else None, None,
                                   reason=reason or UNKNOWN_SPANS, lower=True),
                           no_row_spans_over_300_seconds=gap['spans'], longest_no_row_span_seconds=gap['longest_span'], ranked=False))
        output.append(person_active_row(gap, reason, signals, *day_bounds(day, tz, start, end), day))
    output.append(dict(measure("C3", "seconds_after_last_row", None, tail.get('after_last_row'), end - start if tail else None,
                               reason=reason or UNKNOWN_SPANS, lower=True),
                       ratio=None, ranked=False, last_row_in_window=tail.get('last_row_in_window'),
                       paused_off_or_erased_seconds=tail.get('explained'),
                       last_stored_after_window=tail.get('last_stored_after_window'),
                       copy_time_basis=references.copy_time_basis, copy_after_window_end=tail.get('copy_after_window_end'),
                       seconds_after_copy_time=tail.get('after_copy_time')))
    return output


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
    Progress.stage("input limits")
    for table in ('samples', 'evidence', 'git_repositories', 'git_commits', 'log_recording_history'):
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
        elif table == 'evidence':
            limits.audit(table, EvidenceRows(db, table, start - edge, end + edge))
        elif 'ts' in columns:
            limits.audit(table, QueryRows(db, table, start - edge, end + edge))
        else:
            limits.audit(table, bounded_rows(db, table))
    if schema.has('ax_probe_attempts', 'ts', 'payload'):
        limits.audit('ax_probe_attempts', bounded_rows(db, 'ax_probe_attempts', 'ts>=? AND ts<?', (start - edge, end + edge),
                                                       columns=['ts', 'payload']))
    if reference is not None:
        Progress.stage("reference window")
        for table in ('frames', 'ui_events'):
            if Schema(reference).has(table, 'timestamp') and timestamp_index_name(reference, table, 'timestamp'):
                limits.audit_window_timestamps(reference, table, 'timestamp', start, end)
            limits.audit(table, reference_rows(reference, table, start, end, days, day_of, work=work, bounds=(start, end)))
    sample_columns = ("ts", "bundle_id", "app", "window", "document_key", "keys", "clicks", "scrolls")
    samples_available = schema.has("samples", *sample_columns)
    edge = max(60 if reference is not None else 1, references.tolerance)
    samples = QueryRows(db, "samples", start - edge, end + edge) if samples_available else []
    # Keys before the window too: instructions there help name a session's app.
    keys = DiskKeys(work, neighborhood(samples, start - references.log_lookback - 1, end + 1))
    Progress.stage("read agent logs")
    scope = LogScope(start, end, references.log_lookback, references.all_logs)
    candidates, outgoing, received = read_logs(homes, diagnostics, work, scope)
    Progress.stage("classify instructions")
    classify(candidates, outgoing, received, keys)
    Progress.stage("match prompts")
    def selected():
        return (c for c in candidates if start <= c.ts < end and day_of(c.ts) in days)
    classifications = Counter("repeated_text" if repeated_text(c) else c.sender + ("_queued" if c.queued and c.sender == "human" else "")
                              for c in selected())
    def typed():
        return (c for c in selected() if c.sender == "human" and not c.queued and not repeated_text(c))
    evidence_available = schema.has("evidence", "ts", "kind", "source", "source_id", "text")
    work.executescript("""CREATE TABLE prompts(id INTEGER PRIMARY KEY, ts INTEGER, source TEXT, identity TEXT,
        body TEXT,length INTEGER,legacy INTEGER,used INTEGER DEFAULT 0);
        CREATE INDEX prompt_identity ON prompts(source,identity,ts);
        CREATE INDEX prompt_body ON prompts(source,body,ts);
        CREATE TABLE assignments(instruction TEXT PRIMARY KEY,equal_digest INTEGER,equal_length INTEGER,prompt INTEGER,phase INTEGER);
        CREATE TABLE prompt_facts(prompt INTEGER PRIMARY KEY,ts INTEGER,day TEXT,like_notice INTEGER);""")
    if evidence_available:
        for row in bounded_rows(db, 'evidence', "kind='prompt' AND ts>=? AND ts<?", (start - 1, end + 1),
                                columns=['rowid', 'ts', 'source', 'source_id', 'text']):
            if start <= row['ts'] < end and day_of(row['ts']) in days:
                work.execute("INSERT INTO prompt_facts VALUES(?,?,?,?)", (row['rowid'], row['ts'], day_of(row['ts']),
                                                                         bool(MACHINE_NOTICE.match(row['text']))))
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
    signals = ActivitySignals(work, references.tolerance)
    logs_unreadable = diagnostics["unreadable_log_files"]
    logs_read = sum(diagnostics[tool + "_source_files"] for tool in homes) - logs_unreadable
    signals.input_read("typed_instruction", "logs_read", logs_read > 0 or not logs_unreadable)
    if logs_unreadable:
        signals.input_read("typed_instruction", "logs_unreadable", False)
    # One matching for every line that can claim a stored prompt. Repeated text joins it, with its
    # own row below: the product stores a notice and a person's text alike, so who wrote a line does
    # not matter for whether it was stored.
    for c in selected():
        if c.queued or not (c.sender == "human" or repeated_text(c)):
            continue
        identity = instruction_key(c)
        if not repeated_text(c):
            signals.add("typed_instruction", c.ts)
        work.execute("INSERT INTO prompt_inputs VALUES(?,?,?,?)", (identity, c.ts, c.body_digest, c.length))
        for phase in (0, 1):
            for prompt in prompt_matches(work, c, phase):
                work.execute("INSERT OR IGNORE INTO prompt_edges VALUES(?,?,?)", (phase, identity, prompt))
    allocate_prompts(work)
    unknown_senders = Counter((c.tool, day_of(c.ts)) for c in selected() if c.sender == "unknown" and not repeated_text(c))
    repeated_instructions, repeated_stored = Counter(), defaultdict(Counter)
    for c in selected():
        if repeated_text(c) and not c.queued:
            where = (c.tool, day_of(c.ts))
            repeated_instructions[where] += 1
            match = work.execute("SELECT equal_digest,equal_length FROM assignments WHERE instruction=?", (instruction_key(c),)).fetchone()
            found = repeated_stored[where]
            found["stored"] += match is not None
            found["equal"] += match[0] if match else 0
            found["same_length"] += match[1] if match else 0
            if evidence_available and match is None:
                failures["missing_prompt_evidence"] += 1
    measurements = []
    for day in days:
        for tool in ("claude", "codex"):
            scope_fields = dict(log_scope="all" if references.all_logs else "window",
                                log_lookback_seconds=None if references.all_logs else references.log_lookback,
                                log_files_outside_scope=diagnostics[tool + "_log_files_outside_scope"],
                                log_files_starting_after_window=diagnostics[tool + "_log_files_starting_after_window"])
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
            no_logs = (None if diagnostics[tool + "_files"] else
                       "no agent logs in scope" if diagnostics[tool + "_log_files_outside_scope"] else "no readable agent logs")
            reason = None if instruction_count else no_logs or "no typed instructions"
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
            undecided, repeated = unknown_senders[(tool, day)], repeated_instructions[(tool, day)]
            logs_fields = dict(source_files=diagnostics[tool + "_source_files"],
                               readable_source_files=diagnostics[tool + "_source_files"] - unavailable,
                               unavailable_source_files=unavailable,
                               malformed_source_files=malformed, oversized_source_lines=oversized,
                               oversized_source_lines_unplaced=oversized, **scope_fields)
            logs_partial = "partial: agent logs malformed, oversized or unreadable" if unavailable or malformed or oversized else None
            for item in measurements[-2:]:
                item.update(unknown_instructions=undecided, repeated_text_instructions=repeated,
                            partial_input=bool(logs_partial or undecided or repeated), **logs_fields)
                if logs_partial:
                    item["reason"] = logs_partial
                # An instruction nobody could classify is outside this denominator, and may be a typed one.
                notes = ["partial: instructions with an unknown sender are not in this denominator"] if undecided else []
                if repeated:
                    notes.append("partial: instructions with repeated text are not in this denominator, "
                                 "and a person pasting one text that often is among them")
                if notes:
                    kept = item["reason"] if item["reason"] != "no typed instructions" else None
                    item["reason"] = "; ".join(([kept] if kept else []) + notes)
            found = repeated_stored[(tool, day)]
            row = measure("C2", "repeated_text_instructions_stored", day, found["stored"] if evidence_available else None, repeated, tool,
                          "channel absent: prompt evidence" if not evidence_available else logs_partial or (None if repeated else no_logs))
            row.update(equal_digest=found["equal"], equal_length=found["same_length"],
                       identity_matched_content_changed=found["stored"] - found["equal"], partial_input=bool(logs_partial), **logs_fields)
            measurements.append(row)
    prompt_counts = stored_prompt_rows(work, candidates, keys) if evidence_available and samples_available else {}
    for day in days:
        for group in PROMPT_GROUPS:
            count = prompt_counts.get((day, group), Counter())
            reason = ("channel absent: prompt evidence" if not evidence_available else
                      "channel absent: samples" if not samples_available else
                      UNSAID_PROMPT_GROUP if group == "unknown" and count["stored"] else None)
            absent = not evidence_available or not samples_available
            row = measure("C13", "stored_prompts_without_keys_" + group, day,
                          count['without_keys'] if not absent else None, count['stored'] if not absent else None,
                          reason=reason, lower=True)
            # Only a typed turn should have keys, so only that group can rank as a defect.
            row.update(tolerance_seconds=1, ranked=group == "marked_typed", without_keys_same_app=count["without_keys_same_app"],
                       same_app_unresolved=count["same_app_unresolved"], text_starts_like_notice=count["like_notice"],
                       no_log_line=count["unjoined"])
            measurements.append(row)
            if group == "marked_typed" and not absent:
                failures["stored_prompts_without_keys"] += count['without_keys']
    Progress.stage("attribution")
    work.execute("CREATE TABLE input_seconds(day TEXT,ts INTEGER,app INTEGER,window INTEGER,document INTEGER,PRIMARY KEY(day,ts))")
    for row in samples:
        if start <= row["ts"] < end and day_of(row["ts"]) in days and person_amount(row, "keys", "clicks", "scrolls") > 0:
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
    Progress.stage("Git, screen captures and files")
    measurements.extend(git_checks(schema, start, end, day_of, days, failures))
    measurements.extend(screen_checks(schema, start, end, day_of, days, failures))
    external_failures = failures if samples_available else Counter()
    external = []
    population = KnownFiles(work, samples, start, end, day_of, days, diagnostics)
    for day in days:
        day_start, day_end = day_bounds(day, tz, start, end)
        # Reusable cursor views keep attribution indices bounded to one day.
        day_samples = samples.between(day_start - references.tolerance, day_end + references.tolerance) if isinstance(samples, QueryRows) else []
        external.extend(chrome_checks(references, day_samples, day_start, day_end, day_of, [day], external_failures, diagnostics, signals))
        external.extend(file_checks(day_samples, day_of, [day], references, diagnostics, population))
        external.extend(shell_checks(references, day_samples, day_start, day_end, day_of, [day], external_failures, diagnostics, signals))
    if not samples_available:
        for row in external:
            row.update(numerator=None, ratio=None, reason="channel absent: samples")
    measurements.extend(external)
    Progress.stage("reference comparison")
    evidence_apps = EvidenceApps(db, work, limits, start, end) if reference is not None else None
    comparison, focused, raw_evidence, _ = reference_checks(db, reference, samples, start, end, day_of, days, failures, references, diagnostics, work, evidence_apps=evidence_apps, signals=signals)
    measurements.extend(comparison)
    if reference is not None or references.reference_database is not None:
        events = reference is not None and Schema(reference).has("ui_events", "timestamp", "event_type")
        signals.input_read("reference_input", "database", bool(events and timestamp_index_name(reference, "ui_events", "timestamp")))
    Progress.stage("gaps")
    measurements.extend(gap_rows(schema, samples_available, start, end, day_of, days, failures, signals, references, tz))
    if reference is not None:
        Progress.stage("bundles")
        bundles = export_bundles(db, focused, raw_evidence, samples, references, day_of, start, end, work, evidence_apps)
    else:
        bundles = {"seed": references.seed, "requested": references.bundle_count,
                   "exported": 0, "selected_windows": [], "reason": "reference recorder unavailable"}
    dependencies = {
        'C1': ('samples',), 'C2': ('evidence',),
        'C3': ('samples', 'log_recording_history'),
        'C4': ('git_repositories', 'git_commits'),
        'C5': ('evidence', 'ax_probe_attempts'),
        'C6': ('samples',), 'C7': ('samples',), 'C8': ('samples',),
        'C9': ('samples', 'frames'), 'C10': ('evidence', 'frames', 'evidence_apps'), 'C11': ('samples', 'ui_events'), 'C13': ('samples', 'evidence')}
    for row in measurements:
        limits.apply(row, dependencies[row['check']])
    bundles['input_limits'] = [dict(source=source, day=day, **count)
                              for (source, day), count in limits.counts.items() if count]
    bundles['partial_input'] = bool(bundles['input_limits']) or bundles.get('partial_input', False)
    worst = []
    for day in days:
        values = [r for r in measurements if r["day"] == day and r["ratio"] is not None and r.get("ranked", True)]
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
        available = [r for r in rows if r["numerator"] is not None and (r["denominator"] is not None or r["metric"] == "no_row_seconds_unknown")]
        numerator = sum(r["numerator"] for r in available)
        denominator = sum(r["denominator"] or 0 for r in available)
        ratio = f"{numerator / denominator:.1%}" if denominator and any(r["ratio"] is not None for r in available) else "n/a"
        reasons = sorted({r["reason"] for r in rows if r["reason"] and not (denominator and r["reason"] in ("no typed instructions", "empty denominator"))})
        amount = f"{numerator} s" if metric == "no_row_seconds_unknown" else f"{numerator}/{denominator} ({ratio})"
        lines.append(f"{check} {metric}" + (f" ({tool})" if tool else "") +
                     f": {amount}" + ("; " + "; ".join(reasons) if reasons else ""))
    lines.append("Worst days: " + (", ".join(f"{r['day']} {r['metric']} {r['numerator']}/{r['denominator']}"
                                            for r in report["worst_days"]) or "unavailable"))
    lines.append("Top failure categories: " + (", ".join(f"{r['category']}={r['count']}"
                                                        for r in report["top_failure_categories"]) or "none measured"))
    lines.append("Sender classifications: " + (", ".join(f"{k}={v}" for k, v in sorted(report["classifications"].items())) or "none"))
    warnings = {k: v for k, v in report["diagnostics"].items() if v and not k.endswith("_files")}
    if warnings:
        lines.append("Input diagnostics: " + ", ".join(f"{k}={v}" for k, v in sorted(warnings.items())))
    return "\n".join(lines)


def file_written(path):
    """The file's last write, with its log. A copy cannot hold a row from after this."""
    times = [os.stat(item).st_mtime for item in (path, str(path) + "-wal") if os.path.exists(item)]
    return max(times) if times else None


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes user-provided paths or invalid values.
        self.exit(2, "Invalid arguments; use --help for the accepted format.\n")


def raise_interrupt(number, frame):
    raise KeyboardInterrupt()


def main(argv=None):
    # Termination must reach the same cleanup as Ctrl-C: the reference clone has to go.
    previous = {number: signal.signal(number, raise_interrupt) for number in (signal.SIGTERM, signal.SIGHUP)}
    try:
        return run(argv)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
        Progress.enabled = False


def run(argv=None):
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
    parser.add_argument("--input-is-private-copy", action="store_true",
                        help="when the database cannot be cloned, open it where it lies; only for a private copy, since this can leave side files")
    parser.add_argument("--copy-time", help="when this copy was taken, ISO or Unix seconds; default: its last write. Measure it before "
                                            "the copy starts: a VACUUM INTO file is written when it ends, and cp -c keeps the source's time")
    parser.add_argument("--all-logs", action="store_true", help="read every agent log ever written, not only those around the window")
    parser.add_argument("--log-lookback-hours", type=float, default=24,
                        help="also read logs last written this long before the window, for provenance; default 24")
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
        if args.tolerance_seconds < 0 or not 0 <= args.bundle_count <= MAX_BUNDLES or args.log_lookback_hours < 0:
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
        copy_time, copy_basis = (boundary(args.copy_time), "given") if args.copy_time else (file_written(args.database), "last_write")
        Progress.start()
        with primary_snapshot(args.database, args.input_is_private_copy) as db, ExitStack() as stack:
            references = ReferenceInputs(tuple(args.chrome_history), tuple(args.shell_history),
                                         args.tolerance_seconds, tuple(args.terminal_app), args.reference_database,
                                         args.bundle_dir, args.bundle_count, args.seed, window_start, window_end, selected_days,
                                         args.all_logs, int(args.log_lookback_hours * 3600), copy_time, copy_basis)
            reference, reference_error, reference_reason = None, False, "reference recorder unavailable after retries"
            if args.reference_database is not None:
                try:
                    reference = stack.enter_context(reference_snapshot(args.reference_database))
                except CloneUnavailable:
                    reference_error = True
                    reference_reason = ("reference recorder not cloneable: it must share an APFS volume with the "
                                        "private temporary folder; set TMPDIR to a folder on its volume")
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
                        row["reason"] = reference_reason
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
    except CloneUnavailable:
        close_mask()
        print("Fidelity check refused: the database cannot be cloned here and is never opened where it lies. "
              "Set TMPDIR to a folder on its volume, or give --input-is-private-copy if this path is a private copy.", file=sys.stderr)
        return 1
    except Exception:
        close_mask()
        print("Fidelity check failed: input unavailable, invalid range or unsupported data; no content emitted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
