# Development AX probe

The probe defaults to off. It collects accessibility text alongside each OCR opportunity and stores
it in the probe tables only. Probe text never enters product evidence, summaries, queries or model calls.
Browsers, including private windows, are included whenever the probe privacy gates allow them.

## Collection

The single AX worker walks the target application’s focused AX window alongside the paired OCR
capture. It reads the full containment tree, including web areas, popups, hidden and
unselected tabs, collapsed branches, off-window content, foreign-process descendants and unknown roles.
Repeated references are visited once to avoid cycles. Unresolved children are counted without
refusing the window or discarding other text. Geometry correspondence with the OCR target is
recorded where available. Missing or ambiguous geometry never refuses the window. This is a
best-effort focus/geometry correspondence, not an exact window-ID bridge; focus can change
between native calls.

Each node uses one `AXUIElementCopyMultipleAttributeValues` request for role/subrole, position/size,
selection/expanded/hidden state, text/range metadata and the five containment arrays. Text is decoded
lazily from the native batch, so Swift text does not accumulate in a second node cache. Child AX
references are interned in pages of at most 64. Full native child arrays are released before descent;
only scalar counts remain, and subsequent pages use AXUIElementCopyAttributeValues.
Unsupported/no-value attributes are final; generic batch/attribute errors that warrant retry fall
back to individual reads. A real cannot-complete response is never retried as an ordinary missing
attribute. Parameterized visible-range strings still require separate calls. PID is obtained from
its local AX reference and bundle lookups are cached per PID. An attribute-name discovery call is
unnecessary because unsupported values are returned in the batch.

Nonsecure nodes are asked for AXValue, AXTitle, AXDescription, AXHelp, AXPlaceholderValue, AXSelectedText,
AXURL and AXDocument, plus the visible-range string where supported. Full editable and clipped
values are included, even when visible ranges are unavailable. URL values are converted to strings.
Parent aggregates and repeated attribute strings remain separate observations.
Secure fields (AXSecureTextField role/subrole or AXIsSecure flag) retain their node, non-value
metadata and secure flag/count. Metadata is batched first; only nonsecure nodes receive a second
batch for AXValue and AXSelectedText. Secure fields never request these values or a visible-range
string, and storage also strips these attributes defensively. Their descendants are still visited.

Before the walk, the application element is asked whether AXManualAccessibility is settable. If so,
the worker sets it to true to make Electron/Chromium accessibility available. Each attempt records
set, not settable, or failed. The probe never sets AXEnhancedUserInterface, activates or focuses an
application, invokes an AX action, or posts input. Enabling accessibility can cause an app to build
its accessibility tree; target-app CPU and memory cost are not measured.

Legacy PID streaks and cooldowns are reset once when the failure-policy column is introduced.
New-policy real-failure streaks persist across subsequent opens; run and attempt history is preserved.

## What stays protected

- `Redaction.apply` masks every AX-derived string before serialization, including role, subrole,
  bundle metadata, attribute names/values, and paired OCR text. Raw roles are used only transiently
  to classify secure fields and tabs.
- App block lists, user exclusions, Recording off/pause, Secure Input, own app, unreadable settings,
  review epoch and capture generation/stop gates still apply. A privacy change during acquisition
  or persistence rejects probe text. The requested app and current front app are both checked.
- AX does not depend on OCR delivery acceptance. No person input, a changed window/document key,
  expired OCR delivery, or OCR superseded/busy/dropped outcomes keep the AX result with nullable
  evidence linkage and a content-free `ocr_refusal_reason`. Refused OCR text is omitted. With the
  probe enabled, otherwise eligible windows have opportunities at the 15-second cadence even
  without current person input; ordinary screenshots keep their existing person-input gate.
- One worker runs off the recorder thread. Every AX IPC has a messaging timeout of at most 50 ms.
  Probe-only policy callbacks read current application identity through frontApplication without
  enumerating window details (a lightweight main-thread identity read remains). OCR policy checks still acquire window details.
  A 16-second watchdog cancels the run without replacing a stuck worker. Only real single-call
  cannot-complete/timeouts count as messaging failures. Three consecutive real failures trigger
  a 60-second PID cooldown, then acquisition can resume. Success resets the streak; deadlines
  neither increment the streak nor cause cooldown. No PID is permanently disabled. Both real
  failure and triggered-cooldown counts are persisted. An unfinished worker lease after restart
  also cancels its run. A new opportunity while the worker is in flight returns counted `busy`
  immediately, including for the same window; it never queues a second read.
