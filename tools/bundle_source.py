#!/usr/bin/env python3
"""Refuse a bundle that was not built from the source being checked.

probe.sh writes `build/.bundle-commit` next to every bundle it finishes: HEAD, the tree of every tracked
and untracked file at build time, and whether that tree differed from HEAD. A build that stops at
dependency resolution keeps the previous bundle and its record, so a later check sees the old source.
Usage: bundle_source.py BUNDLE [--repo REPO]
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
RECORD = ".bundle-commit"


def git(repo, *arguments, index=None):
    environment = dict(os.environ, GIT_INDEX_FILE=index) if index else None
    return subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True, text=True, check=True,
                          env=environment).stdout.strip()


def current(repo):
    """The same state probe.sh records: HEAD, and the tree of the working files through a private index."""
    head = git(repo, "rev-parse", "--verify", "HEAD")
    with tempfile.TemporaryDirectory(prefix="bundle-source.") as folder:
        index = str(Path(folder) / "index")
        git(repo, "read-tree", "HEAD", index=index)
        git(repo, "add", "-A", index=index)
        tree = git(repo, "write-tree", index=index)
    return {"commit": head, "tree": tree, "dirty": "0" if tree == git(repo, "rev-parse", "HEAD^{tree}") else "1"}


def recorded(bundle):
    path = Path(bundle).resolve().parent / RECORD
    if not path.is_file():
        return None
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def problems(bundle, repo=REPO):
    record = recorded(bundle)
    if record is None:
        return [f"{bundle} has no {RECORD}: it was not finished by probe.sh build; check that command's exit code"]
    now = current(repo)
    if (record.get("commit"), record.get("tree")) != (now["commit"], now["tree"]):
        return [f"{bundle} was built from commit {record.get('commit')} tree {record.get('tree')} (dirty={record.get('dirty')}), "
                f"but the source is commit {now['commit']} tree {now['tree']} (dirty={now['dirty']}); "
                "a failed probe.sh build keeps the previous bundle, so check its exit code and build again"]
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle")
    parser.add_argument("--repo", default=str(REPO))
    args = parser.parse_args()
    found = problems(args.bundle, Path(args.repo))
    for problem in found:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
