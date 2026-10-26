# Layer-1 recorder fidelity

`fidelity_check.py` measures whether independent agent logs and Git history are
represented in a recorder database. It is a Python 3.9+ standard-library developer
tool. SQLite must provide `octet_length`. The installed Swift compiler builds a
small private helper from the current product redactor and document-key method;
no external Python packages are required.
Counts retain their denominators; absence of a channel is not success. Optional
same-time references add Chrome visits, latest file mtimes and shell history.
An optional reference recorder adds focused attribution, informative-term recall,
input observations, and private local samples for a separate judging step.

```sh
python3 tools/fidelity_check.py /tmp/invented.sqlite \
  --claude-home /tmp/invented-claude --codex-home /tmp/invented-codex \
  --chrome-history /tmp/invented-chrome/History \
  --shell-history /tmp/invented-zsh-history --tolerance-seconds 5 \
  --from 2032-06-24 --to 2032-06-26 --timezone Asia/Seoul \
  > /tmp/fidelity-report.json 2> /tmp/fidelity-summary.txt
python3 tools/test_fidelity_check.py
python3 tools/test_fidelity_check.py --scaling  # invented 16/64/128 MiB corpora
python3 tools/test_fidelity_check.py --shell-scaling  # oversized untimed/zsh/Bash records
python3 tools/test_fidelity_check.py --input-scaling  # nine independent allocation dimensions
```

The database argument is required. Agent homes default to `~/.claude` and
`~/.codex`; repeat either option for additional homes. Only `projects/**/*.jsonl`
under Claude homes and `sessions/**/*.jsonl` / `archived_sessions/**/*.jsonl`
under Codex homes are read. It does not inspect credentials, login files,
processes, process environments, or recorder state. Tests always override homes
and use invented data. Do not point this tool at real data during development.

`--from` is inclusive, `--to` exclusive. Accept Unix seconds, ISO dates, or ISO
timestamps. Naive dates/times and per-day buckets use `--timezone` (default UTC).
Use offset-bearing timestamps or Unix seconds at ambiguous local clock changes.
JSON goes to stdout and a short text summary to stderr. Shell redirections are
optional; choose new destinations rather than any input file.

Chrome and shell-history sources are opt-in, repeatable arguments with no default
source opened. `--tolerance-seconds` controls C6–C8 (default 5, minimum 0);
C1/C2 always use ±1 second. File metadata roots come only from recorder document
keys. Additional terminal bundle IDs can be supplied using `--terminal-app`.

## No-text and read-only boundary

Reports contain only fixed category labels, tool types, dates, counts and ratios.
They never contain window titles, prompts, URLs, document paths, repository paths,
session names, source names, hosts, or raw exception messages. SHA-256 identities,
body digests, lengths and hashed eight-word shingles are used internally for
comparison; content never becomes report data. Identity matching does not prove
that masked text can be recovered or that changed text is equivalent.

**C12 is an explicit local-export exception:** only when `--bundle-dir` is given,
masked text is written into that caller-supplied private directory. It never
enters stdout, stderr or the numeric report, and is never transmitted. Both C10
and C12 call the product's actual Swift redactor, including every recognized
credential format, label and truncated private-key rule. Additional masking
covers structured secret fields and complete authorization payloads. The helper
is compiled locally in a private temporary directory and removed on exit.
Arbitrary secrets without recognizable structure can remain. Keep bundles
private, inspect masking before judging or sharing, and delete afterward.

Both recorder databases use direct `mode=ro`, `query_only=ON` connections with
250 ms busy timeouts and a 2 MiB SQLite cache. Reference SELECTs carry selected-day
or selected-window time bounds, honoring live WAL files without immutable mode.
No full reference or primary database copy is made. Busy/malformed errors retry
with a fresh connection. Reads across different queries are not an atomic snapshot.

Chrome histories first use SQLite backup with a 1-second lock/backup deadline before falling back. If a profile
is locked, History plus existing WAL/journal files are copied into a private
temporary directory, recovered there, and reopened read-only. This fallback is
best effort under concurrent browser writes; inconsistent/unreadable profiles
are counted as partial input, with readable/unreadable profile counts.

