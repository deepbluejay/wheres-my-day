# Collection policy and operating bounds

Every newly received or recovered collection record uses `admitCollection` in a
SQLite transaction snapshot. Publication retries, normal ready recovery,
events-only recovery and SQL insertion share this policy. Current recording-off
or an unexpired current pause refuses every component. Historical off/pause,
forgotten ranges and the committed retention watermark judge each component by
its own integer second. Current exclusions, the own app and acquisition-time
exclusion blank rich context/input and refuse captures. Permitted unrelated
input batches and metadata survive refusal of their parent.

Application privacy matching uses SHA-256 of the case-normalized OS identity,
derived before presentation masking. Observations and screen ready envelopes carry
that opaque identity through memory retry, recovery and SQL admission. Exclusion
settings retain an additional opaque identity when masking loses their normalized
label; ordinary labels keep their existing representation. Acquisition, metadata
and AX admission use the same exclusion matcher. Legacy ready work whose masked
application has no recoverable identity is explicitly refused with
`application_identity_unavailable`, rather than treated as an allowed application.
Outward queries use each canonical sample's own pre-mask application digest,
without joining observations by second or masked label. Observation delivery can
be missing, late or rejected without changing that identity. Rows without their
own digest use conservative legacy label matching across raw lowercase,
mask-then-lowercase and lowercase-then-mask spellings. Masked spans are unknown;
ambiguity can hide extra historical rows. Privacy verdicts use the same rule for
masked labels and stable matching for raw/catalog identities.

Schema 14 adds nullable application digests on canonical samples, screen evidence,
input batches and independent metadata. Observations keep their own digest in
JSON. The digest commits with its record; replay and metadata preservation read
the stored record's digest. Intervals have no application field. Prompt evidence
sources identify log providers rather than applications. Historical rows remain
byte-for-byte unchanged, with NULL digests in the new columns.
Ready envelopes record their writing schema in `storageVersion`. Replay compares
the identity and content fields defined by that version, preserving historical
NULLs rather than requiring or backfilling later columns. Schema-13 observation
JSON also omits the sample digest added in 14. Unversioned observation envelopes
use that original field's presence to distinguish 13 from 14 before redaction;
unversioned screens permit historical NULL ownership but always match a stored
digest exactly. Stored screen privacy still uses its own digest or conservative
historical label rule, never the incoming envelope's digest. Later nullable SQL
columns do not become requirements for earlier envelopes.
Input batches with no stored digest also have no stored label; replay explicitly
counts `input_batch_application_identity_unavailable` rather than supplying an
owner from the incoming observation. Existing metadata is judged using its own
stored source/digest before admission. Neither rule rewrites committed history.

Schema 13 adds a monotonic screen-retention cutoff, numeric component/reason
refusal counts, and independent masked metadata. The cutoff commits with the first SQL
retention batch under the journal barrier, before spool erasure. It survives
restart and later retention lengthening. A failed subsequent spool erasure still
cannot resurrect expired work. Metadata retained without its parent uses a
local-only relation included in preview freshness, forget, retention and logical
byte accounting. Summary/query/model compatibility reads do not use it.

A ready record is removed only after permitted writes and exact identity/content
proof, or explicit refusal. SQL refusal counts commit with the writes and are
proved again after component writes. A single final transaction proof runs after
commit-time accounting and all its triggers, immediately before COMMIT. It covers
exact typed parent/occurrence rows, all input children, independent metadata and
refusal counts. Later component/record/trigger mutations roll back the transaction
and leave ready work retryable within the recovery limit below. Publication refusals use a synchronized
numeric sidecar so SQL contention does not prevent staging. These are
at-least-once refusal-attempt counts if publication or acknowledgement fails,
not counts of distinct lost observations. Input refusal counts count independent
event-second batches; metadata, containers, captures and rich context have
separate reason names. Status exposes `collection_refused_<component>_<reason>`.

## Memory and latency

