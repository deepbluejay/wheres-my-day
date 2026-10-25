#!/usr/bin/env python3
"""Counts-only AX risk analysis of a private, standalone SQLite backup, never the live DB."""
import argparse
import collections
import hashlib
import json
import math
import os
import random
import re
from pathlib import Path
import sqlite3
import stat
import sys

BROWSER_FLAGS = ("true", "false", "unknown")
MASK_KINDS = ("secret", "email", "redacted", "phone")
TRUNCATIONS = ("elementLimit", "depthLimit", "deadline", "watchdog", "messagingFailure", "resource_truncated")
OCR_REFUSALS = ("no_person_input", "key_changed", "superseded", "busy", "dropped", "expired", "failed",
                "permission", "unavailable", "recording_off", "excluded_app", "secure_input", "own_app",
                "settings_unreadable", "capture_generation")
STATUSES = ("pending", "completed", "empty", "permission", "browserExcluded", "policyRefused", "busy",
            "cooldown", "pidDisabled", "identityUnknown", "identityChanged", "visibilityUnknown", "unsupported",
            "messagingFailure", "invalidElement", "deadline", "watchdog", "cancelled", "elementLimit", "depthLimit",
            "ipcLimit", "byteLimit", "oversize", "overload_dropped", "resource_truncated", "storage_failed")


def private_file(path):
    path = Path(path).expanduser()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("private regular file required")
    return path.resolve()


def database_copy(path):
    path = private_file(path)
    live = Path.home() / "Library/Application Support/ActivityProbe"
    if path == live or live in path.parents or path.name == "activity.sqlite":
        raise ValueError("use a separately named backup outside the app directory")
    override = os.environ.get("ACTIVITYPROBE_DB")
    if override and Path(override).expanduser().resolve() == path:
        raise ValueError("recorder override is not a backup")
    if path.stat().st_nlink != 1:
        raise ValueError("a hard link is not a backup")
    if any(Path(str(path) + suffix).exists() for suffix in ("-wal", "-shm", "-journal", ".recorder-lock")):
        raise ValueError("use a standalone SQLite backup")
    # Immutable is safe only for this standalone backup. It prevents SQLite creating sidecars.
    return sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)


def read_map(path):
    if not path:
        return {}
    value = json.loads(private_file(path).read_text())
    if not isinstance(value, dict):
        raise ValueError("invalid label map")
    bundles = value.get("bundles", value)
    if not isinstance(bundles, dict) or any(not isinstance(k, str) or not isinstance(v, str) or not v.strip()
                                            for k, v in bundles.items()):
        raise ValueError("invalid label map")
    return {hashlib.sha256(k.lower().encode()).hexdigest(): v for k, v in bundles.items()}


def app_key(key):
    # Current keys are SHA-256 digests. Never echo unexpected legacy/free-form keys.
    return key if isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key) else hashlib.sha256(str(key).encode()).hexdigest()


def browser_flag(pair):
    value = pair.get("isBrowser")
    return "true" if value is True else "false" if value is False else "unknown"


def quantile(values, p):
    values = sorted(values)
    if not values:
        return None
    index = (len(values) - 1) * p
    lower = math.floor(index)
    return values[lower] + (values[math.ceil(index)] - values[lower]) * (index - lower)