Lifetime log identities, shingle provenance, prompt allocations, click capacity,
one-way term/deletion identities and daily frequency state spill to private temporary SQLite with a
2 MiB cache. Repeated terms share one dictionary entry and frames store compact
integer references, rather than repeating their edit-distance signatures. Raw reference frame text is processed one frame at a time; only the
selected C12 windows fetch text for export. Samples are reusable time-bounded
cursors; C6–C8 timestamp indices and C12 selection populations also live on disk.
Screen recall visits one same-app evidence row at a time, retaining only matches
against the current frame's bounded term set. Recording/awake/exclusion histories
read the last state before the interval and stream transitions inside it;
random C12 state lookups fetch one predecessor. No lifetime history list or
sample-minute set is retained. Log lines over 1,048,576 bytes are skipped, counted,
and make C1/C2 explicitly partial. Temporary stores close and are deleted on
success or exception. Forced termination or power loss cannot guarantee cleanup.
Git history is also streamed with bounded output chunks; stored commit identity
lookups and capture-occurrence checks use SQLite rather than corpus-sized sets.
No migrations, recorder starts/stops, fetches or writes to source inputs occur.

All source SQL text/blob fields pass through one projection with a **256 KiB
byte cap**. It returns bounded `substr` values and `length` metadata, guarded
by `octet_length` before either function can allocate an oversized SQLite value.
The same CASE guard covers text functions in predicates, joins, ordering and
grouping. REAL-affinity columns also use read-only incremental-blob size metadata
before SQLite's implicit numeric conversion. Lifetime app/source identities and
reference timestamps are mapped once into bounded-cache on-disk state; reference
range queries use numeric timestamps and fetch source rows by integer rowid, so
oversized source-index keys cannot bypass the cap.
Screen evidence resolves its bundle ID using the latest sample at or before the
evidence timestamp, shared by C10 and C12. Renames and localized display names
therefore apply from their observed time, independent of insertion order.
Duplicate identical observations collapse. Missing predecessors, empty names,
or conflicting names at that latest timestamp fall back to the source's own
normalized identity, also supporting evidence that directly names an app.
Future samples never supply earlier names. Associations store only opaque
source/app identities and numeric timestamps; each indexed lookup reads at most
two rows, with no lifetime list retained in memory.
Oversized fields become unavailable empty values, preserving other fields and
the record's place in the population. Numeric rows count `oversized_fields` and
`affected_records` per check/day, and mark dependent measurements `partial_input`.
The C12 report also lists source/day counts. Source evidence in a tolerance halo
counts against each potentially affected selected day; unselected days outside
that halo do not affect the report. History-state limits and records without
trustworthy timestamps use a null day and make every potentially affected day partial. Agent-log skip counts whose
timestamps cannot be trusted are explicitly `oversized_source_lines_unplaced`.
Oversized or invalid SQL timestamps are counted before range filtering as
`unavailable_records_unplaced`, with `oversized_fields` or `invalid_timestamps`.
They make every dependent selected day partial.
JSONL and shell physical records share one chunk-discard reader, with 1 MiB and
64 KiB byte caps respectively. Untimed/unplaceable shell skips are identified
separately from skips attributed to a day.

C10 keeps at most **4,096 distinct terms per text record**. Later eligible token
occurrences count as `unsupported_term_occurrences`. Terms longer than **64
characters** retain exact SHA-256 comparison, with no fuzzy signatures, and count
as `exact_only_terms`. Both counts include reference and own evidence records
once per record/affected selected day and make recall partial. Own evidence
counts reach every selected day intersecting its inclusive ±60-second halo,
including across midnight and outside the requested date range. Each supported term has at most 64
deletion signatures. This bounds work as well as memory; exact-only terms still
participate in denominators. App totals spill to disk too; a day reports at most
128 individual app groups plus one combined overflow group. `app_group_count`
identifies that aggregation; all weighted and unweighted denominators survive.

C12 exports at most **100 windows**, with **256 records and 1 MiB of encoded
record data per channel per window** (whichever limit arrives first). It counts
every skipped record and unavailable field in each bundle and in report
`limits_by_day`; partial channels remain visible to the judge. Agent-event and
commit channel status carries its skip counts. The deletion manifest has a
1 MiB read cap. These limits apply only to this development measurement tool.

All time tolerances use the same exact fractional-second predicate,
`abs(observed - reference) <= tolerance`. Integer seconds are used only for
bucket selection, never to widen a ±1, ±5 or ±60-second comparison.

## Checks and denominators

* **C1:** typed human instructions with a key sample in the session's inferred
  app at instruction second ±1, divided by typed human instructions, by tool/day.
  Sender precedence follows RULES 13–15: tool marker, text provenance, same-app
  key at ±1 second, otherwise unknown. Agent/sidechain/parent-thread markers,
  metadata/notification lines and imported turns are excluded. Explicit human
  markers win over provenance. Queued human instructions are counted separately,
  outside the typed denominator, because delivery time need not be typing time.
  Codex messages without a queue marker are never classified using older keys.
