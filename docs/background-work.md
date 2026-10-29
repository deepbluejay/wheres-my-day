# Background work

These rules apply to every repeated job in the recorder: the 5-minute maintenance tick,
agent-log scans, Git backfill, discovery and history, retention, summaries, and any later
queue.

They come from a live failure. One deleted log of about 560 MB stayed in
metadata recovery. While any checkpoint was in recovery, the Git stored pass never saved
its marks, so every tick reread about 149,000 events and 8,121 checkpoints from zero. The
recorder averaged about 40-55% CPU for most of a day. No data was lost.

## 1. Save progress per item, not per pass

- A pass saves its progress as it goes, and a repeat starts from the saved marks.
- One item that cannot finish is set aside with its own state. It never holds back the
  mark for every other item.

In the code:
- The Git stored pass (`GitCollectionTask.backfillStored`) saves the stored-events mark and
  the checkpoint mark at the end of every complete pass. Rows whose source is in metadata
  recovery are not offered, and neither mark waits for them.
- Each source's own recovery (`recover`) keeps its own mark and a finished receipt, so a
  restart does not offer it again.
- Metadata recovery saves each 1 MiB it reads in the checkpoint.

## 2. Every retry has an end state and a growing interval

- Each item that can fail or wait has a terminal or parked state.
- Retries back off.
- An input that no longer exists stops being worked on. One known exception: a Git
  folder row that validation refuses (for example, first seen before the retention
  cutoff, or its source in recovery) is validated again every tick. Remembering a refusal
  would need every input that can lift it in the digest, Secure Input included; live
  this costs 3-15 visits per tick.
- Slow work has a bounded budget per tick, and its progress is saved.
- Every check sorts an item into one of three outcomes:
  - **ready**: do the work;
  - **invalid**: the input is gone or replaced, so finish the item for good;
  - **retryable**: unreadable right now, so back off and count an attempt.
- Backoff never delays a forget, pause or exclusion. Those apply at once.

In the code:
- A Git working folder is `ready`, `missing`, `unversioned` or `failed`. A failed read is
  retried after 5 minutes, doubling up to once a day (`GitCollectionTask.retryDelay`).
- A checkpoint in metadata recovery whose log no agent-log reader lists is parked in
  memory, once every reader has listed in this process. The stored pass then no longer
  repeats for it. A later listing of the same log resumes it.
- Metadata recovery reads at most 64 MiB per file and 128 MiB across all files per scan
  (`recoveryBatchesPerScan`, `recoveryBudgetPerScan`). Files still in recovery wait for
  later scans. Only a read that continues the stored position counts. A file whose
  recovery read failed is tried again without charge while its inputs are unchanged, so
  files that fail every read cannot starve the others. At most 4 such free retries run
  per scan (`freeRecoveryRetriesPerScan`); later ones are charged.
- Stopping the recorder ends a running agent-log scan before its next 1 MiB batch, and a
  running Git pass at its next cancellation check.
- Recording off or paused is checked before and after every batch, and by every Git page
  and publication.

## 3. Skip unchanged input

- Before redoing work, compare a cheap fingerprint with the last run that did nothing.
- Work only on what changed. Steady cost per tick is proportional to what changed, not to
  what is stored.
- Any privacy-relevant change invalidates the skip, so exclusion, forget and pause still
  apply.
- Skip fingerprints hold no content. They live in memory only and are dropped when a
  change invalidates them.

In the code:
- **Agent-log scan** (`AgentLogTask`). A file is skipped when its last read in this process
  found nothing, was not deferred, and its output equalled its input, and since then:
  - its stat is unchanged: device, inode, size, mtime and ctime in nanoseconds;
  - its stored checkpoint is unchanged;
  - no receipt it consults was added.

  Receipts are handled like this:
  - An added receipt name rereads only the files whose candidate names contain it: the
    path, the homes above it, sessions in the file name, and the checkpoint's sessions.
  - An added own-source row rereads only the files with its device and inode. A summary
    call adds one for its own transcript, plus two session names no listed log consults,
    so it rereads at most that transcript.
  - Any other change to the ownership tables (own baseline, own sources, revoked
    sessions) rereads every file. So does a removed receipt name.
  - A receipt registered while the names are listed rereads every file in that scan.
  - The first scan after a start reads every file once.
