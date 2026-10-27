#!/usr/bin/env python3
"""Compile pinned main's real parser/storage, then test additive adoption on invented DBs."""
import argparse
import io
import json
import sqlite3
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
HELPERS = REPO / "tools" / "agent-log-adoption"


def run(args, **kwargs):
    try:
        return subprocess.run([str(x) for x in args], cwd=REPO, check=True, **kwargs)
    except subprocess.CalledProcessError:
        log = kwargs.get("stderr")
        if log is not None and hasattr(log, "name"):
            log.flush()
            print(Path(log.name).read_text()[-6000:])
        raise


def record(tool, field, value, time=200, parts=None):
    stamp = f"1970-01-01T00:03:{time-180:02d}Z"
    if tool == "claude":
        result = {"type": "user", "sessionId": "invented-session", "uuid": "invented-item",
                  "timestamp": stamp, "message": {"role": "user", "content": "Invented adoption instruction"}}
        if field == "attachment.source_uuid":
            result["type"] = "attachment"
            result["attachment"] = {"type": "queued_command", "humanTurn": True, "source_uuid": value,
                                    "prompt": "Invented adoption instruction"}
        else:
            result[field] = value
        return [json.dumps(result)]
    thread, turn, item = parts or ("invented-thread", "invented-turn", "invented-item")
    if field in ("thread", "header.id", "header.session_id"):
        thread = value
    elif field == "turn":
        turn = value
    elif field == "item":
        item = value
    payload = {"type": "item_completed", "thread_id": thread, "turn_id": turn,
               "item": {"id": item, "type": "UserMessage", "content": [{"type": "text", "text": "Invented adoption instruction"}]}}
    prefix = []
    if field.startswith("header."):
        del payload["thread_id"]
        prefix = [json.dumps({"type": "session_meta", "timestamp": stamp, "payload": {field[7:]: thread}})]
    return prefix + [json.dumps({"type": "event_msg", "timestamp": stamp, "payload": payload})]


def fixtures():
    cases = []
    def add(tool, lines, future, **extra):
        for copied_first in (False, True):
            cases.append(dict(name=f"invented-{len(cases)}", tool=tool, lines=lines, future=future,
                              copied_first=copied_first, **extra))
    for field in ("uuid", "thread", "turn", "item"):
        tool = "claude" if field == "uuid" else "codex"
        for pair in (("invented-a", r"invented-\u0061"),
                     ('{"ordinary":"invented"}', '{ "ordinary" : "invented" }'),
                     ("invented-a", "invented-b")):
            for values in (pair, pair[::-1]):
                for collision in (False, True):
                    lines, future = [], []
                    for i, value in enumerate(values):
                        lines += record(tool, field, value, 200+i)
                        future += record(tool, field, value, 204+i)
                    if collision:
                        # An unchanged key sharing the same source is also adopted.
                        lines += record(tool, field, "invented-unchanged", 202)
                        future += record(tool, field, "invented-unchanged", 206)
                    add(tool, lines, future)
    secret = "sk-proj-" + "v" * 48
    escaped = "".join(f"\\u{ord(c):04x}" for c in secret)
    for field in ("uuid", "commandUuid", "source_uuid", "attachment.source_uuid", "thread", "turn", "item", "header.id", "header.session_id"):
        tool = "claude" if field in ("uuid", "commandUuid", "source_uuid", "attachment.source_uuid") else "codex"
        for value in (escaped, escaped.replace("\\", "\\\\"), '"' + escaped + '"'):
            add(tool, record(tool, field, value), record(tool, field, value, 204), forbidden=escaped)
    for parts in (("a:b", "c", "d"), ("a", "b:c", "d"), ("a", "b", "c:d"), ("legacy", "b", "d"), ("a", "b", "d"), ("invented-a:\u0301b", "\u0301c", "invented-item"), ("invented-a", "\u0301b:\u0301c", "invented-item")):
        for retention in (False, True):
            add("codex", record("codex", "tuple", "", parts=parts), record("codex", "tuple", "", 204, parts), retention=retention)
    for value in ("activityprobe:\u0301ordinary", "\u0301invented-native", "ordinary", "a:b", "legacy:b:d", "occurrence:b:d", "native:sha256:invented", "x"*8192,
                  r"invented-\u0061", '{ "ordinary" : "invented" }',
                  '{ "password" : "invented" }', r'{ \"password\" : \"invented\" }', "//invented-user:invented-pass@invented.invalid"):
        for tool, field in (("claude", "uuid"), ("codex", "header.id")):
            for retention in (False, True):
                add(tool, record(tool, field, value), record(tool, field, value, 204), retention=retention)
    # Main's colon join intentionally aliases these distinct modern tuples.
    # Preserve that refusal/content ambiguity only inside the adoption adapter.
    tuple_a = ("invented-a:\u0301b", "\u0301c", "invented-item")
    tuple_b = ("invented-a", "\u0301b:\u0301c", "invented-item")
    for retention in (False, True):
        add("codex", record("codex", "tuple", "", parts=tuple_a) + record("codex", "tuple", "", 201, tuple_b),
            record("codex", "tuple", "", 204, tuple_a) + record("codex", "tuple", "", 205, tuple_b), retention=retention)
    # Main's implicit command pairing and consumed-copy aliases used the same
    # joined identity spellings, even though modern implicit copies stay independent.
    def queued(command, child, time):
        enqueue = {"type": "queue-operation", "operation": "enqueue", "commandUuid": command,
                   "timestamp": f"1970-01-01T00:03:{time-180:02d}Z", "content": "Invented queued instruction"}
        delivery = {"type": "user", "promptSource": "queued", "uuid": child,
                    "timestamp": f"1970-01-01T00:03:{time-179:02d}Z",
                    "message": {"role": "user", "content": "Invented queued instruction"}}
        return [json.dumps(enqueue), json.dumps(delivery)]
    for value in (escaped, escaped.replace("\\", "\\\\"), '"' + escaped + '"', "x" * 8192):
        add("claude", queued(value, "invented-child", 200), queued(value, "invented-future-child", 204),
            forbidden=escaped, independent=True)
        add("claude", queued("invented-command", value, 200), queued("invented-command", value, 204),
            forbidden=escaped)
    return cases