* **C2:** typed human instructions with prompt evidence, divided by typed human
  instructions, by tool/day. Require the same source and a timestamp within ±1
  second, plus native identity or equal body digest (legacy compatibility).
  A conflicting native identity never matches by text; digest fallback requires
  a legacy identity on at least one side. Copied native Claude instructions can
  match any source copy observed in the reference logs. Evidence rows are allocated
  one-to-one with maximum-cardinality allocation, exact identities first, then
  legacy digest fallback. Reassignment preserves exact matches and avoids
  line-order-dependent misses, including copied-source aliases. C1/C2 include
  readable, malformed and unavailable source-file counts and partial-input reasons.
  Report equal-digest, equal-length and identity-matched/content-changed counts
  separately. Masked text can pass storage identity matching without passing
  content equality; equal lengths alone do not establish a match.
* **C3 attribution:** seconds with keys, clicks or scrolls missing app, window,
  document, or any attribution, divided by seconds with such human input.
  Lower is better. Duplicate seconds merge populated attribution fields.
  Excluded samples stay in this denominator, so intentional omissions remain
  visible rather than silently looking complete. Attribution is presence, not
  proof that a window/document identifier is correct.
* **C3 gaps:** full wall-clock minutes without samples, divided by full minutes
  known throughout all 60 seconds to be recording-enabled, unpaused, awake and
  not excluded. Lower is better. Unknown history minutes are counted separately;
  partial boundary minutes are omitted. Schema 9 lacks wake/exclusion history,
  so this metric reports `channel absent` rather than assuming sleep or a gap.
  `samples.keeping_awake` is not wake history.
* **C4:** reachable commits found in registered repositories and stored under
  the same repository identity, divided by reachable commits with committer
  timestamps in the requested range, by day. Uses read-only `git log --all`,
  without fetch, optional locks, pager, or fsmonitor. A commit present on several
  refs counts once per repository. Unreadable repositories make the result
  explicitly partial and are counted. Empty repositories have zero denominator.
* **C5:** acquired captures with stored occurrences, divided by acquired
  captures, by acquisition day. Deduplicate occurrences by capture identity.
  Recorder acquisition counters take precedence over acquisition-row counts
  when available, so admission losses cannot silently shrink the denominator.
  Dropped captures and admission losses are reported separately, never added to
  acquisition counts again. Ratios above 1 or negative counters are flagged as
  inconsistent, not clamped to a passing value.
* **C6:** Chrome visits whose URL has recorder document attribution at visit time
  ± the configured tolerance, divided by visits in the date range, by day.
  Compare one-way digests of lowercased host plus case-sensitive path; an empty
  or root path is omitted and trailing slashes are trimmed, matching the
  recorder's stored host/path keys. Paths stay case-sensitive. Query strings,
  credentials, fragments and schemes do not enter
  the digest. Full URLs call the exact current `RecorderPolicy.documentKey`
  Swift method through the private helper. Stored keys use that native identity
  directly, with host case ignored and path case preserved. This covers bare
  IPv6, IDN, Unicode domain separators, escaped hosts and decoded paths without
  a separate Python URL canonicalizer. C6, C9 and C12 use the same function.
  No URL is emitted.
  Chrome's microseconds-since-1601 timestamps are
  converted to Unix seconds. Non-HTTP(S) visits remain in the denominator as
  unmatched and are counted separately. Unreadable profiles make results partial.
* **C7:** files whose latest mtime has matching recorder file-document attribution
  at ± the configured tolerance, divided by files whose latest mtime lies in the
  date range. A recorded absolute document path or local `file:` URL establishes
  a known folder. Use its nearest containing repository (`.git` ancestor), or its
  containing folder when no repository is found. Discover roots once from the
  full requested recorder time scope, even when a known document was deleted
  but its containing folder survives. Scan these roots once and bucket latest
  mtimes by day, independently of each day's attribution. Inspect regular-file metadata
  recursively in these roots; do not open file contents or follow symlink files
  or symlink ancestors or descendant directories. Deduplicate overlapping roots, omit VCS and
  credential directories, count unavailable metadata, and never list any path.
  **This measures latest surviving mtimes, not all historical modifications.**
  Deleted files and earlier modifications cannot be recovered from filesystem
  metadata. Known document paths that no longer exist are counted separately.