class Accumulator:
    def __init__(self):
        self.counts = collections.Counter()
        self.statuses = collections.Counter()
        self.masks = collections.Counter()
        self.truncations = collections.Counter()
        self.durations = []
        self.timings = 0
        self.samples = {"node_read_seconds": [], "nodes_per_attempt": []}
        self.sample_counts = collections.Counter()
        self.ocr_refusals = collections.Counter()
        self.random = random.Random(0)

    def sample(self, name, value):
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            return
        self.sample_counts[name] += 1
        sample = self.samples[name]
        if len(sample) < 4096:
            sample.append(value)
        else:
            index = self.random.randrange(self.sample_counts[name])
            if index < 4096:
                sample[index] = value

    def add(self, pair):
        counts, statuses, masks, truncations, durations = self.counts, self.statuses, self.masks, self.truncations, self.durations
        ax = pair.get("ax", {})
        status = ax.get("status")
        statuses[status if status in STATUSES else "unknown"] += 1
        nodes = ax.get("nodes")
        reason = pair.get("ocr_refusal_reason")
        if reason in OCR_REFUSALS:
            self.ocr_refusals[reason] += 1
        attempted = ax.get("ipc", 0) > 0 or status == "watchdog"
        counts["attempts"] += attempted
        counts["completed_without_truncation"] += attempted and status in ("completed", "empty") and not ax.get("truncated")
        latencies = ax.get("nodeReadMicroseconds") or []
        latencies = [value for value in latencies if isinstance(value, int) and 0 <= value <= 16_000_000]
        count = ax.get("nodeReadCount", len(latencies))
        if latencies and isinstance(count, int) and 0 < count <= 50000:
            # Reweight each bounded attempt sample to its actual measured-node count.
            for index in range(count):
                self.sample("node_read_seconds", latencies[index % len(latencies)] / 1e6)
        if attempted:
            self.sample("nodes_per_attempt", ax.get("elements", 0))
            counts["attempt_nodes"] += ax.get("elements", 0)
        counts["opportunities"] += 1
        counts["legacy_opportunities"] += nodes is None
        counts["legacy_category_opportunities"] += "category" in pair
        counts["ax_text_opportunities"] += bool(pair.get("axScalars", 0) or ax.get("text"))
        counts["ocr_text_opportunities"] += bool(pair.get("ocrScalars", 0) or pair.get("ocr"))
        counts["ocr_characters"] += pair.get("ocrScalars", len(pair.get("ocr", "")))
        counts["ax_characters"] += pair.get("axScalars", sum(a.get("length", len(a.get("text", ""))) for n in nodes for a in n.get("attributes", [])) if nodes is not None else len(ax.get("text", "")))
        counts["manual_accessibility_set"] += ax.get("manualAccessibility") == "set"
        counts["manual_accessibility_not_settable"] += ax.get("manualAccessibility") == "not_settable"
        counts["manual_accessibility_failed"] += ax.get("manualAccessibility") == "failed"
        if ax.get("ipc", 0) > 0 and status not in ("pending", "watchdog"):
            elapsed = ax.get("workerWall", max(0, ax.get("end", 0) - ax.get("start", 0)))
            if isinstance(elapsed, (float, int)) and math.isfinite(elapsed) and elapsed >= 0:
                self.timings += 1
                if len(durations) < 4096:
                    durations.append(elapsed)
                else:
                    index = self.random.randrange(self.timings)
                    if index < 4096:
                        durations[index] = elapsed
        counts["timing_censored_watchdogs"] += status == "watchdog"
        counts["truncated_attempts"] += bool(ax.get("truncated"))
        for reason, value in (ax.get("truncations") or {}).items():
            if reason in TRUNCATIONS:
                truncations[reason] += value
        if status == "watchdog" and "watchdog" not in (ax.get("truncations") or {}):
            truncations["watchdog"] += 1
        for node in nodes or []:
            self.node(node)

    def node(self, node):
        counts, masks = self.counts, self.masks
        counts["nodes"] += 1
        self.sample("node_read_seconds", node.get("readSeconds"))
        counts["secure_fields"] += bool(node.get("secure"))
        for attr in node.get("attributes", []):
            length = attr.get("length", len(attr.get("text", "")))
            counts["measured_node_characters"] += length
            off = node.get("insideWindow") is False
            screen = node.get("onScreen") is False
            hidden = node.get("hiddenBranch") or node.get("collapsedBranch")
            tab = node.get("nonSelectedTab")
            counts["off_window_characters"] += length if off else 0
            counts["off_screen_characters"] += length if screen else 0
            counts["hidden_branch_characters"] += length if hidden else 0
            counts["non_selected_tab_characters"] += length if tab else 0
            counts["unselected_branch_characters"] += length if node.get("unselectedBranch") else 0
            counts["selected_characters"] += length if node.get("selected") is True else 0
            counts["unselected_characters"] += length if node.get("selected") is False else 0
            counts["unknown_selection_characters"] += length if node.get("selected") is None else 0
            counts["not_visible_characters"] += length if off or screen or hidden or tab else 0
            counts["unknown_geometry_characters"] += length if node.get("insideWindow") is None or node.get("onScreen") is None else 0
            unknown = any(node.get(key) is None for key in ("hiddenBranch", "collapsedBranch", "nonSelectedTab"))
            counts["unknown_branch_characters"] += length if unknown else 0
            for kind, value in attr.get("maskHits", {}).items():
                if kind in MASK_KINDS:
                    masks[kind] += value

    def result(self):
        counts, statuses, masks, truncations, durations = self.counts, self.statuses, self.masks, self.truncations, self.durations
        # Stable output shape, including an empty browser dimension.
        for key in ("opportunities", "legacy_opportunities", "legacy_category_opportunities", "ax_text_opportunities", "ocr_text_opportunities",
                    "ax_characters", "ocr_characters", "nodes", "secure_fields", "manual_accessibility_set",
                    "manual_accessibility_not_settable", "manual_accessibility_failed", "truncated_attempts",
                    "timing_censored_watchdogs", "measured_node_characters", "off_window_characters", "off_screen_characters",
                    "hidden_branch_characters", "non_selected_tab_characters", "not_visible_characters", "unknown_geometry_characters", "unknown_branch_characters", "unselected_branch_characters", "selected_characters", "unselected_characters", "unknown_selection_characters"):
            counts.setdefault(key, 0)
        result = dict(counts)
        denominator = counts["measured_node_characters"]
        for key in ("off_window", "off_screen", "hidden_branch", "non_selected_tab", "not_visible", "unknown_geometry", "unknown_branch", "unselected_branch", "selected", "unselected", "unknown_selection"):
            result[key + "_share"] = counts[key + "_characters"] / denominator if denominator else None
        result["ax_text_yield"] = counts["ax_text_opportunities"] / counts["opportunities"] if counts["opportunities"] else None
        result["ocr_text_yield"] = counts["ocr_text_opportunities"] / counts["opportunities"] if counts["opportunities"] else None
        result["ax_to_ocr_character_ratio"] = counts["ax_characters"] / counts["ocr_characters"] if counts["ocr_characters"] else None
        result["completed_without_truncation_share"] = counts["completed_without_truncation"] / counts["attempts"] if counts["attempts"] else None
        result["ocr_refusal_reasons"] = {reason: self.ocr_refusals[reason] for reason in OCR_REFUSALS}
        for name, values in self.samples.items():
            result[name] = {"n": self.sample_counts[name], "sample_n": len(values), "p50": quantile(values, .5),
                            "p95": sorted(values)[math.ceil(len(values) * .95) - 1] if values else None}
        result["nodes_per_attempt"]["mean"] = counts["attempt_nodes"] / counts["attempts"] if counts["attempts"] else None
        result["statuses"] = dict(statuses)
        result["mask_hits"] = {kind: masks[kind] for kind in MASK_KINDS}
        result["truncations"] = dict(truncations)
        result["timing_seconds"] = {"n": self.timings, "sample_n": len(durations), "p50": quantile(durations, .5),
                                    "p95": sorted(durations)[math.ceil(len(durations)*.95)-1] if durations else None}
        return result