The recorder completion inbox and main-thread capture queue each admit at most
240 ordinary captures totaling 8 MiB **estimated**, plus one already acquired
capture larger than 8 MiB in a separate slot. If the main-thread large slot is
occupied, the next large completion remains in the inbox; ordinary completions
continue moving. These are separate ownership stages, so each can hold one large
payload at once. There is no absolute capture-size ceiling.
Shutdown repeats handoff and writer barriers while retained ownership advances,
including the deferred inbox slot, and ends with a writer barrier. A healthy
writer persists all three retained large captures on one stop. An unavailable
writer still ends shutdown with the existing counted failures/drops; shutdown
does not spin indefinitely. Acquisitions beyond these finite slots are still
rejected and counted in `droppedCaptures`; raw inbox rejections do not generate
pipeline admission-loss receipts. These estimates are not an RSS ceiling.

Pipeline admission waits at most 2 milliseconds, then may admit up to 1 MiB beyond
its ordinary 8 MiB **estimated** budget. It separately reserves one oversized
capture, even with ordinary work pending, without charging ordinary admission for
that large slot. As before, a single oversized observation can enter an otherwise
empty ordinary lane; that received-item exception has no size ceiling either.
Capture admission charges four times the payload estimate plus
identity overhead, so a capture can use the pipeline's large slot before reaching
the recorder's 8 MiB threshold. If that slot is occupied, recorder handoff retains
the next capture and retries, continuing ordinary handoffs within the same bounds.
Publication releases the slot; accepted publication failures retain it for retry.
The utility writer still processes one payload at a time, so one large payload's
masking/encoding/sync can delay persistence; this is not a throughput guarantee.
Privacy and generation checks remain at delivery, and fresh component-time privacy
admission runs again at masked durable publication, recovery and SQL commit.
In-memory handoffs are volatile until publication; published ready records recover
after restart. These estimates cover neither all decoded allocations nor SQLite
transaction bytes. Durable storage has no quota or automatic collection stop.
Rejections beyond ordinary admission or an already occupied recorder large slot
are counted; pipeline deadline losses carry source/time and
`admission_deadline`; acquisition, publication and persistence failures are
separate and retain accepted work for retry.

The native input accumulator retains at most 65,536 detailed events between
drains. Further received events increment `detailedEventOverflow`, reported by
the recorder as `nativeEventLimitRefusals`, while its coarse input counters and
person-activity tracking continue. The explicit reason is the native event-count
limit. Dropped detailed events cannot later be reconstructed; storage's eligible
human-count reconstruction uses the retained detailed events. This is an input
accumulation bound, not a collection/storage quota or native throughput claim.
No key values, typed strings or pointer coordinates are acquired.

Privacy maintenance and SQL recovery scan the directory once into SQLite's
automatically deleted disk-backed ordered filename manifest. Its page-cache target is 64 KiB; it visits
one path and decodes one record at a time, alongside the 64 KiB streaming hash
chunk. SQLite's own buffers, decoded values and the directory enumerator are
additional memory. This is not an RSS ceiling. The indexed manifest avoids
repeated full-directory scans and in-memory backlog sorting. Its temporary disk
size grows with filename count, not payload bytes; process interruption closes
and removes SQLite's temporary database. Atomic ready publication, the journal
barrier and ordered freshness hashing remain in effect. SQL recovery retains its
manifest across bounded 32-acknowledgement drains, advances only after successful
SQL commit and ready-file removal (or quarantine), and adds durable publication
sequence intervals under the journal barrier. Missing leaves from privacy erasure
are skipped. Restart rebuilds the manifest; cursor exhaustion releases it, so the
next drain also discovers legacy/non-sequenced ready leaves. Interrupted temporary
cleanup shares the initial scan rather than rescanning every batch.

Decoded ready records are validated before policy reads: envelope/observation
seconds must agree, every independent wall timestamp must be finite and map to a
supported integer second, compact bytes must decode canonically, and redundant
screen/input representations must agree. Semantically damaged leaves are
unknown-time work, just like malformed JSON: recovery quarantines them and keeps
processing valid records; every privacy preview hashes their identity and bytes,
and forget/retention erases them. An immutable identity/content conflict also
quarantines the record immediately after rollback. Other non-busy transaction
failures retain ready work for eight durable attempts across restarts, then
quarantine it so later records can advance. Busy failures do not consume this
budget. Quarantine retains the masked bytes, remains unknown-time work for every
privacy range, and counts in `collection_quarantined_total`; unprovable SQL records
also count in `collection_unrecoverable_total` and persistence failures. Numeric
retry sidecars contain only a hash of the queue filename and an attempt count.
Counters written before a failed rename can count an attempt more than once.

