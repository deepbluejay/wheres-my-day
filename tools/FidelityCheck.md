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
Each stage prints one line to stderr (`fidelity: <stage> (<seconds>s)`), with at most
one more a minute from inside a long stage. They hold stage names and counts only.

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

The tests build their database with the product's own Storage code
(`tools/fidelity_schema_fixture.swift`, about 20 s the first time). No copy of the
schema is stored, so a table or column this tool reads cannot change without its
tests failing.

The database argument is required. Agent homes default to `~/.claude` and
`~/.codex`; repeat either option for additional homes. Only `projects/**/*.jsonl`
under Claude homes and `sessions/**/*.jsonl` / `archived_sessions/**/*.jsonl`
under Codex homes are read. It does not inspect credentials, login files,
processes, process environments, or recorder state. Tests always override homes
and use invented data. Do not point this tool at real data during development.

## Which agent logs are read

Run time follows the selected window. By default a log is read only when both hold:
it was last written no earlier than `--log-lookback-hours` (default 24) before the
window starts, and its first dated line is before the window ends. Only instructions
inside the window are kept and classified. `--all-logs` reads every log instead; other
logs still cost nothing beyond reading them, and the instruction filter still applies.

24 hours is enough because a dispatched instruction reaches its worker seconds to
minutes after the call that sent it, while the dispatching session is still writing.
C1 and C2 report `log_scope`, `log_lookback_seconds`, `log_files_outside_scope` and, among
those, `log_files_starting_after_window`.

**What the narrowing can lose, exactly:** provenance needs the text in an earlier tool
call from another session. If that call is in a skipped log, its instruction looks
untraced. It is then read by its keys: `human` when the same app had a key sample
within 1 second, otherwise `unknown`. So a worker's instruction can be counted as
typed by a person only when someone also typed in that app in that second. The same
goes for a session's first six command outputs if they are in a skipped log, and for a
call in a log that starts after the window, which can match only an output delivered
after the window ended. A log whose lines are newer than its modification time (a
restored or back-dated file) is skipped too. Skipped logs are counted, never silent.
Run `--all-logs` when a result depends on telling these apart.

**Instructions lost whole, exactly:** a log is judged by its first dated line. If that line is
after the window and an older line follows it, as a format that writes a new line and then copies
old ones would do, the instructions inside the window are never seen. `log_files_starting_after_window`
counts these files; how many instructions they hold cannot be known without reading them, which is
what `--all-logs` does. The same goes for a log whose modification time was moved back past the
lookback, counted only in `log_files_outside_scope`. If the original log is in scope, its identities
still match; only a deleted original loses them.

`--from` is inclusive, `--to` exclusive. Accept Unix seconds, ISO dates, or ISO
timestamps. Naive dates/times and per-day buckets use `--timezone` (default UTC).
Use offset-bearing timestamps or Unix seconds at ambiguous local clock changes.
JSON goes to stdout and a short text summary to stderr. Shell redirections are
optional; choose new destinations rather than any input file.

Chrome and shell-history sources are opt-in, repeatable arguments with no default
source opened. `--tolerance-seconds` controls C6–C8 (default 5, minimum 0);
C1/C2 always use ±1 second. C7 stats only files named by recorder document
keys. Additional terminal bundle IDs can be supplied using `--terminal-app`.

## No-text and read-only boundary

Reports contain only fixed category labels, tool types, dates, counts and ratios.
They never contain window titles, prompts, URLs, document paths, repository paths,
session names, source names, hosts, or raw exception messages. SHA-256 identities,
body digests, lengths and hashed eight-word shingles are used internally for
comparison; content never becomes report data. Identity matching does not prove
that masked text can be recovered or that changed text is equivalent.