def describe(pairs):
    accumulator = Accumulator()
    for pair in pairs:
        accumulator.add(pair)
    return accumulator.result()


def analyze(db, run_id, mapping=None):
    mapping = mapping or {}
    if not db.execute("SELECT 1 FROM ax_probe_runs WHERE id=?", (run_id,)).fetchone():
        raise ValueError("missing run")
    groups, app_browsers = {}, {}
    browsers = {flag: Accumulator() for flag in BROWSER_FLAGS}
    total = Accumulator()
    content_schema = bool(db.execute("SELECT 1 FROM sqlite_master WHERE name='ax_probe_parts'").fetchone())
    for row_id, key, payload in db.execute("SELECT id,mapping_key,payload FROM ax_probe_attempts WHERE run_id=? ORDER BY id", (run_id,)):
        pair = json.loads(payload)
        key = app_key(key)
        if key not in groups:
            groups[key] = Accumulator()
            app_browsers[key] = {flag: Accumulator() for flag in BROWSER_FLAGS}
        flag = browser_flag(pair)
        accumulators = (total, groups[key], browsers[flag], app_browsers[key][flag])
        for accumulator in accumulators:
            accumulator.add(pair)
        if content_schema and pair.get("storageVersion") == 3 and pair.get("ax", {}).get("status") != "pending":
            # Each part has at most 16 nodes. Never hydrate text blobs or retain previous parts.
            for (digest,) in db.execute("SELECT hash FROM ax_probe_parts WHERE attempt_row=? ORDER BY ordinal", (row_id,)):
                raw = "".join(text for (text,) in db.execute("SELECT text FROM ax_probe_chunks WHERE hash=? ORDER BY ordinal", (digest,)))
                for node in json.loads(raw):
                    for accumulator in accumulators:
                        accumulator.node(node)
    flow = {}
    # Only known, content-free operational names are emitted.
    allowed = {"eligible", "privacyRefused", "pendingDropped", "settingsUnreadable", "supersededOCR", "droppedOCR", "busyOCR",
               "tickLateMilliseconds", "scheduledTickGaps", "watchdog", "censoredMilliseconds", "finishStorageFailures", "recoveredWorkerLease", "overload_dropped", "messagingFailures", "cooldowns"}
    allowed.update("ocr_" + reason for reason in OCR_REFUSALS)
    for event, event_total in db.execute("SELECT event,total FROM ax_probe_flow WHERE run_id=?", (run_id,)):
        if event in allowed:
            flow[event] = event_total
    overall = total.result()
    ranked = sorted(groups, key=lambda key: (-groups[key].counts["opportunities"], key))
    apps = {}
    for rank, key in enumerate(ranked, 1):
        apps[key] = {"rank": rank, **groups[key].result(),
                     "browser": {flag: app_browsers[key][flag].result() for flag in BROWSER_FLAGS}}
        if key in mapping:
            apps[key]["label"] = mapping[key]
    return {"overall": overall, "apps": apps,
            "browser": {flag: browsers[flag].result() for flag in BROWSER_FLAGS}, "flow": flow,
            "notes": ["Legacy opportunities have yield counts only; node risk metadata is unavailable.",
                      "Character counts include repeated attributes and visible-range strings; neither arm is ground truth.",
                      "Geometry and branch flags estimate visibility; occlusion and exact character visibility are unmeasured.",
                      "Unknown geometry and branch state are reported separately and are not treated as visible.",
                      "Mask hits count newly emitted mask markers by kind, not unique underlying secrets.",
                      "Timing and node metrics use deterministic uniform reservoirs of at most 4096 values per group; quantiles are approximate above that count. Node times are rounded to microseconds and sampled uniformly during persistence preparation (4096 per attempt), reweighted to measured-node count, then sampled at analysis (4096 per group). They cover batch/metadata/text reads, exclude descendants, and are unavailable in legacy nodes. Watchdogs are censored.",
                      "Selection state is reported separately; unselected controls alone do not imply hidden content.",
                      "Apps use stable opaque stored keys, ranked by opportunity count descending with key-order ties. Optional private labels never merge apps.",
                      "Browser flags are observed boolean facts, separate from apps. Missing or invalid flags are unknown; legacy categories are counted but ignored."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database-copy", required=True)
    parser.add_argument("--label-map", help="private bundle-ID to display-label JSON; labels appear in output for local viewing only")
    parser.add_argument("--run", required=True)
    args = parser.parse_args()
    mapping = read_map(args.label_map)
    with database_copy(args.database_copy) as db:
        print(json.dumps(analyze(db, args.run, mapping), sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("ax_probe_analysis_refused", file=sys.stderr)
        sys.exit(1)
