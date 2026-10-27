#!/usr/bin/env python3
"""Actual previous-build commit/crash/upgrade regressions. Uses owned temp data only."""
import io
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
PREVIOUS = "8a575902e45808c96d2a25190820af66c0451ac6"
MAIN14 = "3bca053"
MAIN15 = "1763e0b"
BROKEN = "bbd9d5267cd4cdea5498579813109c8cde43b8cb"
TABLES = ("evidence", "sample_observations", "screen_payloads", "collection_blobs", "input_batches", "collection_metadata")


def run(args, cwd=None):
    return subprocess.check_output([str(x) for x in args], cwd=cwd, text=True)


def export(revision, target):
    target.mkdir()
    archive = subprocess.check_output(["git", "archive", revision], cwd=REPO)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(target, filter="data")
    return target


def build(source, target, scratch):
    log = scratch / (target.name + "-build.log")
    with log.open("w") as output:
        subprocess.run(["swift", "build", "--jobs", "1", "--target", "Storage", "--scratch-path", str(target)],
                       cwd=source, stdout=output, stderr=subprocess.STDOUT, check=True)
    debug = Path(run(["swift", "build", "--show-bin-path", "--scratch-path", target], source).strip())
    objects = sorted((debug / "Core.build").glob("*.o")) + sorted((debug / "Storage.build").glob("*.o"))
    binary = scratch / (target.name + "-fixture")
    subprocess.run(["swiftc", "-g", "-I", str(debug / "Modules"), str(REPO / "tools/collection_replay_fixture.swift"),
                    *map(str, objects), "-lsqlite3", "-o", str(binary)], check=True)
    return binary


def snapshot(root):
    with sqlite3.connect(root / "invented.sqlite") as db:
        return {table: ([r[1] for r in db.execute(f"PRAGMA table_info({table})")],
                        db.execute(f"SELECT rowid,* FROM {table} ORDER BY rowid").fetchall()) for table in TABLES}


def unchanged(root, before):
    with sqlite3.connect(root / "invented.sqlite") as db:
        for table, (columns, rows) in before.items():
            added = {r[1] for r in db.execute(f"PRAGMA table_info({table})")} - set(columns)
            for rowid, *cells in rows:
                assert db.execute(f"SELECT {','.join(columns)} FROM {table} WHERE rowid=?", (rowid,)).fetchone() == tuple(cells), table
                for column in added:
                    assert db.execute(f"SELECT {column} FROM {table} WHERE rowid=?", (rowid,)).fetchone() == (None,), (table, column)
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def crash(binary, root, kind):
    child = subprocess.run([binary, "crash", root, kind], capture_output=True, text=True)
    assert child.returncode == 73, (kind, child.returncode, child.stderr)
    assert len(list(Path(str(root / 'invented.sqlite') + '.collection').glob('*.json'))) == 1
    return snapshot(root)


def recover(binary, root, kind, expected_version, before, excluded=False):
    result = json.loads(run([binary, "recover-excluded" if excluded else "recover", root, kind]))
    if excluded:
        assert result.pop("exclusionRefusals") > 0
    assert result == dict(version=expected_version, screens=2 if kind == "screen" else 1,
                          observations=1 if kind in ("input", "observation") else 0,
                          inputs=1 if kind == "input" else 0, metadata=1 if kind == "metadata" else 0,
                          ready=0, failures=0), result
    unchanged(root, before)
    print(f"PASS {kind} version={expected_version} excluded={excluded} ready=0 failures=0 original-bytes=unchanged added-columns=NULL", flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix="activityprobe-replay-upgrade-") as temp:
        scratch = Path(temp)
        old_source = export(PREVIOUS, scratch / "schema13")
        broken_source = export(BROKEN, scratch / "schema14-before")
        main14_source = export(MAIN14, scratch / "main14")
        # Copy the current sources, including uncommitted fixes, without a worktree/branch switch.
        current = export("HEAD", scratch / "current")
        for directory in ("Sources", "Plugins"):
            shutil.copytree(REPO / directory, current / directory, dirs_exist_ok=True)
        main15_source = export(MAIN15, scratch / "main15")
        main14 = build(main14_source, scratch / "build-main14", scratch)
        main15 = build(main15_source, scratch / "build-main15", scratch)
        old = build(old_source, scratch / "build13", scratch)
        broken = build(broken_source, scratch / "build14before", scratch)
        fixed = build(current, scratch / "build16fixed", scratch)
        cases = 0
        for kind in ("screen", "input", "metadata", "observation"):
            root = scratch / ("upgrade-" + kind)
            before = crash(old, root, kind)
            if kind != "observation":
                negative = scratch / ("negative-" + kind)
                shutil.copytree(root, negative)
                result = json.loads(run([broken, "recover", negative, kind]))
                assert result["ready"] >= 2 and result["failures"] > 0
                print(f"BEFORE {kind} ready={result['ready']} failures={result['failures']}", flush=True)
            # Schema 13 is an unsupported origin. Refusal must
            # precede writes, including ready-file replay and version changes.
            for label, writer in (("unsupported13", old),):
                rejected = scratch / (label + "-" + kind)
                crash(writer, rejected, kind)
                database = rejected / "invented.sqlite"
                original = database.read_bytes()
                child = subprocess.run([fixed, "expect-refusal", rejected, kind], capture_output=True, check=True)
                assert json.loads(child.stdout) == {"refused": 1}
                assert database.read_bytes() == original
                assert len(list(Path(str(database) + '.collection').glob('*.json'))) == 1
                print(f"PASS refused {label} {kind} database-bytes=unchanged ready=1", flush=True)
                cases += 1
            for label, writer in (("main14-excluded", main14), ("main15-excluded", main15), ("current-excluded", fixed)):
                control = scratch / (label + "-" + kind)
                original = crash(writer, control, kind)
                recover(fixed, control, kind, 16, original, excluded=True)
                cases += 1
            for label, writer, reader, version in (("13-to-13", old, old, 13),
                                                   ("historical-main14-to-16", broken, fixed, 16),
                                                   ("14-to-16", main14, fixed, 16),
                                                   ("15-to-15", main15, main15, 15),
                                                   ("15-to-16", main15, fixed, 16),
                                                   ("16-to-16", fixed, fixed, 16)):
                control = scratch / (label + "-" + kind)
                original = crash(writer, control, kind)
                recover(reader, control, kind, version, original)
                cases += 1
        print(f"PASS {cases} recovery cases and 3 reproduced pre-fix failures", flush=True)
    print("temp folder deleted", flush=True)


if __name__ == "__main__":
    main()