**C12 is an explicit local-export exception:** only when `--bundle-dir` is given,
masked text, including stored screen text, is written into that caller-supplied private directory. It never
enters stdout, stderr or the numeric report, and is never transmitted. Both C10
and C12 call the product's actual Swift redactor, including every recognized
credential format, label and truncated private-key rule. Additional masking
covers structured secret fields and complete authorization payloads. A number in a JSON-shaped
text field is masked too, as a card number can be written that way, and so is a number in any
column outside `NUMERIC_COLUMNS`, since SQLite stores digits in a column with number affinity as
an integer. As in the product's own rule, a number glued to a sign or decimal part, or split
across a list, is not recognized. The helper
is compiled locally in a private temporary directory and removed on exit.
Arbitrary secrets without recognizable structure can remain. Keep bundles
private, inspect masking before judging or sharing, and delete afterward.

## Reading databases that are in use

A live recorder can hold its lock for as long as it likes, and even a read-only open of
a WAL database can leave side files next to it. So neither recorder database is opened
where it lies. Each is **cloned with APFS `clonefile`** (main file, then `-wal` and
`-journal`) into a private 0700 temporary folder with 0600 files, opened there with
`mode=ro` and `query_only=ON`, and deleted on success, failure, Ctrl-C, SIGTERM and SIGHUP.
Like the other temporary stores, SIGKILL or power loss cannot guarantee that. A clone
costs no blocks until the source changes, then the changed blocks until it is deleted.
After a killed run, look in `$TMPDIR` for `fidelity-clone-*` (holds raw text and pins changed
blocks), `fidelity-chrome-*`, `fidelity-analysis-*` and `fidelity-mask-*`, and for
`fidelity-reference-*`, the older name of the clone folder, and delete what you find.
Nothing is written next to the source, and no lock of the source is needed.

The clone holds the same raw text as the source, so it gets the same care as any store
here. The main file goes first: the log still holds every page it could be missing,
unless the log restarted between the two clones. The log's salt is compared before and
after to catch that, with up to three tries, then the reference counts as unavailable.
A failed open (busy or malformed) makes a fresh clone, also up to three times.

A database with no log (`DELETE` journal mode) has no such pages, so its main file and journal
must have the same size and modification time before and after the clone, or it is taken again,
up to three tries. A journal cloned with an unchanged main file is rolled back in the clone only.

A real copy is never the fallback for a recorder database. If the clone cannot be made because
the database is on another volume than the temporary folder, C9 to C11 say `not cloneable`, and
**the primary is refused**: the tool stops, with no numbers. Set `TMPDIR` to a folder on its
volume. `--input-is-private-copy` says the path is a private copy the person made, and only then
is it opened where it lies when it cannot be cloned; this can leave side files beside it, which is
why the tool will not assume it. The tool cannot tell a copy from a live file by itself.

**The reference is never scanned.** All reads seek an index whose first column is
`timestamp`. One pass over that index, which does not touch the rows, stores the window's
row IDs and numeric times in private state, and later reads fetch rows by ID. A
reference with no such index makes C9 to C11 report `reference timestamp index required`.
Primary tables are read through their own time indexes too, so lifetime rows cost nothing.

Cost of this rule: a timestamp in the reference that the seek does not reach is not
audited, so unusable values outside the window go uncounted, and seeking can load one
oversized index key into memory once, at about its size. Real timestamps are short.

Chrome histories go through the same private clone, so a locked profile reads the same and no
side file appears beside it, whatever its journal mode. On another volume, where it cannot be
cloned, History plus existing WAL/journal files are copied byte for byte into a private temporary
directory, recovered there, and reopened read-only: a history is small, unlike a recorder database.
That copy is best effort under concurrent browser writes; inconsistent/unreadable profiles are
counted as partial input, with readable/unreadable profile counts.