def check_origin(revision, version, debug=None):
    with tempfile.TemporaryDirectory(prefix="activityprobe-actual-main-") as temporary:
        base = Path(temporary)
        old = base / "main"
        old.mkdir()
        archive = subprocess.check_output(["git", "archive", revision, "Sources/Core", "Sources/Storage"] + (["Sources/Inbound"] if version == 15 else []), cwd=REPO)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(old, filter="data")
        with (base / "compile.log").open("w") as log:
            for module in ("Core", "Storage"):
                args = ["swiftc", "-parse-as-library", "-emit-library", "-emit-module", "-enable-testing", "-module-name", module,
                        "-I", old, "-L", old, "-o", old / f"lib{module}.dylib"]
                if module == "Storage":
                    args += ["-lCore", "-lsqlite3"]
                run(args + sorted((old / "Sources" / module).glob("*.swift")), stdout=log, stderr=log)
            run(["swiftc", "-I", old, "-L", old, "-lCore", "-lStorage", "-lsqlite3", "-Xlinker", "-rpath", "-Xlinker", old,
                 HELPERS / "seed.swift", "-o", base / "seed", *(["-D", "MAIN14"] if version >= 14 else [])], stdout=log, stderr=log)
            run(["swiftc", "-I", old, "-L", old, "-lCore", "-lStorage", "-lsqlite3", "-Xlinker", "-rpath", "-Xlinker", old,
                 HELPERS / "seed-cursors.swift", "-o", base / "seed-cursors"], stdout=log, stderr=log)
            if version == 15:
                run(["swiftc", "-parse-as-library", "-emit-library", "-emit-module", "-enable-testing", "-module-name", "Inbound",
                     "-I", old, "-L", old, "-lCore", "-o", old / "libInbound.dylib", *sorted((old / "Sources/Inbound").glob("*.swift"))], stdout=log, stderr=log)
                run(["swiftc", "-I", old, "-L", old, "-lCore", "-lStorage", "-lInbound", "-lsqlite3", "-Xlinker", "-rpath", "-Xlinker", old,
                     HELPERS / "verify.swift", "-o", base / "verify-control"], stdout=log, stderr=log)
            debug = debug or Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=REPO, text=True).strip())
            objects = [p for module in ("Core", "Storage", "Inbound") for p in sorted((debug / f"{module}.build").glob("*.swift.o"))]
            run(["swiftc", "-I", debug / "Modules", HELPERS / "verify.swift", *objects, "-lsqlite3", "-o", base / "verify"], stdout=log, stderr=log)
            run(["swiftc", "-I", debug / "Modules", HELPERS / "verify-cursors.swift", *objects, "-lsqlite3", "-o", base / "verify-cursors"], stdout=log, stderr=log)
            run(["swiftc", "-I", debug / "Modules", HELPERS / "open-only.swift", *objects, "-lsqlite3", "-o", base / "open-only"], stdout=log, stderr=log)
        run([base / "seed-cursors", base])
        run([base / "verify-cursors", base, version])
        (base / "cases.json").write_text(json.dumps(fixtures()))
        run([base / "seed", base, version])
        if version == 15:
            control = base / "pinned-control"
            control.mkdir()
            independent = [case for case in fixtures() if case.get("independent")]
            (control / "cases.json").write_text(json.dumps(independent))
            for case in independent:
                shutil.copytree(base / case["name"], control / case["name"])
            run([base / "verify-control", control, version, "--control"])
        prove_additive(base, base / "open-only", version)
        run([base / "verify", base, version])
    print("Actual-main temporary folder deleted")


