"""Prove the unchanged-read tests catch a broken skip, in an owned copy of the source.

Run explicitly: each mutant rebuilds. Each must compile and fail every test named for it.
A build failure, or a pass of any named test, stops the run.

    python3 tools/test_git_unchanged_read_mutations.py [--only NAME ...] [--build-from .build]
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFTPM = str(pathlib.Path(__file__).with_name('swiftpm'))  # names the build system; see that file
REFS = 'Sources/Inbound/GitRefState.swift'
TASK = 'Sources/Shell/GitCollectionTask.swift'
STORE = 'Sources/Storage/GitCollection.swift'
SCHEMA = 'Sources/Storage/Schema.swift'
SKIP = 'if let fingerprint, (try? storage.gitReadUnchanged(repo: repo.id, fingerprint: fingerprint, now: now)) == true {'
WALK = '''guard let refs = try? GitRefState.digest(commonDirectory: directory, check: {
      try self.cancellation.check()
      try self.duringFingerprint?()
    }), let inputs'''
BACKFILL = '    requestStoredBackfill(at: now)\n    // Any change'
QUERY_DOUBT = 'testAnyDoubtInTheStoredStateRefusesTheSkip'

# name, [(file, before, after)], tests that must fail.
MUTANTS = [
    ('never-skips', [(TASK, SKIP, 'if let fingerprint, fingerprint.isEmpty {')], ['testUnchangedRepositoryStartsNoGitChildAndWritesNothing', 'testDigestSurvivesARestart']),
    # No commit lost.
    ('refs-not-walked', [(REFS, 'try walk.tree("refs") else', 'try walk.add("refs") else')],
     ['testNewCommitIsReadOnTheNextRun', 'testNewCommitByAnyAuthorIsRead', 'testForcePushIsRead', 'testDeletedRefIsRead', 'testRefMovedBackAndForthIsReadEachTime',
      'testFetchIsRead', 'testSameRefCountWithDifferentTargetsIsRead']),
    # A rebase rewrites HEAD as well as the branch, so it takes both guards gone to miss one.
    ('refs-and-head-not-read', [(REFS, 'guard try walk.add("HEAD"), try walk.tree("refs") else', 'guard try walk.add("refs") else')], ['testRebaseIsRead']),
    ('packed-refs-not-read', [(REFS, '["packed-refs", "config",', '["config",')],
     ['testPackedRefsTargetsSwappedInPlaceAreRead', 'testPackedRefsRewriteWithNoChangeReadsOnceAndChangesNothing']),
    ('config-not-read', [(REFS, '"packed-refs", "config", "config.worktree"', '"packed-refs", "config.worktree"')],
     ['testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads']),
    ('shallow-not-read', [(REFS, '"config.worktree", "shallow"]', '"config.worktree"]')], ['testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads']),
    ('unknown-format-vouched', [(REFS, 'guard knownRefFormat(common + "/config") else { return nil }\n', '\n')], ['testDigestCannotVouchForWhatItCannotSee']),
    ('head-not-read', [(REFS, 'guard try walk.add("HEAD"), try walk.tree("refs")', 'guard try walk.tree("refs")')], ['testCommitOnADetachedMainHeadIsRead']),
    ('worktree-reftable-not-read', [(REFS, '_ = try walk.tree("worktrees/\\(id)/reftable")', '')],
     ['testCommitOnADetachedReftableWorktreeHeadIsReadBeforeItIsLeft', 'testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads']),
    ('worktree-gitdir-not-read', [(REFS, '["HEAD", "gitdir", "commondir",', '["HEAD", "commondir",')],
     ['testMovedOrLockedWorktreeIsRead', 'testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads']),
    ('worktree-lock-not-read', [(REFS, '"commondir", "locked", "config.worktree"]', '"commondir", "config.worktree"]')],
     ['testMovedOrLockedWorktreeIsRead', 'testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads']),
    ('worktrees-not-read', [(REFS, 'if try walk.add("worktrees") {', 'if walk.root.isEmpty {')], ['testCommitOnADetachedWorktreeHeadIsRead', 'testNewWorktreeIsRead']),
    ('digest-after-read', [(TASK, 'outcome: .accounted, fingerprint: read.fingerprint)', 'outcome: .accounted, fingerprint: readFingerprint(repo, shared: shared))')],
     ['testCommitMadeDuringAReadIsReadOnTheNextRun']),
    ('symlinks-pass', [(REFS, 'guard kind == S_IFREG || kind == S_IFDIR, info.st_dev == device else', 'guard info.st_dev == device else')], ['testDigestCannotVouchForWhatItCannotSee']),
    ('index-counts', [(REFS, '["packed-refs", "config",', '["index", "packed-refs", "config",')], ['testEverydayGitWorkThatMovesNoRefCostsNoRead']),
    # Privacy is live.
    # Not the new-receipt test: discovery removes the folder, and a repository without one is not visited.
    ('no-policy-inputs', [(TASK, '[directory, refs, inputs].joined', '[directory, refs, inputs.isEmpty ? "" : ""].joined')],
     ['testRecordingOffAndOnAppliesAtTheNextRun', 'testForgetOfAnEmptyRangeStillIsReadNext', 'testRetentionChangeAppliesAtTheNextRun', 'testRetentionCutoffMovingADayIsReadAgain',
      'testChangedFolderAuthorityIsReadAgain', 'testMaskChangeRewritesStoredNamesAtTheNextRun']),
    # Only the history fingerprint's copy of ownership; discovery keeps its own.
    ('no-history-ownership', [(STORE, 'for part in [shared, gitMaskRevision, String(repo)]', 'for part in [String(shared.drop { $0 != "|" }), gitMaskRevision, String(repo)]')],
     ['testReceiptBetweenDiscoveryAndHistoryIsReadByHistory']),
    ('no-mask-input', [(STORE, 'for part in [shared, gitMaskRevision, String(repo)]', 'for part in [shared, String(repo)]')], ['testMaskChangeRewritesStoredNamesAtTheNextRun']),
    ('no-folder-authority', [(STORE, 'hash.update(data: Data("\\(try $0.int("id")):\\(try $0.text("ownership_authority"))|".utf8))', '_ = try $0.int("id")')], ['testChangedFolderAuthorityIsReadAgain']),
    ('no-ownership-input', [(STORE, 'var parts = [ownership, String(policy.generation),', 'var parts = [ownership.isEmpty ? "" : "", String(policy.generation),')], ['testNewOwnReceiptAppliesAtTheNextRunWithoutARefChange']),
    ('no-cutoff-day', [(STORE, 'String(Int((Double(try gitRetentionCutoff(now: now)) / 86400).rounded(.down)))]', '""]')], ['testRetentionCutoffMovingADayIsReadAgain']),
    ('no-forget-input', [(STORE, 'String(policy.retentionDays), String(policy.forgottenRevision),', 'String(policy.retentionDays),'),
      (STORE, 'parts += [String(try connection.integer("SELECT count(*) FROM forgotten_ranges")),', 'parts += [')], ['testForgetOfAnEmptyRangeStillIsReadNext']),
    ('no-lifetime', [(STORE, "?-f.read_at<?", "?-f.read_at<?*100000")], ['testUnchangedReadLifetimeEndsInAFullRead', 'testRefsOutliveTheShortestRetentionWhenNothingChanges']),
    ('no-clock-check', [(STORE, 'AND f.read_at<=? AND ?-f.read_at<?', 'AND ?<>0 AND ?-f.read_at<?')], ['testClockSetBackReadsAgain']),
    # What a skip leaves, and what stops one.
    ('skip-writes', [(TASK, 'historySkips += 1\n', 'historySkips += 1; try storage.gitReopenBlocked(repo: repo.id, blocked: false, now: now)\n')], ['testUnchangedRepositoryStartsNoGitChildAndWritesNothing']),
    ('saved-on-failure', [(TASK, 'pending.removeValue(forKey: repo.id); completed.insert(repo.id)\n          // Only an actual', 'let lost = pending.removeValue(forKey: repo.id)?.fingerprint; completed.insert(repo.id)\n          // Only an actual'),
      (TASK, 'try storage.finishGitRead(repo: repo.id, now: now, outcome: outcome)', 'try storage.finishGitRead(repo: repo.id, now: now, outcome: outcome, fingerprint: lost)'),
      (STORE, '    var outcome = finish\n    defer { try? gitLocked {', '''    var outcome = finish
    if finish != .accounted, let fingerprint { try gitLocked { try connection.run("INSERT OR REPLACE INTO git_read_fingerprints SELECT id,?,frontier,(SELECT count(*) FROM git_refs x WHERE x.repo_id=r.id AND x.frontier=r.frontier),? FROM git_repositories r WHERE id=?", [.key(fingerprint), .integer(now), .integer(repo)]) } }
    defer { try? gitLocked {''')], ['testInterruptedReadSavesNothingAndTheNextRunFinishesIt', 'testStoppedFirstReadResumesAfterARestart']),
    ('ignores-frontier', [(STORE, "AND f.frontier=r.frontier AND r.frontier!=''", "AND r.frontier!=''")], [QUERY_DOUBT]),
    ('ignores-pending', [(STORE, " AND r.pending_frontier=''\n          AND r.reopen_blocked", "\n          AND r.reopen_blocked")], [QUERY_DOUBT]),
    ('ignores-blocked', [(STORE, 'AND r.reopen_blocked=0 AND f.read_at', 'AND f.read_at')], [QUERY_DOUBT]),
    ('ignores-incomplete', [(STORE, 'AND NOT EXISTS(SELECT 1 FROM git_commits c WHERE c.repo_id=r.id AND c.complete!=1)\n', '\n')], [QUERY_DOUBT]),
    ('ignores-ref-count', [(STORE, 'AND f.ref_count=(SELECT count(*) FROM git_refs x WHERE x.repo_id=r.id AND x.frontier=r.frontier)\n', '\n')], [QUERY_DOUBT, 'testRefsRemovedBehindTheDigestAreReadAgain']),
    ('ignores-permission', [(STORE, 'try gitAllowed(now), try gitRepositoryPermitted(repo) else { return false }', 'try gitAllowed(now) else { return false }')], [QUERY_DOUBT]),
    ('no-raw-path-guard', [(TASK, 'guard raw != nil || !repo.needsRawDirectory else { return nil }\n', '')], ['testRepositoryWithoutItsRawPathIsNotSkipped']),
    ('skip-before-copy-check', [(TASK, 'if try refusedAsCopy(repo: repo.id, directory: repo.directory, now: now) {\n            if pending',
      'if let early = readFingerprint(repo, shared: shared), (try? storage.gitReadUnchanged(repo: repo.id, fingerprint: early, now: now)) == true { historySkips += 1; completed.insert(repo.id); continue }\n          if try refusedAsCopy(repo: repo.id, directory: repo.directory, now: now) {\n            if pending')],
     ['testCopyRefusalAppliesToARepositoryThatWouldBeSkipped']),
    ('skips-discovery', [(TASK, BACKFILL, 'if let repo = try storage.nextGitRepository(after: 0), let early = readFingerprint(repo, shared: try storage.gitDiscoveryRevision(now: now)), try storage.gitReadUnchanged(repo: repo.id, fingerprint: early, now: now) { return }\n' + BACKFILL)],
     ['testBackfillAdvancesOnARepositoryWhoseRefsDidNotChange']),
    # A restart.
    ('memory-only', [(TASK, SKIP, 'if let fingerprint, historyReads > 0, (try? storage.gitReadUnchanged(repo: repo.id, fingerprint: fingerprint, now: now)) == true {')], ['testDigestSurvivesARestart']),
    ('schema-not-repaired', [(SCHEMA, ",'git_read_fingerprints','git_read_fingerprint_cleanup')\") != 28", ")\") != 26")], ['testLostOrSpoiledDigestReadsOnceAndIsWrittenAgain']),
    ('no-cleanup-trigger', [(STORE, 'try run("CREATE TRIGGER IF NOT EXISTS git_read_fingerprint_cleanup AFTER DELETE ON git_repositories BEGIN DELETE FROM git_read_fingerprints WHERE repo_id=OLD.id; END")\n', '\n')], ['testDeletingARepositoryDeletesItsDigest']),
    # Where it runs.
    ('git-child-in-digest', [(TASK, 'let directory = raw ?? repo.directory\n    guard let refs', '_ = try? reader.insideWorkTree(raw ?? repo.directory)\n    let directory = raw ?? repo.directory\n    guard let refs')], ['testUnchangedRepositoryStartsNoGitChildAndWritesNothing']),
    ('no-stop-check', [(REFS, 'if seen % checkInterval == 0 { try check() }', '')], ['testDigestChecksForAStopWhileWalking', 'testDigestRunsOnTheGitQueueWithNoLockHeldAndStops']),
    ('walk-under-lock', [(TASK, WALK, 'guard let refs = try? storage.mutantLocked({ try GitRefState.digest(commonDirectory: directory, check: {\n      try self.cancellation.check()\n      try self.duringFingerprint?()\n    }) }), let inputs'),
      (STORE, 'public struct GitBackfillReceipt {', 'extension ActivityStorage { public func mutantLocked<T>(_ body: () throws -> T) rethrows -> T { try locked(body) } }\npublic struct GitBackfillReceipt {')],
     ['testDigestRunsOnTheGitQueueWithNoLockHeldAndStops']),
    ('walk-on-maintenance-thread', [(TASK, BACKFILL, 'if let repo = try storage.nextGitRepository(after: 0) { _ = readFingerprint(repo, shared: try storage.gitDiscoveryRevision(now: now)) }\n' + BACKFILL)],
     ['testDigestRunsOnTheGitQueueWithNoLockHeldAndStops']),
]


def run(names, cwd, log):
    pattern = '|'.join('GitCollectionTests.' + name + '$' for name in names)
    with log.open('w') as output:
        try:
            result = subprocess.run([SWIFTPM, 'test', '--jobs', '4', '--filter', pattern], cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=900)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = None
    return code, log.read_text(errors='replace')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', nargs='*')
    parser.add_argument('--build-from', type=pathlib.Path, help='an existing .build whose fetched packages to reuse')
    parser.add_argument('--keep-going', action='store_true', help='report a surviving mutant and go on')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='activityprobe-git-idle-mutants-') as temporary:
        copy = pathlib.Path(temporary) / 'source'
        copy.mkdir()
        logs = pathlib.Path(temporary) / 'logs'
        logs.mkdir()
        for directory in ('Sources', 'tests', 'tools', 'Plugins', 'Resources', 'release'):
            if (ROOT / directory).exists():
                shutil.copytree(ROOT / directory, copy / directory, ignore=shutil.ignore_patterns('__pycache__', '.DS_Store'))
        for name in ('Package.swift', 'Package.resolved'):
            shutil.copy2(ROOT / name, copy / name)
        if args.build_from:
            # Compiled modules are tied to their folder, so only the fetched packages carry over.
            (copy / '.build').mkdir()
            for name in ('checkouts', 'repositories', 'artifacts', 'workspace-state.json'):
                if (args.build_from / name).exists():
                    subprocess.run(['cp', '-cR', str(args.build_from / name), str(copy / '.build' / name)], check=True)
        chosen = [m for m in MUTANTS if not args.only or m[0] in args.only]
        survived = []
        for name, edits, tests in chosen:
            originals = {}
            try:
                for file, before, after in edits:
                    path = copy / file
                    text = path.read_text()
                    originals.setdefault(path, text)
                    if text.count(before) != 1:
                        raise AssertionError(name + ': anchor is not unique in ' + file + ': ' + before[:60])
                    path.write_text(text.replace(before, after))
                code, output = run(tests, copy, logs / (name + '.log'))
                if code is None:
                    missed = ['timed out']
                elif 'error: fatalError' in output or 'Compiling' in output and 'Build complete!' not in output and 'Test Suite' not in output:
                    raise AssertionError(name + ': did not build\n' + '\n'.join(l for l in output.splitlines() if 'error:' in l)[:2000])
                else:
                    missed = [test for test in tests if test + ']' not in ' '.join(l for l in output.splitlines() if ' error: ' in l)]
                if missed:
                    print(name + ': SURVIVED ' + ', '.join(missed), flush=True)
                    survived.append(name)
                    if not args.keep_going:
                        raise AssertionError(name + ' survived')
                else:
                    print(name + ': killed by ' + ', '.join(tests), flush=True)
            finally:
                for path, text in originals.items():
                    path.write_text(text)
        if survived:
            raise SystemExit('survived: ' + ', '.join(survived))
        print('all %d mutants killed; copied source deleted on exit' % len(chosen), flush=True)


if __name__ == '__main__':
    main()