Log identities, text template digests and shingle provenance for logs in scope, prompt allocations, click capacity,
one-way term/deletion identities and daily frequency state spill to private temporary SQLite with a
2 MiB cache. Repeated terms share one dictionary entry and frames store compact
integer references, rather than repeating their edit-distance signatures. Raw reference frame text is processed one frame at a time; only the
selected C12 windows fetch text for export. Samples are reusable time-bounded
cursors; C6–C8 timestamp indices and C12 selection populations also live on disk.
Recall keeps the terms of each channel's moving ±60-second window in memory and adds
and removes each text row once, so a frame costs only its own terms. The recording
history reads the last state before the interval and streams transitions inside it;
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
reference timestamps in the window are mapped once into bounded-cache on-disk state;
reference range queries use numeric timestamps and fetch source rows by integer rowid.
Screen evidence resolves its bundle ID using the latest sample at or before the
evidence timestamp, shared by C10 and C12. Renames and localized display names
therefore apply from their observed time, independent of insertion order.
Duplicate identical observations collapse. Missing predecessors, empty names,
or conflicting names at that latest timestamp fall back to the source's own
normalized identity, also supporting evidence that directly names an app.
Future samples never supply earlier names. Associations store only digests of
source/app identities and numeric timestamps; each indexed lookup reads at most
two rows, with no lifetime list retained in memory. Names come from samples between
one day before the window and its end. A capture happens while its app is focused, so
a name older than that is not needed; without one the source's own identity is used.
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
  **An instruction whose sender is unknown is outside this denominator and may have been typed**,
  so C1 and C2 carry `unknown_instructions` for that tool and day and are `partial_input` when it
  is not zero. A second instruction is what most often settles it, so a narrow window would make
  more of them: see the vote rule under App inference.
  **So is repeated text**, counted in `repeated_text_instructions` and also `partial_input`, since a
  person can have pasted it. See "Repeated text" below; such lines take no part in C3's
  `typed_instruction` or in naming a session's app either.
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
  `repeated_text_instructions_stored` is the same measure for repeated text, in the same
  matching, by tool/day, with its own denominator (`repeated_text_instructions`). It ranks, and
  those not found add to `missing_prompt_evidence`. The product stores a notice and a person's text
  alike, so a line that was not stored is a loss whoever wrote it. Repeated text stays out of the
  main C1 and C2 ratios whatever the keys say: keeping only those with keys in the same app would
  keep only lines that pass C1, and keys do not say who wrote one. C1 has no such row; read
  `partial_input` and C13's `repeated_text` `without_keys`, which does not rank.
* **C3 attribution:** seconds with keys, clicks or scrolls missing app, window,
  document, or any attribution, divided by seconds with such human input.
  Lower is better. Duplicate seconds merge populated attribution fields.
  Excluded samples stay in this denominator, so intentional omissions remain
  visible rather than silently looking complete. Attribution is presence, not
  proof that a window/document identifier is correct.
