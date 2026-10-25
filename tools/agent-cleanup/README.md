# One-time agent cleanup

`agent-cleanup` is an operator command, separate from app startup and subscription connection.
It never invokes Claude or Codex, starts a server, opens a database, discovers a home, or prints
settings contents. It requires Python 3.11+ on PATH for complete TOML validation. The executable
uses Python isolated mode and passes only PATH to its child. Keep the SwiftPM Shell resource bundle
beside the executable when moving it outside the build directory.

## Intended answers

- Only literal allowlisted executable paths with the installed verb and matching provider qualify.
  Modified, mixed or ambiguous groups block the entire preflight. Same-name foreign binaries stay.
- Preserve all bytes outside removed tokens and necessary commas, including Unicode, CRLF, comments,
  unknown settings, foreign command bytes and their order. Never reserialize a settings file.
- Codex groups before any foreign group become empty in place. Existing empty groups always stay;
  this deliberately avoids guessing which empty group metadata referred to.
- Remove a ledger-recorded `trusted_hash` only when its stored value still matches. Keep `enabled`,
  other state and foreign hashes. Apply trust changes before removing the hook definitions.
- Remove only `activityprobe` registrations whose exact command is an allowlisted old app and
  whose arguments are exactly `["mcp"]`. Claude JSON must contain exactly `command`, `args` and
  `type: "stdio"`; Codex TOML must contain exactly `command` and `args`. Any additional field or
  changed value on an allowlisted command blocks the entire preflight, before backups or edits.
  A foreign same-name entry stays.
- Dry-run changes nothing. Apply requires `--live-switch`, keeps immediate-before 0600 backups in
  a new 0700 folder, verifies replacements, and changes nothing on the second successful run.
- Missing, unreadable, malformed, linked, hard-linked, changed or unsupported files block preflight.
  A detected concurrent save survives; the tool never rolls back over newer content.

## Operator procedure

First stop the old recorder and its repair/watchdog paths, close old app clients, and quiesce the
person's affected agent sessions. Only the coordinator/owner performs that live procedure. In-memory
hooks can survive a disk edit; a successful result does not establish session quiescence.

Establish the exact old executable identities and the Claude **user-scope** registration store
through a separately validated scoped lookup before supplying its home-relative path. The tool
does not guess that store or search project/local registrations. Codex defaults to `.codex/config.toml`;
use `--codex-config-file` with an operator-established home-relative user config store when it differs.
Both stores must be inside the explicit home and have verified user scope. It accepts a root `mcpServers`
JSON map and deliberately refuses the hooks file or ledger as the registration store.

```sh
swift build --product agent-cleanup --jobs 1
.build/debug/agent-cleanup --dry-run \
  --home /absolute/canonical/operator-selected-home \
  --old-app /exact/old/ActivityProbe \
  --old-hook /exact/old/ActivityProbeHook \
  --claude-mcp-file operator-established-user-store.json
.build/debug/agent-cleanup --apply --live-switch \
  --home /absolute/canonical/operator-selected-home \
  --old-app /exact/old/ActivityProbe \
  --old-hook /exact/old/ActivityProbeHook \
  --claude-mcp-file operator-established-user-store.json
```

Use the same arguments in both calls; executable options may repeat for verified historical installs.
The default trust ledger is `Library/Application Support/ActivityProbe/agent-hooks.json` relative to
that explicit home. Tests can pass another home-relative `--metadata-file`. All path components must
be actual directories/files, including the home itself. macOS `/tmp` is a symlink; use its canonical
`/private/tmp` spelling for invented homes.

Exit 0 means verified or a completed dry-run; exit 2 means blocked, including any missing inventory
file. JSON reports contain only fixed roles/reasons and counts, with no file contents or command
strings. `preserved_trust_mismatches` counts foreign/replaced hashes deliberately left alone.

Backups are in `.activityprobe-cleanup-<random>` below the explicit home. Its 0600 `manifest.json`
maps numbered `*.before` files to paths, modes and ownership; historical `.before-activityprobe`
backups and the app-owned ledger remain untouched. Do not print these backups or place them in
reports. Retain them privately through the switch and any owner-managed rollback.

Each file replacement is atomic, but the set of files is not one transaction. A later IO error may
leave earlier edits committed; `files_changed`, `verified_before_failure` and
`verification_failed_after_commit` expose exactly when replacement preceded failure.
Backups for every planned edit exist before the first replacement. Stop the switch on **any** blocked
result, preserve the old executable, resolve the reason and dry-run again. Never automatically
restore over settings another tool has since saved.

Advisory locks and repeated descriptor/inode/metadata/byte checks detect cooperating or observed
concurrent changes. They cannot close the final check-to-rename race against a noncooperating writer;
quiescence remains a live-switch precondition. Concurrent saves after verification are also outside
what a disk-only cleanup can guarantee.

TOML inline containers mixing owned and foreign trust/registrations, multiline targeted
registration assignments, and other layouts whose narrow byte edit cannot be proved are refused. No vendor config writer or formatting
fallback is used. Support those layouts with new invented fixtures and independent review before
using the tool on them. Do not broaden the allowlist or treat a blocked run as successful cleanup.

## Invented checks

`python3 -I tools/test_agent_cleanup.py` exercises byte-exact output, foreign positional approvals,
mixed/modified commands, legacy commands, mismatched hashes, private backups, idempotence, gating,
missing/unreadable/malformed files, symlink/hardlink/path traversal, concurrent saves and partial
failure reporting. `swift test --jobs 1` runs the same suite through XCTest. No real agent CLI or
personal settings are needed.
