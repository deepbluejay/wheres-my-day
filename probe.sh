#!/bin/bash
# Build a fresh signed bundle before running any command.
# SIGNING_IDENTITY='...' ./probe.sh build
# ./probe.sh build --adhoc  (isolated development and tests)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ActivityProbe.app
BIN="$APP/Contents/MacOS/ActivityProbe"
ADHOC=0
ARGS=()
for argument in "$@"; do
  if [ "$argument" = --adhoc ]; then ADHOC=1; else ARGS+=("$argument"); fi
done
if [ "${#ARGS[@]}" -gt 0 ]; then set -- "${ARGS[@]}"; else set -- status; fi

# The source a bundle is built from: HEAD and the tree of every tracked and untracked file, read through
# a private index so the real one is untouched. The checking tools compare it with the source they check.
source_state() {
  local head tree folder
  if ! head=$(git rev-parse --verify -q HEAD 2>/dev/null); then echo 'commit=unknown'; return; fi
  folder=$(mktemp -d "${TMPDIR:-/tmp}/probe-index.XXXXXX")
  GIT_INDEX_FILE="$folder/index" git read-tree HEAD
  GIT_INDEX_FILE="$folder/index" git add -A
  tree=$(GIT_INDEX_FILE="$folder/index" git write-tree)
  rm -rf "$folder"
  printf 'commit=%s\ntree=%s\ndirty=%s\n' "$head" "$tree" "$([ "$tree" = "$(git rev-parse 'HEAD^{tree}')" ] && echo 0 || echo 1)"
}

build() (
  mkdir -p build
  # Keep the descriptor open in this subshell, including while recovering abandoned stages.
  # The kernel releases the lock even after SIGKILL; never unlink its shared inode.
  exec 9>build/.packaging.lock
  /usr/bin/python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
  rm -rf build/.bundle.*
  local identity
  if [ "$ADHOC" = 1 ]; then
    identity=-
  elif [ -n "${SIGNING_IDENTITY:-}" ] && [ "$SIGNING_IDENTITY" != - ]; then
    identity="$SIGNING_IDENTITY"
  else
    rm -rf "$APP" build/.bundle-commit
    echo 'Set SIGNING_IDENTITY explicitly, or use --adhoc for isolated development.' >&2
    exit 2
  fi
  # Dependencies come first: a remote that cannot be read stops here and changes nothing, so the
  # bundle already built stays. Nothing below runs, and the command exits without launching it.
  local resolved=0
  swift package resolve || resolved=$?
  if [ "$resolved" -ne 0 ]; then
    echo 'Dependencies did not resolve: previous bundle kept, not rebuilt.' >&2
    exit "$resolved"
  fi
  local source
  source=$(source_state)
  # From here an unsuccessful attempt must never leave an older bundle available to launch.
  rm -rf "$APP" build/.bundle-commit

  STAGE=$(mktemp -d build/.bundle.XXXXXX)
  trap 'result=$?; rm -rf "$STAGE"; if [ "$result" -ne 0 ]; then rm -rf "$APP" build/.bundle-commit; fi; exit "$result"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  swift build --jobs 1 --product ActivityProbe
  swift build --jobs 1 --product ActivityQueryServer
  local products bundle helper
  products=$(swift build --jobs 1 --show-bin-path)
  bundle="$STAGE/ActivityProbe.app"
  helper="$bundle/Contents/MacOS/ActivityQueryServer"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$products/ActivityProbe" "$bundle/Contents/MacOS/ActivityProbe"
  cp "$products/ActivityQueryServer" "$helper"
  cp Info.plist "$bundle/Contents/Info.plist"
  python3 tools/strings.py compile "$bundle/Contents/Resources"
  local language
  for language in en ko ja zh-Hans zh-Hant de fr es ru; do
    test -s "$bundle/Contents/Resources/$language.lproj/Localizable.strings"
  done

  # The app's seal includes the helper, so sign the helper first.
  codesign --force --sign "$identity" "$helper"
  codesign --force --sign "$identity" "$bundle"
  codesign --verify --strict "$helper"
  codesign --verify --strict "$bundle"
  # A source edited while it was built may or may not be in the bundle, so neither state can be recorded.
  if [ "$(source_state)" != "$source" ]; then
    echo 'The source changed during the build: bundle removed, not recorded.' >&2
    exit 3
  fi
  mv "$bundle" "$APP"
  printf '%s\n' "$source" > build/.bundle-commit
  rm -rf "$STAGE"
  trap - EXIT INT TERM HUP
)

case "$1" in
  build) build ;;
  start) shift; build; open -n -g "$APP" --args collect "$@"; sleep 2; "$BIN" status ;;
  settings) shift; build; open -n "$APP" --args settings "$@" ;;
  *) build; "$BIN" "$@" ;;
esac