* **C3 silence**, four separate answers. Nothing here tells rest from sleep from loss by itself:
  - `unexplained_gap_seconds`: seconds the recorder should have written and did not, divided by
    seconds it should have written. Lower is better. `samples` has one row per recorded second, and
    recording stops 300 s after the last input by design (`RestPolicy.inputAgeSeconds`), so only that
    span after a stored person input is expected. **It cannot see an outage:** a stored input can
    only prove 300 s, and input the recorder never stored proves nothing, so a recorder dead for
    hours adds at most 300 here, and one that died in a rest span adds 0. The row says so in its
    reason whenever there is silence it cannot judge. `gap_runs` and `gap_runs_over_5_seconds` count
    runs of those seconds; `longest_gap_seconds` is the whole silent span around them, not capped.
  - `no_row_seconds_unknown`: seconds in spans of more than 300 s with no row, with
    `no_row_spans_over_300_seconds` and `longest_no_row_span_seconds`. **This is unknown, not loss,**
    since rest, sleep and an outage look alike. It has no ratio and never ranks.
  - `seconds_after_last_row`, one row for the window: seconds from the last row in the window to its
    end, of which `paused_off_or_erased_seconds` are explained by the histories below. It also counts in the two above when the copy can see that far. No ratio, never ranks.
    `copy_after_window_end` compares the copy's own time with the window's end, so a copy taken after
    the end cannot excuse a stop; `seconds_after_copy_time` is what a copy taken earlier cannot speak
    for. That time is `--copy-time`, or else the file's last write (`copy_time_basis`). **A recorder's
    own file stops being written when the recorder stops**, so give `--copy-time` for one, or its death
    looks like the moment of the copy. **Measure that time before the copy starts.** A `VACUUM INTO` file
    is written when it ends and holds what existed when it began, so its file time can pass a window's
    end the content never reached, which reads as a gap. `cp -c` keeps the source's file time, so a
    clone of a stopped recorder's file has the same trap as the file itself.
  - `person_active_seconds_without_row`: seconds an independent source shows the person active and
    no row exists, divided by seconds it shows them active. **This one is a finding, and it ranks.**
    Only two sources make the total, the failures, the rank and the implied count: reference input
    events (click, key, text and scroll types, not focus or app changes, which a program can cause)
    and typed instructions from logs. Logs and reference input allow a row within 1 s.
    `implied_seconds_without_row` of `implied_expected_seconds` extends each such second by 300 s, as
    the recorder itself would.
    **Chrome visits and shell history are in `by_source` only** (within `--tolerance-seconds`). The
    product stops writing 300 s after input, so a page a person opened has a row beside it, and a visit
    with no row either loaded itself or was really missed; this number cannot tell which. A shell
    line can be a script's. `visit_transitions` on this row and on C6 counts visits by Chrome's
    `visits.transition`: `reload`, `subframe` (automatic or manual), `auto_toplevel` and `redirect`, the
    last a flag on a visit of some other type, so these overlap and do not add up. `unavailable` counts
    visits in a profile with no such column. An agent driving the same profile looks like a person
    in all of them, and C6 still has these visits in its denominator.

    **`sources` says what each input could speak for**, per day, for all four sources: `requested`
    (false: never asked for, as opposed to stopped), `readable`, `first_second`, `last_second`, `seconds`
    and `cannot_speak_for_rest`. Logs are always requested. A requested input that cannot be read makes
    the row `partial_input` and names the source in the reason. A last signal more than 300 s before the
    end of that day's part of the window makes `cannot_speak_for_rest` true, and for reference input the
    reason names it: a zero is then true only up to that signal. Instructions are sparse by nature, so
    `typed_instruction` says this in `sources` only. `cannot_speak_for_rest` says what is unknown, not that anything stopped working. With neither
    total source showing a signal that day, numerator and denominator are null and the reason is
    `NO_SIGNALS`, not a clean result.

  Paused or off seconds (`log_recording_history`) and erased ones (`forgotten_ranges`) count as silence
  in none of the others. **What the data cannot match:** the product extends the 300 s by `byPerson`
  (`RecorderLoop.observeInputActivity`), and stored rows match it because `ActivityStorage.insertSample`
  rewrites their counts from person events; older or converted rows are read through `synthetic` (see
  below). The product also clears its last input at suspend and screen lock
  (`RecorderLoop.swift:239`), and accessibility review pauses are not in the history. The schema has no
  sleep, lock or review history, so a machine locked or asleep within 300 s of input counts as a gap
  (`machine_sleep_distinguished` is false).

  **Person input:** C1, C3, C8 and C13 count only what a person certainly made. Rows with `observed_ts`
  hold only person events. A row without it can be older or converted and its counts may include
  program-made ones, so only what is above `synthetic` counts. `synthetic` also counts key-ups, so such
  a row can undercount a person, and a recorder row for a hidden app has no `observed_ts` either.
* **C4:** reachable commits found in `git_repositories` and stored in `git_commits`
  with `complete=1` under the same repository, divided by reachable commits with
  committer timestamps in the requested range, by day. Uses read-only
  `git -C <common_dir> log --all`, without fetch, optional locks, pager, or fsmonitor.
  A commit on several refs counts once per repository. `git_tombstones` commits were
  erased by the person and are excluded (`commits_forgotten`); stored but unfinished ones
  are `commits_incomplete`. `reopen_blocked` repositories are not read
  (`repositories_blocked`). `common_dir` is masked text, so a repository whose path masking
  changed cannot be read (`repositories_path_masked`, identity no longer equals the path's
  digest) and makes the result partial, as unreadable ones do. A commit whose author date
  is older than the prompt retention is not stored by design and still counts as
  missing, so use recent windows.