Privacy maintenance releases both the SQL writer and journal barrier between
proven batches, after committing its cutoff or forget tombstone. Publication and
recovery recheck that durable admission policy before saving work. Tick admission
still has its deadline. Explicit drains,
flush/stop barriers and individual transactions can take longer; neither
one-record transactions nor the ordinary no-input fixture gives a universal
latency guarantee.

## Reproducible invented fixtures

`python3 tools/test_collection_replay_upgrade.py` exports and builds the actual
schema-13 and pre-fix schema-14 commits. A SQLite WAL-commit callback exits only
the owned fixture child after SQL commit and before ready acknowledgement, with
no product-source crash hook. Screen, input, metadata and observation controls
cover 13-to-14, 13-to-13, old/current 14-to-14, and a simulated 14-to-15 nullable
column addition. Current exclusions are also tested against historical and
current committed records. Every successful case checks forward progress, all
original typed content columns, NULL added columns and SQLite integrity.

`CollectionPolicyTests` measures previews for 512, 2,048 and 8,192 ready records,
asserts exactly one directory visit per leaf, checks repeated-preview freshness,
and erases the selected backlog. It also measures actual offer/drain/persistence
for 65,536 fully annotated received scroll events and an approximately 8.3 MB
estimated capture with 1,200 candidates (120 observations, ten candidates each).
The capture's estimated admission charge exceeds the normal byte budget and
exercises the oversized-item exception.

`RecorderOversizedCaptureTests` additionally exercises the complete recorder
handoff with an ordinary control, an 11.58 MB estimated structured payload and
a 10.50 MB estimated plain payload. It checks other work pending in all three
ownership stages, deferred retry without loss, privacy-off during handoff,
generation invalidation and masked 0600 ready-file recovery after restart.
`CollectionAdoptionRecoveryTests` terminates an owned child before migration
commit and after commit, verifies rollback/reopen, and immediately records an
invented sample/capture. Its synthetic migration-boundary fixture is separate
from the integration review's actual-main-9 migration and cost measurements.

`CollectionIntegrityTests` additionally drains 512, 2,048 and 8,192 records through
production SQL recovery, asserts one directory leaf visit per record, and reports
`COLLECTION_RECOVERY_CURSOR` with drain time. These idempotent small-record fixtures
measure traversal and SQL acknowledgement, not native capture throughput.

Exact times and bytes print as
`COLLECTION_CURSOR` and `COLLECTION_RECEIVED`. Offer durations are reported
separately from full drain durations. Darwin's process peak RSS before and after
the fixture includes the entire test process and prior tests; it is not an
individual payload's allocation size or an incremental-memory ceiling.

These are local debug-build fixtures under concurrent machine load. They include
explicit drain barriers, masking, encoding, publication and SQL; they exclude
native tap/capture/OCR acquisition. They are stress examples at the native
received-event count bound and a specified large capture, not a maximum capture
size or a production throughput/RSS guarantee. The earlier 30 ordinary ticks
and conditional eight-hour growth fixture remain separate measurements.

## Scoped SQL proofs and maintenance progress

Every public SQL write transaction establishes a read-only SQLite snapshot before
its first write, including canonical `appendAccountingSamples` and `appendSamples`.
The expected database materializes only planned row identities and their content
from that fixed snapshot. Prepared bound statements, schema defaults, independently
derived generated identities, shipped cascades and shipped byte-accounting rules
establish additions and changes. Live changed identities must be in that statement's
expected changed set, including deletions; typed row comparisons run immediately
and again after commit accounting. Absent components and existing dedup content
therefore cannot be legitimized by an earlier faulty write. The original complete
baseline is restricted to one-time schema migration, which can itself rewrite all
historical rows; no ordinary ingestion, privacy or repair path uses it.

First adoption of a main schema-9 database remains synchronous, before the
recorder starts. Independent invented owner-scale fixtures with 570,000 samples
and 341,278,720 database bytes took 24.007–30.216 seconds, about 150–152 MB peak RSS,
and up to 365,318,144 allocated temporary bytes (about 348 MiB), plus 8,194,712 WAL
bytes. Deployment needs that startup time and additional temporary disk beyond
retained growth. These are measured costs, not ceilings. Ordinary reopen took
11–12 ms. Schema changes, baseline verification and `user_version` advancement
share one SQLite transaction: interruption before commit rolls it back and the
next open retries adoption; interruption after commit reopens the adopted schema.
The recorder proceeds immediately when initialization returns, with no extra
adoption cooldown. SQLite closes/removes the anonymous proof database on process
exit; ordinary SQLite WAL recovery handles an interrupted migration transaction.

