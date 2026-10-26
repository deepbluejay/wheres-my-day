# Where's my day?

Where's my day? started from one question: where did my day actually go?
It is a local Mac activity recorder with a menu-bar app and a timeline
window. It records foreground activity and input counts, extracts text from the
active window when capture is allowed, and stores the results in SQLite. Optional
account features summarize activity and let you ask questions about it.

Inside the code, the app, its command-line executable, bundle identifier and
data folder are still named ActivityProbe.

## License and contributions

Where's my day? is **source-available, not OSI open source**. It is free for
noncommercial use as defined by [PolyForm Noncommercial 1.0.0](LICENSE).
Any commercial use requires separate written permission from the copyright
holder. The license text defines which purposes are permitted. Contact
[deepbluejay through GitHub](https://github.com/deepbluejay) to request permission.
Third-party material retains its own terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Issues and bug reports are welcome. Outside code contributions, including pull
requests, are not accepted. Keep private activity and credentials out of reports.

Collection policy, admission exceptions, native input bounds and reproducible
stress measurements are documented in [Collection bounds](tools/CollectionBounds.md).

## Requirements

- macOS 14 or later.
- An Apple Swift toolchain supporting the Swift tools 5.9 package manifest and a
  compatible macOS SDK.
- Xcode providing `xcrun xcstringstool`, Python 3, and `codesign`.

The Swift package has no fetched package dependencies. Packaging compiles string
catalogs with `xcstringstool`; an installation without that tool fails the build
instead of producing a bundle without translations. Command Line Tools alone
may not provide it.

## Build and run

From the repository root:

```sh
./probe.sh build --adhoc
```

The result is `build/ActivityProbe.app`, including the separately signed
`ActivityQueryServer` helper and translations. Ad-hoc signing does not require a
developer signing certificate. For a certificate-signed build, supply an explicit
`SIGNING_IDENTITY` instead of `--adhoc`.

**Every build deletes the previous bundle first.** A build, packaging, or signing
failure leaves no previous runnable bundle at that location.

To build and launch the recorder with its menu-bar app:

```sh
./probe.sh start --adhoc
```

A saved Recording-off setting is respected. If you previously used `stop` or
turned Recording off in settings, this command opens the menu-bar app but leaves
the recorder stopped. Turn Recording on in settings to resume.

Open `build/ActivityProbe.app` in Finder to show the timeline, or use the menu-bar
app to open the timeline and settings. macOS permission approval is a manual step.
To check or stop the recorder without rebuilding:

```sh
B="$(pwd)/build/ActivityProbe.app/Contents/MacOS/ActivityProbe"
"$B" status
"$B" stop
```

Turning Recording off in settings also stops it. Quitting the window/menu process
does not stop the separate recorder.

### Start at login

The CLI can print, install, and remove a per-user LaunchAgent. Keep the bundle at
a stable location and use its absolute executable path. Inspect the configuration
before installing:

```sh
B="$(pwd)/build/ActivityProbe.app/Contents/MacOS/ActivityProbe"
"$B" launch-agent print "$B"
"$B" launch-agent install "$B" --live-switch
```

Installation replaces any job with the same label, loads the new job immediately,
and runs `collect` at login. A saved Recording-off setting is respected. Reinstall
after moving the bundle. To unload the job and remove its plist:

```sh
"$B" launch-agent uninstall --live-switch
```

The plist is `~/Library/LaunchAgents/dev.local.ActivityProbe.recorder.plist`.
Uninstalling the job does not erase recorded data.

## Developer tools

For read-only layer-1 recorder measurements, see
[the fidelity checker](tools/FidelityCheck.md). It compares agent instructions,
input attribution, optional history/Git/screen channels, Chrome visits, latest
file mtimes and timestamped shell history, reporting counts and denominators
without including private text in either JSON or its summary. It also compares
an optional reference recorder and can export seeded, masked samples into a
private local folder for separate judging, with a matching deletion command.

## macOS permissions

Use the Permissions section in settings to open the relevant macOS privacy pane
and approve access yourself.

- **Accessibility** reads focused-window details, including titles, document
  identifiers, and browser addresses. Without it, those accessibility details
  are unavailable; foreground-app observation and other permitted sources can
  still operate.
- **Input Monitoring** counts keyboard and mouse activity to distinguish human
  input from program-generated events. It stores counts, not typed keys.
  Without it, input observations are unavailable and input-triggered screen-text
  capture cannot proceed.
- **Screen Recording** captures the active window for local text recognition.
  Without it, screen text is unavailable; other permitted observations can
  continue. Images are used for recognition, not saved as screenshot files by
  this capture path.

Missing permissions appear in the app's health notices. Ad-hoc rebuilds can
require approving permissions again because the executable's code identity
changes.

## Data and privacy

Recorded history is stored locally at
`~/Library/Application Support/ActivityProbe/activity.sqlite`. App-owned support
files also live in that directory. `ACTIVITYPROBE_DB` changes the database path
only, not the app's support directory. Recording does not require an account.

Settings let you pause recording, turn it off, exclude apps, and set evidence
retention. ActivityProbe always excludes itself; the default exclusions include
password managers and messaging apps. Excluded apps' window titles and document
identifiers are omitted, and their screen text is not captured. Content-free
app/time/input records may remain. Secure Input suppresses screen-text capture.
Private browser windows are not automatically detected or excluded; exclude the
browser if its content must not be captured. Text is filtered for sensitive
patterns, but filtering cannot guarantee that every secret is removed.

Agent-log reading is optional and shares consent with subscription summaries.
It reads supported local assistant conversation logs only while that connection
is enabled and an eligible account is signed in. Disconnecting pauses new log
reading and summaries; it does not delete previously stored evidence.

Account features need your own eligible provider account. Conversations also
need the corresponding compatible command-line tool. When enabled or used,
summaries and conversations send selected activity content, your messages, and
requested activity-query results to the selected provider. Provider processing
is outside the local recorder. Building the app does not grant account access
or guarantee eligibility for those features.

### Delete a time range

Use `privacy forget`, starting with a preview. `FROM` and `TO` below are
placeholders for Unix seconds, or quoted local times in `YYYY-MM-DD HH:MM:SS`
format. The range includes `FROM` and excludes `TO`; `TO` must not be in the
future. Use Unix seconds if a local time is ambiguous.

```sh
"$B" privacy forget FROM TO
```

Review the preview and its counts. Only after deciding to delete, repeat the same
range with the returned code:

```sh
"$B" privacy forget FROM TO --confirm CODE
```

**Deletion is immediate and irreversible.** Ranges over 24 hours require
`--allow-over-24h` on both commands. Overlapping summarized intervals are removed
whole, including portions outside the requested range. The confirmation code
checks that the preview is still current; it does not stand in for your approval.
Settings, log-reading history and positions, numeric model-call costs and outer
ranges, existing database copies, and original source logs are not removed.

## Separate fork installations

The bundle identifier (`dev.local.ActivityProbe`), LaunchAgent label
(`dev.local.ActivityProbe.recorder`), and app-data directory name are fixed.
Before installing a second independent copy, rename these consistently in
`Info.plist`, `AppPaths`, `RecorderLaunchAgent`, and `AppDataPaths`, along with
related references. Otherwise copies share identities, the login job, and data.