* **C8:** timestamped shell-history commands with key samples in a terminal app
  at ± the configured tolerance, divided by timestamped history commands, by day.
  Read only the explicitly provided history files. Support zsh extended records
  (`: epoch:duration;...`) and Bash timestamp markers (`#epoch` then command).
  Zsh escaped multiline continuation is one command. Untimed lines are counted
  separately, never assigned a guessed timestamp. A history with only untimed
  lines reports `history not timestamped` and an unavailable denominator. Commands are never emitted or
  retained. Physical records are read with a 64 KiB bound; oversized bodies are
  discarded in chunks with only bounded timestamp/continuation state. Report
  oversized-record counts and mark C8 partial, or unavailable when no usable
  timestamped records survive. Common terminal bundle identities, explicit `--terminal-app` IDs and
  a future recorded `app_type=terminal` identify terminals; session-app inference
  for C1 does not use this list. History timestamps indicate execution, not exact
  typing time; shell history can also contain automated or imported commands.
* **C9:** focused reference frames matching a recorder app plus either a window
  title or document URL at ±1 second, divided by focused reference frames, per
  day. Compare normalized app names; never output those names. Missing samples,
  differing apps, and differing windows/documents are counted separately.
* **C10:** weighted informative-term recall against reference focused frames,
  per day and opaque app digest. Apply the common mask, NFKC/case normalization,
  then extract words of at least 3 letters, or 2 Hangul syllables; exclude
  numbers. For each term use `log(focused_frames_that_day / frames_with_term)`.
  A term on every reference frame has weight 0. Sum weights of reference terms
  found in our same-app screen evidence at ±60 seconds, divided by all reference
  term weights. Each term counts once per reference frame. Also report unweighted
  matched/total term counts for contrast. Allow edit distance at most 1 for
  reference terms at least 5 characters long, without exposing any term. If all
  terms have zero weight, weighted recall is unavailable, not 100%. This is an
  information proxy, not semantic judgment or a recorder optimization target.
* **C11:** observed reference clicks, window-focus and app-switch events divided
  by those reference events, per day/type. A click needs a same-app click count
  at ±1 second, consuming one recorded click for each matched reference click.
  Repeated reference event IDs count once; capacity is shared across adjacent
  seconds. Window focus needs a same-app observation plus matching title
  when supplied; app switch needs a same-app observation. Unknown event types
  do not become guessed human input. Agreement does not prove event identity.
* **C12:** export, without scoring, up to N shared 5-minute windows (default 20).
  Both recorders must have focused observations in the aligned window; windows
  must fit wholly within the requested date/time range. Stratify by day and
  reference main app, seeded shuffle within strata, then round-robin across
  strata. Record seed and selected start/end timestamps in the JSON report and
  local manifest so the same windows can be judged again.

## Reference comparison and private judging bundles

Use `--reference-database` with an explicit path; no default product or path is
encoded. The reference database is queried directly with `mode=ro`, never immutable
mode. Busy/malformed failures retry up to three times with fresh connections,
then become an explicit unavailable-channel reason. Supported reference
shapes are `frames(timestamp, app_name, window_name, browser_url, focused,
full_text, accessibility_text, text_source)` and `ui_events(timestamp,
event_type, app_name, window_title, element_role, element_name)`. Optional
`monitor_id` fields allow identifying another monitor; without monitor metadata
the tool does not infer that explanation. Timestamps accept ISO timestamps with
offsets or numeric Unix seconds. Source inputs are never modified.

For an invented historical baseline, select three local days:

```sh
python3 tools/fidelity_check.py /tmp/invented.sqlite \
  --reference-database /tmp/invented-reference.sqlite \
  --claude-home /tmp/invented-claude --codex-home /tmp/invented-codex \
  --from 2032-06-08 --to 2032-06-24 --timezone Asia/Seoul \
  --days 2032-06-08,2032-06-15,2032-06-23 \
  --bundle-dir /tmp/invented-private-bundles --bundle-count 20 --seed 42
```

For a later same-time post-deploy comparison, use `--window-from` and
`--window-to` instead of `--from` / `--to`, or alongside them to narrow the export
period. This marks bundles `same_time`; historical samples remain
`historical_baseline`. Time bounds may be Unix seconds or ISO timestamps. A seed
and unchanged inputs reproduce the selected windows; live inputs can change.