The expected SQLite page-cache target is 512 KiB. Indexed conflict, time, owner and
content-reference predicates select dependencies. Unique-key conflicts use SQLite's
NULL-distinct rule, both incoming and existing partial-index predicates, and the
index's collation; a NULL source identity never materializes retained screen history; a reference-existence marker
protects shared blobs without copying other retained occurrences. Cleanup checks
only affected references. Temporary proof bytes and final hashing scale with the
current transaction's work, rather than retained history. SQLite caches, schema
objects, snapshot/WAL pages and decoded individual payloads remain additional
memory and disk, so this cache target is not an RSS or disk ceiling.

Forget and retention process at most 64 directly selected rows per SQL statement,
checkpoint after at least 64 accumulated row changes, and leave a 1 ms scheduling
opportunity between committed batches. Cascades, accounting and one acquired
payload can exceed that row count; there is no universal transaction-time or
payload-size ceiling. Derived selection repair continues to select 32 pending
occurrences per transaction. Metadata preservation checkpoints before admission,
then keeps the policy decision, refusal accounting and prepared writes in one
transaction, so a concurrent settings change cannot straddle that unit. A forget
range marker or monotonic retention cutoff
commits with the first batch and prevents new or recovered data from resurrecting
any selected second. SQL and staged cleanup continue to use that committed cutoff
after retention is lengthened, so interrupted expiry work cannot be abandoned.
Each forget batch verifies its range marker after accounting.
If a later batch fails, earlier proven erasures remain committed; restart/retry
requires a fresh preview and completes the remaining work. Small failed operations
still roll back their single transaction. The journal barrier covers the
initial approval snapshot and each bounded work section. After a proven commit,
the SQL writer and shared journal locks are released so actual rich publication
and persistence can proceed. A separate privacy-plan file lock serializes forget,
retention, deletion previews and model-call insertion/recovery for the operation's
lifetime. Rich publication, SQL ingestion and selection repair never acquire that
lock. Thus privacy manifests, call facts/billing and final proofs cannot be
invalidated by another privacy or model-accounting operation during a collection
gap. Metadata preservation reads at most 32 keyset identities, finalizes the source
SELECT, then rereads each payload and admits it in its fresh transaction before
writing. Checkpoints reject any open main-database statement or surviving read
snapshot. Refusal/accounting baselines are rebuilt after every checkpoint. The review-closed
precondition and durable privacy marker are rechecked after accounting at every
erasure batch commit. Prompt retention rereads its mutable duration after each
checkpoint and keeps that policy decision within a bounded deletion unit.
Cross-batch erasure targets include original logical identities and acquisition
clocks so legitimate new collection can reuse a freed SQLite rowid. Metadata
scrub targets are selected again after parent deletion, avoiding an old numeric
slot that now belongs to allowed metadata. Final staged verification judges each
freshly read leaf within its journal section rather than retaining a remaining
count across recovery gaps. Screen-metadata scrub also checkpoints before its
payload/dedup lookup and keeps blob preparation and replacement in that unit, so
a concurrently collected shared blob retains its fresh creation clock.
Final staged erasure also yields every 64 visited filenames, including manifest
construction and verification. Recovery may remove or quarantine a leaf in a gap;
the ordered manifest skips absent leaves and checks quarantine afterward. New
publication is subject to the committed marker throughout. Approval freshness is
checked under the initial barrier before that marker is written.

## Conditional growth and maintenance measurements

These measurements predate schema 14's per-record identity columns. Current
retained-byte and commit-time accounting includes the additional digest bytes;
the earlier page-growth numbers are historical measurements, not measurements
of the identity extension. No new owner-scale growth or adoption benchmark was
run for that extension.

The opt-in eight-hour fixture in `CollectionSafetyTests` uses 1,920 captures every
15 seconds, 192 exact structured scenes repeated ten times, 120 roughly 61–63-byte
lines with three candidates, 38,400 observations, and 1,080,000 movements at
125 movements/second for 30% of the active day. Its earlier approximately 56 MiB
added-page result is conditional on exact bounds/confidence/context reuse for ten
captures. It is neither a personal-use forecast nor a capacity ceiling. Canonical
samples, AX/prompts/models, filesystem/WAL overhead and outage staging are excluded.

