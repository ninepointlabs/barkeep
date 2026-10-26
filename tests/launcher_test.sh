#!/bin/bash

# tests/launcher_test.sh — bin/barkeep with the Omarchy shell down.
#
#   tests/launcher_test.sh
#
# omarchy-shell is a stub that fails every call, as when the shell is not
# running. Help, --version, unknown commands and `check` must still answer;
# the overlay commands must say the shell is not running. Runs against a
# throwaway HOME; nothing outside the temp directory is touched.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

ok()   { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '\n%s\n' "$*"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/barkeep-launcher-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
H="$ROOT/home"
STUB="$ROOT/stub"
mkdir -p "$H/.config/omarchy/plugins" "$STUB"
printf '#!/bin/sh\nexit 1\n' >"$STUB/omarchy-shell"
chmod +x "$STUB/omarchy-shell"

run() {
  env -i HOME="$H" PATH="$STUB:/usr/bin:/bin" TERM=dumb "$REPO/bin/barkeep" "$@" 2>&1
}
expect() { # description want-status want-output args...
  local desc="$1" want_rc="$2" want="$3" out rc; shift 3
  out=$(run "$@"); rc=$?
  if [[ $rc == "$want_rc" && $out == *"$want"* ]]; then ok "$desc"
  else bad "$desc (exit $rc): $out"; fi
}

VERSION="$(jq -r .version "$REPO/manifest.json")"

note "without the shell"
expect "--help works" 0 "barkeep profile <command>" --help
expect "help works" 0 "barkeep --version" help
expect "--version prints the manifest version" 0 "barkeep $VERSION" --version
expect "an unknown command is reported as unknown" 1 "unknown command 'nope'" nope
expect "check reads the plugin folders" 0 "[]" check
expect "the overlay needs the shell" 1 "omarchy-shell is not running" show
expect "the chip needs the shell" 1 "omarchy-shell is not running" chip on

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