- Range forget and `privacy forget --probe-run` delete the probe observations. Existing historical
  rows survive schema upgrades. No probe text is used as ordinary evidence.

The collection limits are **50,000 elements per window, depth 256, and 15 seconds per opportunity**.
The time budget is cooperative; an in-progress IPC can overrun it. Element, depth and time
truncation reasons are recorded. Partial collected text is kept unless the run or capture policy
has been cancelled. There is no separate IPC-count cap. The operational memory envelope below can drop an overloaded
attempt, regardless of its application, role, visibility or selection state.

## Invented latency measurement

A deterministic 100-node provider models **4 ms per IPC** with identical text in both paths.
The sequential path makes **2,305 calls**, takes **9.220 s**, and has node-read **p50/p95 72/72 ms**.
The batch path makes **204 calls** (200 metadata/value batches, two child pages, setup/focus), takes
**0.816 s**, and has node-read **p50/p95 8/8 ms**: **9x** lower node latency and **11.3x** lower total modeled time.
This tests the extractor's batch hook and equal collection, not real macOS server performance.
The native batch fallback has separate invented regression tests.

If the observed approximately 100 ms/node is dominated by the same round-trip overhead, reducing
roughly 22 calls to two suggests approximately 9 ms/node plus batch processing and any child-page/range/fallback
calls. Real speed-up remains unmeasured: target-app batch computation, tree materialization,
parameterized ranges and timeout behavior can reduce it. No real windows were read for this change.

## Stored measurements

Each paired opportunity retains masked OCR and per-node AX observations in probe storage only.
Schema 9 adds content-addressed `ax_probe_blobs`, 64 KiB `ax_probe_chunks`, attempt-to-blob
`ax_probe_refs`, and ordered `ax_probe_parts`. Attempts keep a small version-3 header with lengths
and references; parts describe at most 16 nodes each. Distinct masked strings, including repeated
parent aggregates, are stored once by SHA-256. Repeated metadata parts are deduplicated too.
An unchanged observation adds references and a small attempt header, never another text copy.
Characters and mask hits still count every observation, including duplicate attributes.
Legacy runs and their exact payload bytes are preserved without rewriting them. New masking
protections apply to new writes; historical payloads retain their original masking behavior until
explicitly forgotten.

Each node records role/subrole/bundle references, depth, PID, frame-inside-window and on-screen
flags, inherited hidden/collapsed/unselected and non-selected-tab flags, local selected state, and
secure-field status. Unavailable metadata remains unknown. Only actual tab/page/panel roles and
direct radio-button children of a tab group introduce non-selected-tab state. An unselected row
inside an active tab remains a separate selection measurement, not hidden content.
Each attribute records a reference, masked Unicode scalar length, and counts of newly emitted
mask markers by kind (`secret`, `email`, and legacy marker kinds). These are marker occurrences,
not unique secrets or redaction-rule counts.

Attempts also record AXManualAccessibility outcome, elements visited, IPC count, truncation
reasons, elapsed/worker/queue time and pairing diagnostics. New attempt headers record `isBrowser`
as a boolean from observed browser metadata; unavailable metadata leaves the field absent, meaning
unknown. App identity never determines an activity category. No categories are written in new
headers, and legacy category fields remain untouched and readable. This additive JSON change keeps
the version-3 content format, preserves active runs, and requires no data rewrite. The database
schema is version 14 after the separate additive collection-identity change.
Node latency covers batch, metadata and text reads, excluding descendant traversal. Attempt headers
store a deterministic uniform reservoir prepared on the background pipeline of at most 4,096 microsecond-rounded node latencies and
the exact measured-node count. Timing stays outside node parts, preserving metadata deduplication.
Older attempts lack this measurement. Geometry and branch metadata estimate
visibility; they do not establish exact pixel visibility, occlusion or individual visible characters.

## Operational memory and storage