Independent one-hour actual-pipeline fixtures, including canonical samples,
projected 58,130,432–150,339,584 committed page bytes per eight active hours
(55.44–143.38 MiB). They used 240 captures per hour at 15-second intervals,
24 scenes repeated ten times, 120 roughly 61–63-byte lines with three candidates,
4,800 observations, 135,000 movements at 125 Hz during 30% of seconds, and
1,080 compact input batches. Exact structured reuse produced the lower result;
changing bounds/confidence produced the upper result. AX, prompts, models,
filesystem/WAL/checkpoint overhead and outage staging are excluded. Real text,
URL, bounds, confidence or event-rate changes can exceed this range. There is no
quota or automatic collection stop.

`tools/measure_collection_maintenance.swift` keeps that exact-reuse scenario beside
a changing-payload/high-event-rate scenario. Compile with the debug Core/Storage
objects, `-I .build/debug/Modules -lsqlite3`, then pass an owned temporary directory
and `seed`, `noop`, `forget`, `forget-day`, `day`, `capture`, `tick`, `repair`, `growth`,
`validate` or `variant`. The 30-day seed preserves
the same event/occurrence dimensions and adds 192 distinct scenes each day. It
constructs invented rows directly; measured operations use public production APIs.
Its particular IDs/JSON strings need not have identical page packing to other
independently generated fixtures.

The previous SQL-only local debug run on a 1,658,474,496-byte committed-page seed (1,152,000 observations,
259,200 input batches representing 32,400,000 movements, 57,600 captures and 11,520
blobs) measured no-op retention at 14.2 ms and one-second forget at 11.1 ms, with
longest observed zero-wait writer refusal spans of 12.9 and 8.5 ms. Their anonymous
temporary-file peaks were zero; whole-process peak RSS was 13.6 and 14.0 MB. The
forget preview took 4.4 ms separately. Deleting one expired day took 11.75 seconds
across batches, with a longest observed writer refusal span of 185.0 ms, 586,300
logical / 589,824 allocated anonymous temporary bytes, 98,381,512 peak WAL bytes,
and 32,096,256 peak RSS. Starting process peaks were about 10.2–10.4 MB. A dedicated
connection probed `BEGIN IMMEDIATE`/`ROLLBACK` about every 1 ms; the maximum sampling
gap was 10.83 ms. These are observations, not hard latency bounds. WAL growth scales
with the deletion work and is distinct from the small proof database.

The changing scenario uses 120 captures in 120 seconds with unchanged first-candidate
text but varying bounds/confidence, alongside 150,000 received movements at
1,250/second. It added 8,187,904 committed page bytes, retained 121 blobs (one reused
text blob and 120 different structured blobs), and encoded 1,638,629 input bytes.
This is another conditional stress example, not an extrapolated daily forecast or
an acquisition-throughput claim. Real text/context/URL/window variation can defeat
exact deduplication, faster received events add compact bytes, and stable scenes
across days can reduce growth. No collection quota or automatic stop is imposed.

The harness now also offers an allowed observation through the actual
`CollectionPipeline`, using its separate zero-busy-wait writer while each measured
path runs. `PIPELINE` reports offer-to-synchronized-publication and
SQL-commit/ready-acknowledgement delay, whether that completed before maintenance
ended, drain attempts and staging/persistence failures. The first maintenance
commit triggers the offer, so the observation encounters active work rather than
an idle store. `MAINTENANCE` labels the independent `BEGIN IMMEDIATE` probe as
SQLite writer refusal only; SQL gaps alone do not demonstrate recorder progress.
`capture` and `tick` exercise the public capture/canonical-sample insert on the
30-day database. `repair` marks 320 existing selections pending, then uses the
production retention repair loop, retaining its 32-selection transaction bound.
The growing same-source/different-source fixture uses two tiny shared blobs and
reports full public capture calls, separately from the realistic structured month.

Round-eight debug measurements on a fresh equal-dimensional 1,658,474,496-byte seed,
under concurrent headless test load (milliseconds, rounded):