- **Git discovery** (`GitCollectionTask.discoverAllowed`). A folder is skipped when its last
  visit passed validation and left nothing to do, and since then these are unchanged:
  - its folder row;
  - its source's checkpoint;
  - whether the folder exists;
  - for an unlinked folder, whether it is still outside every repository.

  The digest of these inputs is a one-way hash. Some changes revisit every folder:
  - receipts and the ownership tables;
  - recording settings and history;
  - forgotten ranges;
  - the retention day;
  - discovery tombstones.

  Folders in other states are visited every tick, such as a failed read in backoff, and
  so are folders that validation refused (section 2). A git init in an unversioned folder
  changes its walk, so the next tick finds it. One discovery tick shares one read-only
  database connection.
- **Git history** (`finishGitRead`). A repository whose refs equal its active frontier
  is not rewritten. One gated refresh moves the refs' observation time and `last_read`,
  as a rewrite would have.
  - "Equal" is every ref's identity, masked name and tip, compared whole. Any ref added,
    removed, renamed, moved or force-moved back, or a worktree HEAD on another commit,
    rewrites the frontier. A ref name long enough to be kept in chunks never compares
    equal.
  - The refs read from Git are held in memory until the last one, then compared, and
    staged through the gate only if they differ (`settleGitRefStage`). An unchanged
    repository costs the ref export plus one publication. Past 4096 refs or 4 MiB of
    names, every ref is staged as it is read and the staged refs are compared instead.
  - The compare reads 256 rows per hold of the storage lock, with a cancellation check
    between pages.
  - The refresh is refused like a rewrite: recording off or paused (current and
    historical), Secure Input, forget, retention, revocation and own sources. It also
    needs the same frontier active, nothing pending, and the same ref count, so a forget
    or retention that removed refs meanwhile makes the next read rewrite.
- **Git ownership** (`reconcileGitOwnership`, inside every Git publication). Candidates
  found absent from the receipt registry are not looked up again while the registry
  state is unchanged. That state is the registry folder's stat (device, inode, link
  count, mtime and ctime in nanoseconds) plus the own baseline's count, min and max.
  - A selector (repository, folder id or identity) found holding no owned row is skipped
    while the state and the Git source revision are unchanged. The source revision moves
    with any write to the folder rows, revocations, own sources, positions and
    discovery tombstones.
  - The key assumes APFS and an insert-only own baseline. Off APFS, nothing is
    remembered and every candidate is looked up.
  - Each set is cleared at 65,536 entries.
- **Summaries** (`SummaryService.plan`). Summaries start from 0, so each pass plans over
  every stored sample. Planning reads only the time, input counts, keeping awake and
  exclusion of each sample (`planningSamples`). This cost still grows with what is stored:
  about 1 s of CPU per pass at 21 invented days.

## 4. Measure it

- Each stage records its thread CPU time and item counts. `status` shows them:
  - `stage_<name>_last_*` covers the latest maintenance tick;
  - `stage_<name>_total_*` covers the time since the recorder started;
  - `stage_usage_at` is the time of the last tick.
- The stages:

  | Stage | Items |
  |---|---|
  | `agent_logs_claude`, `agent_logs_codex` | `listed`, `reads`, `skipped`, `recovery_reads` |
  | `git_discovery`, `git_backfill`, `git_history` | `visited`, `skipped`; `rows`, `checkpoints`, `offers`; `commits` |
  | `retention`, `summaries` | `removed`; runs only |
  | `screen_collection`, `sample_collection` | `ocr`, `writes`; `writes` |

- `front_*` counts how the front application was read since the recorder started, by the
  probe gate and by each tick's front observation, which share one read:
  - checks of the front-process call against NSWorkspace (`front_comparisons`,
    `front_disagreements`), after 3 s with no switch or after 8 switches, at most once
    per 5 s;
  - main-thread answers by cause (`front_fallback_missing_symbol`, `_error`,
    `_no_identity`, `_changed_during_lookup`);
  - `front_fast_path_disabled=1` once 3 disagreements in a row turned the call off.
- The figures sit in a file beside the database, rewritten once per tick. They hold only
  numbers and stage names.
- After every live deploy, check CPU for at least 30 minutes, across several ticks, before
  calling the deploy settled.
- These numbers are only recorded. No cap or automatic stop reads them.

## Review standard

A sustained per-tick cost on a realistic owner-scale path is must-fix, in the same class
as an hour-scale stall. That means a cost that does not shrink to "proportional to change"
once steady.

Each new background job's tests include a steady-state measurement on an owner-shaped
fixture with messy data:
- deleted files;
- one very large file;
- thousands of stale positions;
- one stuck item.

`GitCollectionTests.testOwnerShapeSteadyTickCost` is that measurement for the agent-log
and Git stages. It runs only with `ACTIVITYPROBE_OWNER_CPU=1`.
