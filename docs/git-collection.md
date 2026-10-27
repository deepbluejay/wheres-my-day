# Git collection boundaries

Collection accepts only its fixed Git built-ins: rev-parse, symbolic-ref, for-each-ref,
worktree list, merge-base, show, diff-tree, cat-file and rev-list. No command text comes
from a repository. Aliases cannot replace these built-ins. Global/system config and
the caller's environment are excluded. Repository configuration remains readable
because it defines repository format and worktree locations; Git has no supported
switch that ignores all local configuration while retaining normal discovery.

The command-line overrides disable log signature display and every supported GPG,
X.509 and SSH signature program. Metadata show also passes --no-show-signature.
Fsmonitor, hooks, external diff, textconv, pager, alternate-ref commands, automatic
GC and maintenance are disabled. Diff drivers cannot run under --no-ext-diff and
--no-textconv; clean/smudge/process filters are not used by object metadata or numstat
reads. Credential helpers are reset, askpass/SSH/git-proxy commands cannot prompt,
and GIT_ALLOW_PROTOCOL is empty. This environment allow-list takes precedence over
repository protocol.<name>.allow settings, including remote-helper transports.
There is no fetch, checkout, remote, credential, status or user alias command.
Includes/includeIf can supply configuration, but cannot restore an overridden
helper or add a command to the fixed collection surface. Local config can still
make a repository unreadable; failure is counted and retried.

Links retain tool, session, physical source, original cwd time and a hash of the
cwd discovery. Registration, backfill and existing-link checks consult the shared
tool-scoped own-source/session receipts and completed database revocations. A cwd
record uses its explicit session attribution before ordinary header metadata, both
when observed directly and when backfilled. Ordinary and lookahead checkpoint
sessions are consulted only when their explicit tool matches the link. Prepared
batches carry their lookahead state through the final registration transaction. A completed database receipt remains
authoritative when filesystem receipts are unavailable. Late session revocation
removes Git-only links in the same checkpoint transaction; independent human
provenance preserves shared repos.
Physical revocation removes only links in the proven tool namespace. Missing-tool
checkpoint state and legacy unscoped physical receipts cannot establish ownership.
Migration recovers a legacy link tool only from unambiguous physical event
provenance; unknown-tool links cannot borrow either registry's session membership.
A current checkpoint alone cannot assign its tool to an older link.
Checkpoints carry native cwdObservedAt rather than treating cursor polling as cwd discovery. Timestamp-free log cwd records never authorize Git discovery, including after Secure Input deferral or restart; the log task counts them in its timestampUnknownCwd ignored counter.
Migration freezes legacy time using retained original events/links where available.
A legacy checkpoint with no original receipt and an earlier forget is refused until
a new permitted cwd event establishes fresh provenance.
Forget freshness includes checkpoint discovery state, and permanent hash-only
discovery tombstones stop unchanged checkpoints and stale callbacks recreating links.
A new permitted cwd event has its own observation time and can register a new link.

`git_masked_reopen_blocked` is a count only. If masking changes the common directory,
its usable raw path exists only in memory. After restart, history cannot reopen it
until another raw cwd supplies that location. A deleted last worktree may make this
recovery impossible. A masked worktree alone does not block history when the common
directory remains ordinary, and ordinary unmasked repositories are unaffected.
Missing-folder and failure counts remain separate; no raw secret is persisted.

Discovery runs before the log checkpoint advances. History has its own worker queue,
so a large first read cannot hold later five-minute log/cwd discovery or summaries.
Hash spools and staged refs resume between time slices, rotating repositories after
0.25 seconds (at least one commit); this is scheduling, not a collection cap. A single
Git command still has a 30-second timeout and a commit slice may exceed its target
while finishing that commit. Completed rows persist across restart; old ref tips stay
in place until spool EOF, so a restart retries only uncompleted commits. Temporary
spools use an owned 0700 directory and 0600 files and are removed when released.