def prove_additive(base, binary, version):
    # Guard every original table, including empty tables, before the first new open.
    # Compare original columns with typeof, and require all additive columns to be NULL.
    database = base / "invented-proof" / "invented.sqlite"
    def quote(value):
        return '"' + value.replace('"', '""') + '"'
    with sqlite3.connect(database) as db:
        assert db.execute("PRAGMA user_version").fetchone() == (version,)
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
        original = {}
        for table in tables:
            columns = [r[1] for r in db.execute(f"PRAGMA table_info({quote(table)})")]
            selection = ','.join(f'{quote(c)},typeof({quote(c)})' for c in columns)
            original[table] = columns, selection, db.execute(f'SELECT {selection} FROM {quote(table)} ORDER BY {selection}').fetchall()
            for operation in ("INSERT", "UPDATE", "DELETE"):
                db.execute(f"CREATE TRIGGER {quote('invented_guard_' + table + operation)} BEFORE {operation} ON {quote(table)} BEGIN SELECT RAISE(ABORT,'Historical mutation'); END")
    run([binary, database.parent])
    with sqlite3.connect(database) as db:
        assert db.execute("PRAGMA user_version").fetchone() == (16,)
        for table, (columns, selection, rows) in original.items():
            assert db.execute(f'SELECT {selection} FROM {quote(table)} ORDER BY {selection}').fetchall() == rows, table
            added = {r[1] for r in db.execute(f"PRAGMA table_info({quote(table)})")} - set(columns)
            for column in added:
                assert db.execute(f'SELECT count(*) FROM {quote(table)} WHERE {quote(column)} IS NOT NULL').fetchone() == (0,), (table, column)
            for operation in ("INSERT", "UPDATE", "DELETE"):
                db.execute(f"DROP TRIGGER {quote('invented_guard_' + table + operation)}")
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    print(f"Additive schema {version}->16: {len(tables)} original tables guarded for INSERT/UPDATE/DELETE; bytes/types unchanged; added columns NULL", flush=True)


def check_rejected_branch_origin(debug=None):
    with tempfile.TemporaryDirectory(prefix="activityprobe-actual-branch-") as temporary:
        base = Path(temporary)
        old = base / "branch"
        old.mkdir()
        archive = subprocess.check_output(["git", "archive", "7094865", "Sources/Core", "Sources/Storage"], cwd=REPO)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(old, filter="data")
        with (base / "compile.log").open("w") as log:
            for module in ("Core", "Storage"):
                args = ["swiftc", "-parse-as-library", "-emit-library", "-emit-module", "-enable-testing", "-module-name", module,
                        "-I", old, "-L", old, "-o", old / f"lib{module}.dylib"]
                if module == "Storage": args += ["-lCore", "-lsqlite3"]
                run(args + sorted((old / "Sources" / module).glob("*.swift")), stdout=log, stderr=log)
            run(["swiftc", "-I", old, "-L", old, "-lCore", "-lStorage", "-lsqlite3", "-Xlinker", "-rpath", "-Xlinker", old,
                 HELPERS / "seed.swift", "-o", base / "seed"], stdout=log, stderr=log)
            debug = debug or Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=REPO, text=True).strip())
            objects = [p for module in ("Core", "Storage") for p in sorted((debug / f"{module}.build").glob("*.swift.o"))]
            run(["swiftc", "-I", debug / "Modules", HELPERS / "open-only.swift", *objects, "-lsqlite3", "-o", base / "open-only"], stdout=log, stderr=log)
        (base / "cases.json").write_text("[]")
        run([base / "seed", base, 14])
        database = base / "invented-proof" / "invented.sqlite"
        with sqlite3.connect(database) as db:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
            for index, table in enumerate(tables):
                quoted = '"' + table.replace('"', '""') + '"'
                for operation in ("INSERT", "UPDATE", "DELETE"):
                    db.execute(f"CREATE TRIGGER invented_guard_{index}_{operation} BEFORE {operation} ON {quoted} BEGIN SELECT RAISE(ABORT,'Historical mutation'); END")
        for version in (10, 11, 12, 13, 14):
            with sqlite3.connect(database) as db: db.execute(f"PRAGMA user_version={version}")
            before = database.read_bytes()
            run([base / "open-only", database.parent, "--refuse"])
            assert database.read_bytes() == before, version
        print(f"Actual branch schema 14 and versions 10/11/12/13 refused before writes: {len(tables)} original tables guarded; database bytes unchanged", flush=True)
    print("Actual-branch temporary folder deleted", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-path", type=Path, help="Existing current Swift debug bin directory")
    args = parser.parse_args()
    for revision, version in (("45312a9", 9), ("3bca053", 14), ("1763e0b", 15)):
        check_origin(revision, version, args.build_path)
    check_rejected_branch_origin(args.build_path)


if __name__ == "__main__":
    main()