* **C5:** what became of captures that returned text, from accessibility probe attempts.
  Denominator: attempts that completed, plus attempts whose `ocr_refusal_reason` is `dropped`.
  - `acquired_captures_stored`: linked plus `unlinked_with_stored_capture`, divided by that. This is the
    number that means keeping. It does not rank, since its gap is the next two rows, which do.
  - `acquired_captures_dropped`: capacity drops, divided by that. Lower is better, and it ranks.
  - `acquired_captures_unlinked_unknown`: attempts that returned text and have no link and no stored
    capture to explain it, divided by that. Lower is better, and it ranks, as real loss can hide here. Its
    cause is not in the row: refused after arrival (a document change, say), refused by policy when
    stored (`eventsOnly`, by design), a delivery discarded at suspend, no link within 60 s, or a store that
    failed after hand-off (the attempt commits with no link after 60 s, a loss).
  - `acquired_captures_linked`: attempts with a linked stored occurrence, divided by that. **A diagnostic,
    not a rate of keeping,** so it never ranks. It measures a race: `ActivityStorage` links only attempts
    still pending or in watchdog, and a later commit in `AXProbeContent` can write the link back to NULL.
  - All four rows carry `unlinked_unknown`, `unlinked_with_stored_capture` (of the unlinked, those with an
    unlinked screen occurrence at the same second in the same app, strong evidence and not proof, as a
    same-second capture from elsewhere can land here; on one real 12.5 h window it covered 29 of 29),
    `refused_by_design` with `refusal_reasons`, `capture_failed` (failed, permission, unavailable),
    `other_statuses`, and `unreadable_attempts`, which make the row partial.
  - `probe_run_drop_counters`: `droppedOCR`, `ocr_dropped`, `pendingDropped` and `overload_dropped` from
    `ax_probe_flow`, for the runs touching the window. They count whole runs, which can outlast it,
    so this is one row with no day and no ratio. The same drop adds to both of the first two.
  - **Outside a probe run these report a reason, not a number:** the schema stores only kept
    captures, and drop counts exist only in the running recorder's status.
  - `screen_occurrences_with_text`: stored screen occurrences with non-empty text, divided by stored
    screen occurrences, always available. It does not rank. It carries `empty_text`, a stored capture with no
    words, which a picture, video or blank window gives as readily as OCR that read nothing, and `no_blob`.
  - `screen_occurrences_no_blob`: occurrences whose text has nowhere to be read from (the payload or the
    blob is gone, with an empty text column), divided by the same. Damage, so lower is better and it ranks.
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
  No URL is emitted. `visit_transitions` counts reloads and other visits a page can make by itself (see
  C3); they stay in this denominator.
  Chrome's microseconds-since-1601 timestamps are
  converted to Unix seconds. Non-HTTP(S) visits remain in the denominator as
  unmatched and are counted separately. Unreadable profiles make results partial.
