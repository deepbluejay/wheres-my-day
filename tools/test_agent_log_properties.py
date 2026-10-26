#!/usr/bin/env python3
"""Prove generated invariants bite using isolated, deliberately broken source copies."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
MUTATIONS = [
    ("outbound-string-membership", "Sources/Outbound/ConversationIdentityMap.swift",
     "get { entries[conversationIdentity(raw)]?.value }", "get { entries.values.first { $0.raw == raw }?.value }",
     "OutboundOwnershipInvariantTests.testGeneratedOutbound"),
    ("identity-byte-equality", "Sources/Core/AgentLogIdentity.swift",
     "lhs.storedKey.utf8.elementsEqual(rhs.storedKey.utf8)", "lhs.storedKey == rhs.storedKey",
     "testGeneratedDecodedBytesHaveOneKeyAcrossEveryPathWithoutMerging"),
    ("unusable-session-inheritance", "Sources/Core/AgentLogTransitions.swift",
     "state.session = facts.session.subject", "state.session = facts.session.subject ?? state.session",
     "testGeneratedSessionTransitionsIgnoreRoleChunkingAndRestart"),
    ("ownership-subject-scope", "Sources/Storage/AgentLogEvents.swift",
     "WHERE s.tool=? AND s.session_id=?", "WHERE s.tool=? AND (? IS NOT NULL)",
     "testGeneratedPositiveOwnershipAffectsOnlyProvenSubjectsAndSources"),
    ("explicit-edge-loss", "Sources/Storage/AgentLogIdentity.swift",
     "INSERT OR IGNORE INTO agent_prompt_edges VALUES(?,?)", "INSERT OR IGNORE INTO agent_prompt_aliases VALUES(?,?)",
     "testGeneratedExplicitEdgesSurviveOrderingAndPrivacyClosure"),
    ("permanent-refusal-bypass", "Sources/Storage/AgentLogAdmission.swift",
     "legacyLogAdapter.refused(subject.legacy) || logComponentRefused()", "legacyLogAdapter.refused(subject.legacy)",
     "testGeneratedForgetOffPauseAreMonotoneButRetentionIsNot"),
    ("transaction-partial-commit", "Sources/Storage/SQLiteConnection.swift",
     'try? run("ROLLBACK")', 'try? run("COMMIT")',
     "testGeneratedTransactionAbortsRollBackEventsProjectionRefusalsAndCursor"),
    ("unindexed-occurrence-cleanup", "Sources/Storage/AgentLogEvents.swift",
     "DELETE FROM evidence INDEXED BY evidence_prompt_id WHERE kind='prompt' AND source_id>=? COLLATE BINARY AND source_id<? COLLATE BINARY",
     "DELETE FROM evidence WHERE kind='prompt' AND source_id>=? COLLATE BINARY AND source_id<? COLLATE BINARY",
     "testGeneratedWriterWorkIsIndependentOfUnrelatedPromptsAtOwnEOF|AgentLogTests.testLegacyOccurrenceCleanupUsesFullIndexedByteExactDeletePlan"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Keep a JSON summary outside the temporary copy")
    parser.add_argument("--temp-root", type=Path, help="Parent for the disposable source and build copies")
    args = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix="activityprobe-property-mutations-", dir=args.temp_root) as folder:
        base = Path(folder)
        copy = base / "copy"
        copy.mkdir()
        for name in ("Sources", "tests", "tools", "Plugins"):
            shutil.copytree(REPO / name, copy / name)
        shutil.copy2(REPO / "Package.swift", copy / "Package.swift")
        for name, source, before, after, test in MUTATIONS:
            path = copy / source
            original = path.read_text()
            if before not in original:
                raise AssertionError(f"Mutation target disappeared: {name}")
            try:
                path.write_text(original.replace(before, after))
                test_filter = test if test.startswith("OutboundOwnershipInvariantTests.") else "AgentLogTests." + test
                run = subprocess.run(["swift", "test", "--jobs", "1", "--scratch-path", str(base / "build"),
                                      "--filter", test_filter], cwd=copy,
                                     capture_output=True, text=True)
                output = run.stdout + run.stderr
                witnesses = [line for line in output.splitlines() if "minimal trace=" in line or "error:" in line]
                # A compile error is not a counterexample. Require an XCTest assertion failure.
                if run.returncode == 0 or "Test Suite 'Selected tests' failed" not in output or not witnesses:
                    raise AssertionError(f"Mutation did not produce an assertion failure: {name}\n{output[-6000:]}")
                result = dict(mutation=name, test=test, witnesses=witnesses)
                results.append(result)
                print(f"{name}: caught, {len(witnesses)} failing assertions", flush=True)
            finally:
                path.write_text(original)
        run = subprocess.run(["swift", "test", "--jobs", "1", "--scratch-path", str(base / "build"),
                              "--filter", "AgentLogTests.testGenerated|AgentLogTests.testLegacyOccurrenceCleanup|OutboundOwnershipInvariantTests"],
                             cwd=copy, capture_output=True, text=True)
        if run.returncode:
            raise AssertionError("Restored source copy failed:\n" + (run.stdout + run.stderr)[-6000:])
        print("Restored copy: all invariant/plan and outbound ownership tests passed", flush=True)
    if args.report:
        args.report.write_text(json.dumps(results, indent=2) + "\n")
    print("Mutation temporary folder deleted", flush=True)


if __name__ == "__main__":
    main()