The AX worker requests visible ranges in **16,384 UTF-16-unit chunks**, retrying a trailing split
surrogate at the next boundary. Full-value AX APIs can return an already allocated native object;
its disclosed length is checked before making a Swift string copy. Strings over **4,194,304 UTF-16
units** are omitted with `resource_truncated` and the exact original UTF-16 length. That threshold
accepts at least 4 MiB of ASCII text and can accept up to 12 MiB of UTF-8 text. Oversized metadata
lengths are retained as empty diagnostic attributes with the exact original length, alongside
content-free counters. Oversized text attributes likewise retain their original length. If aggregate original-length totals overflow, the total saturates at `Int.max`
with `resource_length_sum_overflow`; individual attribute lengths remain exact. Values below the threshold are masked as complete strings before storage chunking,
so a secret crossing a storage chunk boundary cannot escape masking.

Acquisition retains at most **64 MiB of accounted input per attempt**. Accounting charges string
UTF-8 bytes plus 1,024 bytes per node, 128 bytes per attribute and a small receipt allowance.
It never builds a second concatenated AX aggregate, and interns child references a page at a time.
Native batches can return already allocated full child arrays, just as full-value text APIs can
return already allocated native strings; these native objects are outside accounted Swift input.
Full child arrays are released before descent, preventing full-array retention across ancestors.
If acquisition cannot retain an attempt within this envelope, it releases its text, continues the
walk, and reports `overload_dropped`. This is an operational resource drop, not a visibility or role
refusal. The background pipeline reserves **128 MiB** across waiting, queued and executing input,
using the same accounting. A full queue drops the newest attempt with counted `overload_dropped`.
These are accounted-input bounds, not promises about total process RSS; native AX objects, Swift
containers, and bounded redaction/encoding scratch buffers also consume memory.

Only small immutable receipts reach the recorder main thread. Masking, hashing, encoding and
persistence run on the background pipeline. Probe writes use a separate SQLite/settings connection
and small transactions, with at most one 64 KiB text chunk per chunk write. Run, recording policy,
capture generation, retention and forget barriers are rechecked between writes and before commit.
Partial writes are referenced by their pending attempt so off, forget, evidence deletion and
retention remove them too. Blobs still referenced by kept attempts remain; unreferenced blobs and
all their chunks are deleted by triggers. Each write and failure cleanup verifies the original
run, attempt and timestamp as well as the row ID, so a late writer cannot change a kept attempt
that reused a forgotten row ID. Existing unmanaged backups are outside this deletion.

A failed payload is released without re-enqueueing it. If SQLite is busy, the recorder retains a
content-free failure receipt in memory for maintenance retries. The retry commits its storage-failure
counter and any still-pending attempt's `storage_failed` status together, once. Retry bookkeeping
never processes payload content on the recorder thread. If the failed writer could not clean up
partial masked content while busy, it remains attached to the terminal attempt until forget or
retention removes it. These receipts, like worker-finish receipts, do not survive recorder restart.

`ax-probe status` includes `ax_probe_storage_bytes`, `ax_probe_added_24h_bytes`, and
`overload_dropped`. Byte fields measure retained logical probe content and references, including a
fixed row allowance. The 24-hour field uses opportunity timestamps and counts currently retained
content first observed during that window; deletion reduces it, and reused older blobs add only reference bytes. These counters exclude
SQLite page slack, indexes, WAL and legacy review tables, so filesystem usage can be larger.
There is **no total disk quota and no automatic stop at a disk-size threshold**. Existing screen
retention also removes probe attempts and their unreferenced blobs. Highly changing trees can still
consume substantial disk; status and overload/truncation metrics make that observable.

An invented one-hour workload at 15-second cadence (240 opportunities, ten recurring windows,
100 nodes/window, two text attributes/node, about 200 characters/node, 3,800 OCR characters,
and revisions to five nodes every ten minutes) retained about **6.1 MB logical / 10.9 MB in SQLite
probe pages**. Linear extrapolation is about **49 MB logical / 90 MB of probe pages per eight active
hours**, including initial content. These earlier storage figures exclude the new per-attempt
latency sample, which adds up to about 36 KiB per opportunity at the 4,096-sample maximum and
much less for a 100-node tree. This is an illustrative workload, not a real-app measurement or
a worst-case bound; different tree sizes and change rates can increase growth substantially.

## Turn on and off

```
B ax-probe on
B ax-probe status
B ax-probe off
```