Bundle directories must be new or empty with mode 0700; files use mode 0600 and
exclusive creation. No existing file is overwritten. Export failures roll back
files created by that export. Each bundle contains masked reference frames,
our samples/evidence/prompts, and per-frame comparison metadata: focused per our
observations (`yes`, `no`, `other_monitor`, or `unknown`), nearby screen evidence,
document agreement and availability, nearby sample counts, recording/pause state
where history exists, and exclusion flags. The `ours.screen_evidence_context`
field includes clearly marked screen rows from the ±60-second halo outside the
window, so the judge can inspect evidence underlying nearby-evidence flags. `unknown` stays distinct from `no`.

`our_only_candidates` also carries prompts, agent events/payloads and stored
commits in the window for the judge's reverse-direction comparison. These are
candidates for judgment, not claims that every item is exclusive. Missing
agent/Git channels and unsupported timestamp columns are marked explicitly;
schema 9 cannot supply channels it never stored. No model runs and no judgment
or score is produced. Agent event/payload adapters use `agent_log_events` and
`agent_log_payloads(event_id, ...)`; event/commit time aliases are `ts`,
`timestamp`, `event_ts`, `committed_ts`, `commit_ts`, `committer_ts`, `committed_at`.

Delete only this tool's manifested bundle files afterward:

```sh
python3 tools/fidelity_check.py --delete-bundles /tmp/invented-private-bundles
```

Deletion rejects symlink files and unsafe manifest names, preserves unrelated
files, removes the manifest, and removes the directory if empty. The numeric
report retains only the seed and times, never the bundle directory or text.

App inference uses no app-name allowlist. Within the requested range (plus ±1
second at its edges), a session needs key votes at two or more instructions and
one app with at least 80% of votes. Otherwise pool inferred apps from at least
five sessions with the same tool and nonempty originator/entrypoint; one app must
have at least 80%. Unresolved apps never make a key-inferred human instruction.
Votes count each app at most once per instruction. Consequently, C1's
`classified_by_input` part is conditional on the same recorder data it checks;
the `classified_by_tool_marker` part is independent of key-based sender inference.
Both counts and unresolved-app counts are exposed rather than conflated.

Provenance compares SHA-256 hashes of sliding eight-word shingles, requiring at
least 50% of the candidate shingles in one preceding outbound tool call from a
different session. Too-short text falls through to keys. Also compare the
session's first six command outputs with calls preceding those outputs, to
recognize workers that retrieve their assignment after their initial setup.
Only outputs linked to known command calls qualify, not arbitrary file reads.
No development-session IDs are required. Copied native Claude identities and duplicate
Codex message representations count once; distinct native instructions survive.
Logs are scanned read-only, but are not an atomic snapshot of concurrently
changing log files. Unreadable/malformed input is counted in diagnostics.

## Optional-schema adapters

Schema 9's `samples`, `evidence` and `log_recording_history` use the actual
storage column names. The tool detects tables/columns rather than depending on a
particular future `user_version`. Additional channels use these explicit shapes:

* Gap histories: `awake_history(since, awake)` and
  `exclusion_history(since, excluded)`, together with
  `log_recording_history(since, enabled, paused_until)`. These are state
  transitions, continuing until the next transition. Unknown initial state is
  never backfilled from later state.
* Git: `git_repositories(id, path)` (alias `git_repos`; path aliases `root_path`,
  `repository_path`) and `git_commits(repository_id, commit_hash)` (repository
  alias `repo_id`; hash aliases `oid`, `sha`, `hash`). Stored commit timestamps
  are unnecessary because Git supplies the independent committer timestamp.
* Screen: `screen_captures(id, ts)` (alias `screen_acquisitions`) and
  `screen_occurrences(capture_id)` (alias `screen_capture_occurrences`), with
  optional `screen_capture_counters(ts, acquired, dropped_captures,
  admission_losses)` (alias `screen_capture_stats`). Counter-only storage also
  works if a `stored` counter is present. **Counter rows must be interval deltas,
  not cumulative gauges; acquired must include captures lost before admission.**

These optional shapes are tested with invented fixtures, not claims about an
unreleased recorder schema. Missing channels return `channel absent`; recognized
tables with unsupported columns return `unsupported schema`. Update an adapter
when an actual later schema uses a different representation. Screen evidence
alone does not prove how many captures were acquired.

Worst days rank the worst individual defect ratio per day, preserving its check,
numerator and denominator. The top five failure categories count observations;
categories can overlap (one second can lack several attribution fields). They
are diagnostic counts, not an additive score or a recorder optimization target.