Commit preparation runs outside the shared storage lock and writer transaction.
The prepared storage interface keeps up to 65,536 masked UTF-8 bytes per field in
memory and publishes larger fields through 65,536-byte chunk transactions. The parent
insert holds at most 196,608 text bytes across its three metadata columns.
Large author, email and message values use ordered BLOB
chunks in `git_commit_text`, with field numbers 0, 1 and 2 respectively; the matching
parent column is empty. Concatenate chunk bytes in ordinal order before UTF-8 decoding,
since a scalar can cross a chunk boundary. Smaller values remain in the parent columns.
The parent stays incomplete until its metadata, files and refs finish. Recording
generation, source recovery, historical permission, tombstones and retention remain
publication checks; interrupted preparations cannot certify the ref frontier.

Chunk payloads participate in deletion previews and cascade with their commit during
forget, retention and ownership revocation. Status includes their count and byte total.
Schema 16 adds Git tables to actual main schemas 9, 14 and 15 without rewriting historical rows. Fresh databases are supported; undeployed branch schemas 10, 11, 12, 13 and the Git branch’s schema 14 are refused before opening a writer.
A separate WAL read connection exports previous ref tips without holding the shared
maintenance connection lock during filesystem writes.

Production reads use a two-pass reader: bounded raw windows build a private recipe
of lengths, flags and block hashes; verified replay writes masked-only spools. Raw
fields up to 65,536 bytes use the exact existing two-layer sanitizer. Larger fields
conservatively mask entire secret-bearing lexical units, preserve clear units and
publish ordered chunks of at most 65,536 bytes, including file paths and ref names.
Legacy caller-owned String convenience APIs still accept and sanitize whole Strings.
The Git child timeout measures idle output, excludes consumer work and resets on
progress; it imposes no total Git wall-time cap or collection size quota.

Discovery, reading, preparation, replay, staging and publication share a task stop
receipt. Each bounded publication unit checks it, including the final commit and
frontier certification. Cancellation never creates a privacy tombstone. Abandoned
parents are durably incomplete and pending frontiers are invalidated before cleanup.
Cleanup checks the same receipt between bounded batches, with a 0.1-second stop
grace. Ref staging uses a dedicated file-backed TEMP connection that stop closes
and unlinks immediately. If interrupted, the next collector startup or scan removes the remaining
uncertified work even while Recording is off. Startup recovery uses the background
history worker. Forget and retention still cover it;
user-initiated forget keeps its synchronous physical-erasure guarantee.
Masked text spools are unlinked as individual files; deferred scratch disposal
contains only numeric/hash recipes, with small text sanitized during verified replay.

Completed retention maintenance records a durable, monotonic maintenance time in
`git_retention_progress`. Publication computes its effective cutoff as
`max(scan time, completed maintenance time) - current retention days * 86400` inside
the writer transaction. Discovery uses the original cwd time; commits check both
author and commit time; ref frontiers check their original preparation time.
Ready/failed discovery, branch chunks/completion, commit insertion/completion,
metadata/path/ref chunks and frontier rows/chunks/pointer all repeat these checks.
Recording generation, retention policy and forget-range receipts travel with the
prepared work. Harmless cleanup still permits retained work. Increasing retention
can backfill older records because the stored progress is a clock, not a permanent
expiry cutoff. Storage interruptions do not count as Git read failures.

User forget retains one atomic physical-erasure transaction: fresh confirmation,
source/hash tombstones, secure deletion and end-state verification either commit
together or roll back. Chunk publication's 0.25-second writer target does not apply
to an unbounded, synchronous user-requested erase. The erase regression uses a
fixed 0.25-second admission allowance plus payload bytes / (32 MiB per second),
covering 1, 8, 32 and 128 MiB. Thus 32 MiB has a 1.25-second bound and 128 MiB has a
4.25-second bound. It also profiles DELETE statements and the actual transaction,
and samples a competing zero-timeout writer and maintenance reader. These are
regression budgets with scheduling/storage headroom, not hard real-time promises
or a claim that a real recorder cannot miss samples during physical erasure.

An invented local profile measured atomic transaction times of 0.007, 0.031, 0.081
and 0.375 seconds at 1, 8, 32 and 128 MiB respectively. Corresponding longest sampled
writer busy spans were 0, 0.079, 0.111 and 0.572 seconds; maintenance waits were
0.0001, 0.041, 0.078 and 0.544 seconds. The earlier independent 32-MiB profile reached
0.352 seconds of sampled writer busy time. These measurements justify retaining
size-dependent headroom rather than asserting a universal 0.25-second erase bound.
