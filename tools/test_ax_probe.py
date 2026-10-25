#!/usr/bin/env python3
"""Invented-only counts analysis and backup-boundary fixtures."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import tracemalloc
import unittest
from unittest.mock import patch
from ax_probe_analysis import analyze, database_copy, describe, private_file, quantile, read_map


def pair(nodes=None, **changes):
    result = {"isBrowser": True, "ocr": "Invented OCR", "ocrStatus": "completed",
              "ax": {"text": "Invented AX", "status": "completed", "nodes": nodes,
                     "ipc": 10, "workerWall": .2, "manualAccessibility": "set", "truncations": {}}}
    result.update(changes)
    return result


def node(length=10, **flags):
    result = {"insideWindow": True, "onScreen": True, "secure": False,
              "attributes": [{"attribute": "AXValue", "text": "Invented", "length": length, "maskHits": {"secret": 2}}]}
    result.update(flags)
    return result


class AnalysisTests(unittest.TestCase):
    def test_refusal_reasons_latency_nodes_and_completion_share(self):
        pairs = [pair([node(readSeconds=.001), node(readSeconds=.003)], ocr_refusal_reason="no_person_input"),
                 pair([node(readSeconds=.010)], ocr_refusal_reason="key_changed"),
                 pair([], ocr_refusal_reason="superseded"), pair([], ocr_refusal_reason="Invented private value")]
        for p, count in zip(pairs, [2, 1, 0, 0]):
            p["ax"]["elements"] = count
        pairs[1]["ax"].update(status="deadline", truncated=True)
        pairs[2]["ax"]["status"] = "watchdog"
        pairs[3]["ax"]["status"] = "messagingFailure"
        result = describe(pairs)
        self.assertEqual(result["ocr_refusal_reasons"]["no_person_input"], 1)
        self.assertEqual(result["ocr_refusal_reasons"]["key_changed"], 1)
        self.assertEqual(result["ocr_refusal_reasons"]["superseded"], 1)
        self.assertEqual(result["node_read_seconds"]["p50"], .003)
        self.assertEqual(result["node_read_seconds"]["p95"], .010)
        self.assertEqual(result["nodes_per_attempt"]["mean"], .75)
        self.assertEqual(result["completed_without_truncation_share"], .25)
        self.assertNotIn("Invented", json.dumps(result))

    def test_header_latency_sample_reweights_to_measured_nodes(self):
        p = pair([])
        p["ax"].update(nodeReadMicroseconds=[4000, 8000], nodeReadCount=100)
        result = describe([p])
        self.assertEqual(result["node_read_seconds"]["n"], 100)
        self.assertEqual(result["node_read_seconds"]["p50"], .006)
        self.assertEqual(result["node_read_seconds"]["p95"], .008)

    def test_visibility_union_never_double_counts_and_unknown_is_separate(self):
        p = pair([node(10), node(20, insideWindow=False, hiddenBranch=True, nonSelectedTab=True),
                  node(30, onScreen=False), node(40, insideWindow=None, onScreen=None)])
        result = describe([p])
        self.assertEqual(result["ax_characters"], 100)
        self.assertEqual(result["off_window_share"], .2)
        self.assertEqual(result["hidden_branch_share"], .2)
        self.assertEqual(result["non_selected_tab_share"], .2)
        self.assertEqual(result["not_visible_share"], .5)
        self.assertEqual(result["unknown_geometry_share"], .4)
        self.assertEqual(result["mask_hits"]["secret"], 8)
        self.assertNotIn("Invented", json.dumps(result))

    def test_collapsed_is_hidden_and_unselected_is_separate(self):
        result = describe([pair([node(collapsedBranch=True), node(unselectedBranch=True)])])
        self.assertEqual(result["hidden_branch_share"], .5)
        self.assertEqual(result["unselected_branch_share"], .5)
        self.assertEqual(result["not_visible_share"], .5)

    def test_empty_failed_pending_and_refused_remain_in_yield_denominator(self):
        pairs = [pair([]), pair([]), pair([]), pair([])]
        for p, status in zip(pairs, ["completed", "messagingFailure", "pending", "policyRefused"]):
            p["ax"]["status"] = status
            if status != "completed":
                p["ax"]["text"] = ""
                p["ocr"] = ""
        result = describe(pairs)
        self.assertEqual(result["opportunities"], 4)
        self.assertEqual(result["ax_text_yield"], .25)
        self.assertEqual(result["ocr_text_yield"], .25)
        self.assertEqual(result["statuses"]["policyRefused"], 1)

    def test_timing_truncation_secure_and_manual_accessibility_counts(self):
        pairs = [pair([node(secure=True)]) for _ in range(3)]
        for p, duration, manual in zip(pairs, [.1, .2, .4], ["set", "not_settable", "failed"]):
            p["ax"].update(workerWall=duration, manualAccessibility=manual)
        pairs[1]["ax"].update(truncated=True, truncations={"elementLimit": 1, "depthLimit": 1, "deadline": 1})
        pairs[2]["ax"]["status"] = "watchdog"
        result = describe(pairs)
        self.assertEqual(result["secure_fields"], 3)
        for key in ["set", "not_settable", "failed"]:
            self.assertEqual(result["manual_accessibility_" + key], 1)
        self.assertEqual(result["truncations"], {"elementLimit": 1, "depthLimit": 1, "deadline": 1, "watchdog": 1})
        self.assertEqual(result["timing_seconds"]["n"], 2)
        self.assertAlmostEqual(result["timing_seconds"]["p50"], .15)
        self.assertEqual(result["timing_seconds"]["p95"], .2)
        self.assertEqual(result["timing_censored_watchdogs"], 1)

    def test_legacy_and_empty_groups_have_explicit_unknown_risk(self):
        legacy = pair(category="invented_legacy_category"); legacy.pop("isBrowser")
        result = describe([legacy])
        self.assertEqual(result["legacy_opportunities"], 1)
        self.assertEqual(result["legacy_category_opportunities"], 1)
        self.assertEqual(describe([pair([])])["legacy_opportunities"], 0)
        self.assertIsNone(result["not_visible_share"])
        self.assertEqual(result["ax_characters"], len("Invented AX"))
        self.assertIsNone(describe([])["ax_text_yield"])
        self.assertEqual(quantile([0, 1, 2, 3], .25), .75)

    def test_generator_analysis_has_bounded_timing_memory(self):
        result = describe(pair([node(readSeconds=.004)]) for _ in range(20000))
        self.assertEqual(result["opportunities"], 20000)
        self.assertEqual(result["timing_seconds"]["n"], 20000)
        self.assertEqual(result["timing_seconds"]["sample_n"], 4096)
        self.assertEqual(result["node_read_seconds"]["n"], 20000)
        self.assertEqual(result["node_read_seconds"]["sample_n"], 4096)

    def test_unknown_metadata_never_becomes_output_labels(self):
        p = pair([node()])
        p["ax"].update(status="Invented sensitive status", truncations={"Invented sensitive reason": 1})
        p["ax"]["nodes"][0]["attributes"][0]["maskHits"]["Invented sensitive mask"] = 1
        self.assertNotIn("sensitive", json.dumps(describe([p])))


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ax-analysis-invented-")
        self.root = Path(self.temp.name)
        self.path = self.root / "invented-copy.sqlite"
        db = sqlite3.connect(self.path)
        db.executescript("CREATE TABLE ax_probe_runs(id TEXT); CREATE TABLE ax_probe_attempts(id INTEGER,run_id TEXT,mapping_key TEXT,payload TEXT); CREATE TABLE ax_probe_flow(run_id TEXT,event TEXT,total INTEGER);")
        db.execute("INSERT INTO ax_probe_runs VALUES('invented-run')")
        self.key = hashlib.sha256(b"invented.bundle").hexdigest()
        db.execute("INSERT INTO ax_probe_attempts VALUES(1,'invented-run',?,?)", (self.key, json.dumps(pair([node()]))))
        db.commit(); db.close()
        self.path.chmod(0o600)

    def tearDown(self):
        self.temp.cleanup()

    def test_private_copy_readonly_without_sidecars_and_optional_label(self):
        before = self.path.read_bytes()
        db = database_copy(self.path)
        try:
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("DELETE FROM ax_probe_attempts")
            result = analyze(db, "invented-run", {self.key: "Local editor"})
            self.assertEqual(result["apps"][self.key]["opportunities"], 1)
            self.assertEqual(result["apps"][self.key]["label"], "Local editor")
            self.assertEqual(result["overall"]["opportunities"], 1)
            self.assertNotIn("Invented", json.dumps(result))
        finally:
            db.close()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [self.path])

    def test_analyzer_streams_many_rows_without_retaining_payloads(self):
        db = sqlite3.connect(self.path)
        payload = json.dumps(pair([node()], ocr="x" * 4096))
        db.executemany("INSERT INTO ax_probe_attempts VALUES(?,'invented-run',?,?)",
                       ((i + 2, self.key, payload) for i in range(15000)))
        db.execute("INSERT INTO ax_probe_flow VALUES('invented-run','overload_dropped',3)")
        db.commit()
        tracemalloc.start()
        result = analyze(db, "invented-run")
        peak = tracemalloc.get_traced_memory()[1]
        tracemalloc.stop()
        db.close()
        self.assertLess(peak, 8 * 1024 * 1024)
        self.assertEqual(result["overall"]["opportunities"], 15001)
        self.assertEqual(result["flow"]["overload_dropped"], 3)

    def test_per_app_rank_browser_dimension_and_legacy_categories_are_independent(self):
        db = sqlite3.connect(self.path)
        other = hashlib.sha256(b"invented.other").hexdigest()
        tied = hashlib.sha256(b"invented.tied").hexdigest()
        legacy = pair([node()], category="browser"); legacy.pop("isBrowser")
        rows = [(2, self.key, pair([], isBrowser=False)), (3, self.key, legacy),
                (4, other, pair([], isBrowser=False)), (5, tied, pair([], isBrowser="Invented private flag"))]
        for row_id, key, payload in rows:
            db.execute("INSERT INTO ax_probe_attempts VALUES(?,'invented-run',?,?)", (row_id, key, json.dumps(payload)))
        db.commit()
        before = list(db.execute("SELECT payload FROM ax_probe_attempts ORDER BY id"))
        result = analyze(db, "invented-run", {self.key: "Local label", other: "Local label"})
        self.assertEqual(result["apps"][self.key]["rank"], 1)
        self.assertEqual(result["apps"][self.key]["opportunities"], 3)
        self.assertEqual(result["apps"][min(other, tied)]["rank"], 2)
        self.assertEqual(result["apps"][max(other, tied)]["rank"], 3)
        self.assertEqual(len(result["apps"]), 3)
        for flag in ("true", "false", "unknown"):
            self.assertEqual(result["apps"][self.key]["browser"][flag]["opportunities"], 1)
        self.assertEqual(result["browser"]["false"]["opportunities"], 2)
        self.assertEqual(result["browser"]["unknown"]["opportunities"], 2)
        self.assertEqual(result["overall"]["legacy_category_opportunities"], 1)
        default = analyze(db, "invented-run")
        self.assertNotIn("classes", default)
        self.assertNotIn("label", default["apps"][self.key])
        self.assertNotIn("Invented", json.dumps(default))
        self.assertEqual(list(db.execute("SELECT payload FROM ax_probe_attempts ORDER BY id")), before)
        db.close()

    def test_unexpected_stored_app_key_is_opaque_and_stable(self):
        db = sqlite3.connect(self.path)
        db.execute("UPDATE ax_probe_attempts SET mapping_key='invented.private.bundle'")
        db.commit()
        result = analyze(db, "invented-run")
        self.assertEqual(list(result["apps"]), [hashlib.sha256(b"invented.private.bundle").hexdigest()])
        self.assertNotIn("invented.private.bundle", json.dumps(result))
        self.assertEqual(result, analyze(db, "invented-run"))
        db.close()

    def test_empty_run_has_no_apps_and_explicit_empty_browser_dimensions(self):
        db = sqlite3.connect(self.path)
        db.execute("DELETE FROM ax_probe_attempts")
        result = analyze(db, "invented-run")
        self.assertEqual(result["apps"], {})
        self.assertEqual(result["overall"]["opportunities"], 0)
        for group in result["browser"].values():
            self.assertEqual(group["opportunities"], 0)
            self.assertIsNone(group["ax_text_yield"])
        db.close()

    def test_chunked_node_parts_are_analyzed_without_loading_text_blobs(self):
        db = sqlite3.connect(self.path)
        db.executescript("CREATE TABLE ax_probe_parts(attempt_row INTEGER,ordinal INTEGER,hash TEXT); CREATE TABLE ax_probe_chunks(hash TEXT,ordinal INTEGER,text TEXT);")
        header = pair([], storageVersion=3, axScalars=20, ocrScalars=11, ocr="")
        header["ax"]["text"] = ""
        db.execute("UPDATE ax_probe_attempts SET payload=?", (json.dumps(header),))
        db.execute("INSERT INTO ax_probe_parts VALUES(1,0,'invented-part')")
        nodes = [node(10, unselectedBranch=True, readSeconds=.004), node(10, hiddenBranch=True, readSeconds=.008)]
        for n in nodes:
            n["attributes"][0].pop("text")
            n["attributes"][0]["textRef"] = "missing-blob-never-read"
        db.execute("INSERT INTO ax_probe_chunks VALUES('invented-part',0,?)", (json.dumps(nodes),))
        db.commit()
        analysis = analyze(db, "invented-run")
        result = analysis["overall"]
        db.close()
        self.assertEqual(result["ax_characters"], 20)
        self.assertEqual(result["nodes"], 2)
        self.assertEqual(result["node_read_seconds"]["n"], 2)
        self.assertEqual(result["node_read_seconds"]["p50"], .006)
        self.assertEqual(result["node_read_seconds"]["p95"], .008)
        self.assertEqual(result["hidden_branch_share"], .5)
        self.assertEqual(result["unselected_branch_share"], .5)
        self.assertEqual(result["ax_text_yield"], 1)
        for group in (analysis["apps"][self.key], analysis["browser"]["true"],
                      analysis["apps"][self.key]["browser"]["true"]):
            self.assertEqual(group["nodes"], 2)
            self.assertEqual(group["hidden_branch_share"], .5)

    def test_copy_guards_reject_sidecars_links_basename_override_and_public_file(self):
        for suffix in ["-wal", "-shm", "-journal", ".recorder-lock"]:
            side = Path(str(self.path) + suffix); side.touch()
            with self.assertRaises(ValueError): database_copy(self.path)
            side.unlink()
        link = self.root / "link.sqlite"; link.symlink_to(self.path)
        with self.assertRaises(ValueError): database_copy(link)
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(ValueError): database_copy(self.path)
        link.unlink()
        with patch.dict(os.environ, {"ACTIVITYPROBE_DB": str(self.path)}):
            with self.assertRaises(ValueError): database_copy(self.path)
        self.path.chmod(0o644)
        with self.assertRaises(ValueError): database_copy(self.path)
        self.path.chmod(0o600)
        live = self.root / "activity.sqlite"; self.path.rename(live)
        with self.assertRaises(ValueError): database_copy(live)

    def test_optional_map_and_cli_without_manifest_emit_only_counts(self):
        self.assertEqual(read_map(None), {})
        mapping = self.root / "map.json"; mapping.write_text('{"bundles":{"INVENTED.BUNDLE":"Local label"}}'); mapping.chmod(0o600)
        self.assertEqual(read_map(mapping), {self.key: "Local label"})
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("ax_probe_analysis.py")),
                                 "--database-copy", str(self.path), "--run", "invented-run"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Invented", result.stdout)
        self.assertNotIn("invented.bundle", result.stdout)
        output = json.loads(result.stdout)
        self.assertEqual(output["apps"][self.key]["opportunities"], 1)
        self.assertEqual(output["browser"]["true"]["opportunities"], 1)
        self.assertNotIn("Local label", result.stdout)
        labeled = subprocess.run([sys.executable, str(Path(__file__).with_name("ax_probe_analysis.py")),
                                  "--database-copy", str(self.path), "--run", "invented-run",
                                  "--label-map", str(mapping)], capture_output=True, text=True)
        self.assertEqual(labeled.returncode, 0, labeled.stderr)
        self.assertEqual(json.loads(labeled.stdout)["apps"][self.key]["label"], "Local label")
        self.assertNotIn("INVENTED.BUNDLE", labeled.stdout)
        self.assertNotIn(str(self.path), labeled.stdout)

    def test_label_map_requires_private_file_and_string_labels(self):
        mapping = self.root / "map.json"
        for value in ([], {"invented.bundle": 1}, {"invented.bundle": ""}, {"bundles": []}):
            mapping.write_text(json.dumps(value)); mapping.chmod(0o600)
            with self.assertRaises(ValueError): read_map(mapping)
        mapping.write_text('{"invented.bundle":"Local label"}'); mapping.chmod(0o600)
        self.assertEqual(read_map(mapping), {self.key: "Local label"})
        mapping.chmod(0o644)
        with self.assertRaises(ValueError): read_map(mapping)


if __name__ == "__main__":
    unittest.main()