* **C7:** `open_document_changes_attributed`. It asks: a file the person had open changed, was it
  attributed? Denominator: files that were some sample's document key inside the window and whose
  mtime is inside the window. Numerator: those with a sample of that document at the mtime ± the
  configured tolerance. Each document is asked about once with `lstat`, no folder is ever walked or
  listed, and no file is opened, so the cost follows the window. Files nobody had open cannot enter,
  which rules out most of what agents, Git and builds write. `documents_known` is how many files that was.
  **It does not rank** and stays out of worst days and top failures, because an agent can still write a
  file the person had open and the two look the same here; its misses are a diagnostic count,
  `open_document_changes_without_attribution`.
  **It sees only the latest surviving mtime.** Deleted files and earlier saves cannot be recovered, a
  save outside the tolerance of the document's focus misses, and a file never focused is invisible.
  **It measures little in a browser and terminal.** A document key is a file path only when the app reports
  one through `AXDocument`; browsers give web addresses, and many apps give nothing. `document_keys_seen`
  and `document_keys_not_a_path` count this, and when every key in the window is not a path the reason
  says no app here reports file documents, as opposed to paths that are gone or refused, counted below.
  Names are compared in NFC, so either Unicode form is one file. A symlink ancestor is followed once to
  name the real file (`document_paths_through_symlink`), and the file is refused if either name passes
  through a credential or tool-output folder (`document_paths_excluded`). Symlink files and folders
  (`document_paths_not_regular_files`) and vanished paths (`known_document_paths_unavailable`) are
  counted. `stat` can make macOS ask for permission on a protected folder; a refusal counts in `metadata_errors`.
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
  per day and app digest, once for each place our text lives, so they can be
  compared. `app_id` is an unsalted SHA-256 of the app's name, so a well-known app can be recognised
  by hashing its name; it keeps names out of the report but does not hide which app it is. Metric names are `informative_term_weighted_recall` and
  `informative_term_unweighted_recall` plus a suffix; rows also carry `text_source`,
  `text_rows` and `app_matched`:
  - no suffix, `screen`: stored screen text, what summaries read: `screen_payloads.text_hash`
    joined to `collection_blobs.content`, with `evidence.text` for rows without a payload.
  - `_ax_probe`: accessibility probe text. Each finished attempt in `ax_probe_attempts`, its
    `ax_probe_parts` read as JSON, then each attribute's `textRef` from `ax_probe_chunks`,
    through that attempt's `ax_probe_refs`. JSON keys, content hashes, role and
    attribute names, and the attempt's OCR reference are not counted.
  - `_agent_log`: `agent_log_events` joined to `agent_log_payloads`, values only, without line
    metadata fields. A log line names no app, so this channel matches **any** frame's app
    (`app_matched` false), and a background session's words can count.
  - `_all`: the union of the three.
  Identifiers (UUIDs, long hex, long unbroken tokens) are removed from the last two before
  extracting terms. Stored text was masked by the product when written; the labelled-secret
  rules below still apply to it, and reference text gets the product mask as well.
  An empty channel keeps numerator 0 and the reason `no <channel> text in this window`.
  Extract words of at least 3 letters, or 2 Hangul syllables, after NFKC/case
  normalization; exclude numbers. For each term use
  `log(focused_frames_that_day / frames_with_term)`.
  A term on every reference frame has weight 0. Sum weights of reference terms
  found in that text at ±60 seconds, same app except as above, divided by all reference
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
  local manifest so the same windows can be judged again. Screen rows carry their real
  text from the blob, masked as everything else in a bundle.
* **C13:** stored prompts with no key sample in any app within 1 second, divided by stored prompts,
  in groups named by **what the prompt's log line says, never by the shape of its text**. A stored prompt
  joins its line by C2's identity rule. Metrics are `stored_prompts_without_keys_<group>`:
  - `marked_typed`: a tool marker says this turn came through the input box. **That is not the same as a
    person:** text sent in through a terminal gets the same marker. Queued ones are `queued`, since delivery
    need not be typing. Only this group ranks, as it is the only one that should have keys.
  - `repeated_text`: see "Repeated text" below. Its `without_keys` is shown and does not rank, so a person's
    text moved here by mistake still shows as a number.
  - `agent`: a tool marker says so, or provenance traces the text to another session's tool call.
  - `machine_notice`: a marker says not an instruction (meta lines, or an imported turn).
  - `unknown`: no marker and no provenance, or no log line at all (`no_log_line`). Keys decide nothing
    here, even where C1's classifier used them, because keys are what is being measured.

  Each row also has `without_keys_same_app`, with no key in the session's inferred app within 1 s, since a
  person typing elsewhere gives any-app a key; `same_app_unresolved` counts prompts whose session has
  no inferred app; and `text_starts_like_notice`. That last count only describes what got stored: the
  product already refuses task notifications, command and shell output, interruption lines and marked
  meta lines (`AgentLogs.swift:347-352`), so most named notices never reach this table, and a count in
  `marked_typed` is someone quoting one. Counts only; lower is better. A queued instruction can legitimately
  have no keys. The log reader applies the product's same opening strings when it reads a line, so
  a person's prompt starting with one is neither stored nor counted.

  **Repeated text.** A notice delivered in plain words carries a typed marker and no keys, so without this
  it would count as a person with lost keys. A line's *template* is a SHA-256 digest of its text with hex ids and numbers
  replaced, spaces collapsed and case folded. Text of fewer than `TEMPLATE_MIN_WORDS` (8) words has no template, because
  people repeat short words. A template used `REPEATED_TEXT_MIN` (3) or more times is `repeated_text`,
  counting every line of every log read, of any date, so a narrow window still sees it. So the same window can count
  differently by what was read: **compare runs only with the same `log_scope` and `log_lookback_seconds`**, and even
  then a later run has more lines, which can take a template to 3. **The 3 is a guess, never
  fitted to real data.** Copies of one line count once (a resumed session keeps its identity, and equal text
  within `SAME_LINE_SECONDS` (2) in one session, as when Codex writes a message three ways, is one use). Lines a tool marked as an agent's, as metadata or as imported do not count, so a person's
  text an agent passed on to its workers stays that person's. Only digests are kept; template text is never written anywhere.
  It decides nothing where a marker or provenance has already said agent or notice.
  **What it gets wrong:** a person pasting one long text three times counts as repeated from the first, and so does
  a person's fixed wording of 8 or more words where only a number changes, since numbers do not make a new template. A template that
  has a changing name or word in it is a new template each time. The first two uses of a notice with no
  third in the logs read, and notices that differ each time, still count as typed; once a third use appears, the first
  two leave the typed count too. All this
  is a count to read, and `repeated_text_instructions`, this group and the `repeated_text` entry of `classifications`
  show how much it moved. `repeated_text_instructions_stored` under C2 says whether those lines were stored.