`on` creates a new run, which has no scheduled expiry. Stop it with `off`; worker hang protection
can also cancel a run. Disable an existing run before starting another. No manifest, binary hash,
acceptance flags, app map or browser scope is required. Building does not enable the probe.
The old freeze, manifest and blinded review tools have been removed. Historical review rows and
lease handling remain for compatibility with existing data and sessions; leases expire normally.

## Counts-only analysis

Create a private standalone backup outside the app directory, with a separate name:

```
sqlite3 -readonly SOURCE ".backup 'COPY'"
chmod 600 COPY
python3 tools/ax_probe_analysis.py --database-copy COPY --run RUN
```

Never supply the live database. The analyzer rejects the standard app directory, the recorder
DB basename, the configured `ACTIVITYPROBE_DB`, hard links, and files with SQLite sidecars or a
recorder lock. It opens the supplied backup read-only and immutable. Delete the backup afterward.
The operator must still ensure a custom database at an otherwise unrecognized path is a backup.

By default, the output contains counts only, overall and per app in `apps`, keyed by each app's
existing opaque SHA-256 key. Each app has a `rank` by descending opportunity count, with key-order
ties, so keys remain stable when ranks change. A separate `browser` dimension (`true`, `false`,
`unknown`) appears overall and within each app; missing or invalid booleans are unknown and are
never inferred from legacy categories. Measurements include opportunities, AX/OCR text yields and character counts, off-window,
off-screen, hidden-branch and non-selected-tab character shares (including their union), unknown
geometry and branch state, mask hits by marker kind, secure fields, manual-accessibility outcomes, truncations and
returned-attempt timing p50/p95, per-node read latency p50/p95, nodes per attempted read
(mean/p50/p95), and completed-without-truncation share. The completion denominator is attempted
reads (actual IPC or a censored watchdog), not all scheduled opportunities. Empty successful reads
count as completed. `ocr_refusal_reasons` and `ocr_*` flow counters separate all fixed refusal
reasons; messaging failures and triggered cooldowns have separate flow counters. Rows and 16-node parts stream into counters without loading text
blobs. Timing uses a deterministic uniform reservoir of at most 4,096 durations per app/browser group
(and overall); quantiles are approximate above that count. Node latency first uses at most
4,096 samples per attempt, reweighted to that attempt's measured-node count before analysis sampling;
large-attempt node quantiles are approximate at both stages. Memory is bounded by counters,
reservoirs (also at most 4,096 node latencies and node counts per group) and the largest current row/part;
group memory grows with the number of apps, not the number of opportunities. Unusually large legacy JSON rows still require
memory for that single row. Unselected controls are reported separately from visibility. Watchdogs are reported separately as censored durations.
Policy-refused and pending opportunities remain in denominators and status counts. Flow counters
show collection/storage gaps; missing rows cannot be reconstructed from those counters.
Legacy rows without node metadata have yield counts and a note that per-node risk data is unavailable.
`legacy_category_opportunities` counts rows carrying an old category, whose value is ignored.

An optional private `--label-map MAP` adds display labels for local viewing only:
`{"bundles":{"invented.bundle":"Local label"}}` (a direct bundle-to-label object also works).
The map must be an owner-only regular file; bundle IDs are hashed case-insensitively for matching.
Labels appear in output only when this option is supplied, so keep that output private. Equal labels
never merge distinct apps or alter rank, measurements, browser flags or collection. The old
`--class-map` option is removed. Without a label map, no names, text, bundle IDs, window titles or
paths are printed; even unexpected legacy app keys are hashed before output.

## Forget

```
B privacy forget --probe-run RUN
B privacy forget FROM TO
```

These commands preview only. Show the preview to the person requesting deletion, then use the
same scope with `--confirm CODE` only after their explicit approval. Deletion is immediate and
irreversible. The freshness code covers attempt headers, references, ordered parts and reachable blobs/chunks,
including incomplete content written under an unchanged pending header. Changing any of that state
requires a new preview. A freshness code does not prove approval. Ranges over 24 hours require
`--allow-over-24h` on both preview and confirmation.

Probe-run forget removes probe observations, counters, historical review rows and run settings,
retaining only a content-free cancellation barrier. It preserves ordinary history. Range forget
also removes probe observations in the range. Linked evidence deletion and retention continue to
remove associated probe rows. Existing unmanaged copies and backups are not erased; WAL
truncation can be busy and is reported by the command.