- No-op retention: operation 11.14, longest SQLite refusal 8.71; concurrent
  observation publication 4.82 and durable acknowledgement 15.04.
- Public structured capture insert: 41.39, SQLite refusal 15.71; concurrent
  observation publication 2.79 and acknowledgement 9.82. An additional actual
  structured capture through the pipeline published in 25.59 and acknowledged
  in 44.32, including masking, preparation, spool sync, SQL and ready removal.
- Canonical tick insert: 6.89, SQLite refusal 7.18; observation publication 3.73
  and acknowledgement 12.57.
- 320-selection repair: operation 1,579.35, SQLite refusal 323.59; observation
  publication 11.00 and acknowledgement 18.96, while repair was still progressing.
- One-second forget: preview 3.96, operation 13.74, SQLite refusal 9.79;
  observation publication 5.61 and acknowledgement 14.34.
- One-day retention: operation 13,446.49, SQLite refusal 178.08; observation
  publication 3.97 and acknowledgement 68.00, before cleanup finished. Anonymous
  proof temp peaked at 586,300 logical / 589,824 allocated bytes, WAL at 98,443,312
  bytes and whole-process RSS at 33,701,888 bytes.
- Additional one-day forget after retention: preview 436.66, operation 8,992.23,
  SQLite refusal 527.54; observation publication 4.92 and acknowledgement 27.81,
  before cleanup finished. Anonymous temporary files peaked at 19,161,612 logical /
  19,165,184 allocated bytes, including selected-work erasure proofs, WAL at
  108,351,912 bytes and whole-process RSS at 44,924,928 bytes.

Every measured offer was accepted, committed on the first drain and produced zero
staging/persistence failures. The first five paths had zero anonymous temp bytes;
the small-operation recorder acknowledgement delays remained well below a second.
These timings include the independent SQLite probe and are observations rather
than universal bounds. The large forget follows the day-retention check on the
same original month-sized file; retained counts are therefore smaller for that
additional check. The report records exact counts, byte peaks and timings.

Each latency offer measures one allowed record's progress. It does not measure
sustained throughput or establish a universal latency guarantee. In particular,
metadata with independent component clocks exercises a different preservation
branch from the equal-clock month seed and has separate concurrent regressions.

## Agent-log adoption and preparation

Schema 15 adds local agent-log occurrence, payload and privacy receipt tables on
main's collection schema. Actual main 9 and 14 fixtures retain every original
column value and SQLite type during adoption. Main 13's version-aware ready
replay remains supported. Undeployed schemas 10, 11 and 12 are rejected before
migration writes. Ready envelopes keep their writing version across 14 to 15.

Agent-log payload re-masking, hashing, flag encoding and evidence preparation run
before the writer transaction. Prepared bytes grant no admission authority:
recording permission, historical barriers, fresh ownership receipts and the final
content decision remain inside the transaction. The planner selects prepared
records by their input index, so equal physical offsets cannot substitute a
refused record's payload.

The resource regression measures complete reader processes at 1, 4 and 16 MiB.
The original dense/prose/base64/Unicode cases retain the cold-baseline + 3 times
input + 24 MiB RSS guard. Selected content, flag values and long keys have a
separate cold-baseline + 5 times input + 24 MiB guard, accounting for simultaneous
raw, selected, serialized flag and masked representations. The end-to-end writer
uses baseline + 9 times input + 32 MiB, including SQLite copies. These measured
linear envelopes retain full permitted content; they are not allocator-independent
RSS ceilings. Token autorelease pools release Foundation masking temporaries
before processing the next token. Flags are encoded and their selected copy
released before allocating the re-masked payload.

Reader CPU at 4 and 16 MiB must stay below 7 times the 1 MiB CPU + 1 second and
24 times the 1 MiB CPU + 2 seconds, respectively. CPU measurements avoid conflating
concurrent build scheduling with algorithmic scaling; each process also has a
180-second wall deadline. Writer measurements cover dense/prose/selected/flag/key
records at all three sizes. The measured BEGIN-through-return span must remain
under 2 seconds and half the append duration + 0.1 second, so preparation cannot
silently return to the writer transaction.

Operational health stores `busyRetries` separately from `persistence` and exposes
`collection_busy_retries` in status. Busy attempts keep their existing retry
behavior and no longer increment persistence failures. Old health files decode
with zero busy retries; their historical failure counts are retained.