## Reference comparison and private judging bundles

Use `--reference-database` with an explicit path; no default product or path is
encoded. It is read through a private clone (see above). Supported reference
shapes are `frames(timestamp, app_name, window_name, browser_url, focused,
full_text, accessibility_text, text_source)` and `ui_events(timestamp,
event_type, app_name, window_title, element_role, element_name)`, each with an index
starting on `timestamp`. `monitor_id` is carried in a frame when present; samples have no
monitor, so the tool never says a frame was on another one. Timestamps accept ISO timestamps with
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
observations (`yes`, `no`, or `unknown`), nearby screen evidence,
document agreement and availability, nearby sample counts, recording/pause state
where history exists, and exclusion flags. The `ours.screen_evidence_context`
field includes clearly marked screen rows from the ±60-second halo outside the
window, so the judge can inspect evidence underlying nearby-evidence flags. `unknown` stays distinct from `no`.

`our_only_candidates` also carries prompts, agent events with their payloads
(`agent_log_events.payload_id`) and stored commits in the window for the judge's
reverse-direction comparison. These are candidates for judgment, not claims that every
item is exclusive. Missing agent/Git channels are marked explicitly. A commit message
too long for `git_commits.message` is in chunks that a bundle does not assemble. No
model runs and no judgment or score is produced.

Delete only this tool's manifested bundle files afterward:

```sh
python3 tools/fidelity_check.py --delete-bundles /tmp/invented-private-bundles
```

Deletion rejects symlink files and unsafe manifest names, preserves unrelated
files, removes the manifest, and removes the directory if empty. The numeric
report retains only the seed and times, never the bundle directory or text.

App inference uses no app-name allowlist. From `--log-lookback-hours` before the window to
its end, a session needs key votes at two or more instructions and
one app with at least 80% of votes. Instructions before the window only vote, and are not
measured, so a narrow window does not leave its one instruction undecided for lack of a second. Otherwise pool inferred apps from at least
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

## Schema

The tool reads the current schema (`Sources/Storage/Schema.swift` and the schema functions
it calls) by table and column name, not by `user_version`. A missing table or column
returns `channel absent` rather than a number. It has no adapters for other shapes.

Worst days rank the worst individual defect ratio per day, preserving its check,
numerator and denominator. Rows with `ranked` false, and rows with no ratio, take no part: their
numbers cannot be read as defects. The top five failure categories count observations;
categories can overlap (one second can lack several attribution fields). They
are diagnostic counts, not an additive score or a recorder optimization target.
