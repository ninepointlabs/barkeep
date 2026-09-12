#!/bin/bash

# tests/install_test.sh — what install.sh installs, and what it refuses to touch.
#
#   tests/install_test.sh
#
# Every case runs against a throwaway HOME with a stub omarchy-shell on PATH
# (the stub fails its ping, so the installer takes the "shell not running"
# branch and never talks to the real desktop).
#
# The foreign-owner case needs a second uid. Rather than ask for root it runs
# itself inside a user namespace with /etc/subuid mapped in, where it can chown
# a directory to an id that is not ours; without subuid ranges it is skipped.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="ninepointlabs.barkeep"
pass=0
fail=0
skip=0

ok()   { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
skipt(){ printf '  skip  %s\n' "$*"; skip=$((skip + 1)); }
note() { printf '\n%s\n' "$*"; }

# A sandbox HOME with the stub shell, returned on stdout.
new_home() {
  local home stub
  home="$(mktemp -d "${TMPDIR:-/tmp}/barkeep-test.XXXXXX")"
  stub="$home/.stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' >"$stub/omarchy-shell"
  chmod +x "$stub/omarchy-shell"
  printf '%s' "$home"
}

# Run the installer against a sandbox HOME. Output on stdout, status preserved.
run_install() {
  local home="$1"; shift
  env -i HOME="$home" PATH="$home/.stub:/usr/bin:/bin" TERM=dumb \
    "$REPO/install.sh" "$@" 2>&1
}

assert_installs() {
  local home="$1" desc="$2" out
  if out="$(run_install "$home")"; then
    ok "$desc"
  else
    bad "$desc (exit $?): $out"
  fi
}

# The installer must fail, and say why in a way that names the reason.
assert_refuses() {
  local home="$1" desc="$2" want="$3" out
  if out="$(run_install "$home")"; then
    bad "$desc — installer succeeded, expected refusal: $out"
  elif [[ $out == *"$want"* ]]; then
    ok "$desc"
  else
    bad "$desc — refused, but not with '$want': $out"
  fi
}

assert_file() {
  if [[ -f $1 && ! -L $1 ]]; then ok "$2"; else bad "$2 ($1 missing or not a plain file)"; fi
}
assert_absent() {
  if [[ -e $1 || -L $1 ]]; then bad "$2 ($1 exists)"; else ok "$2"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3"; fi
}

# ------------------------------------------------------- the ownership case

# Re-entry point: already inside the namespace, running as its root, so a
# directory can be handed to an id that is not ours.
if [[ ${1:-} == "--ownership-case" ]]; then
  home="$(new_home)"
  trap 'chown -R 0:0 "$home" 2>/dev/null; rm -rf "$home"' EXIT
  plugins="$home/.config/omarchy/plugins"

  mkdir -p "$plugins"
  chown 4242:4242 "$plugins"
  assert_refuses "$home" "foreign-owned plugins directory is refused" "owned by uid 4242"
  chown 0:0 "$plugins"

  mkdir -p "$plugins/$ID"
  printf '{"id":"someone.else"}\n' >"$plugins/$ID/manifest.json"
  chown -R 4242:4242 "$plugins/$ID"
  assert_refuses "$home" "foreign-owned plugin folder is not replaced" "not a Barkeep install owned by you"
  assert_contains "$plugins/$ID/manifest.json" "someone.else" "foreign plugin folder left untouched"
  chown -R 0:0 "$plugins/$ID"

  (( fail == 0 ))
  exit
fi

# ------------------------------------------------------------ normal install

note "install"
H="$(new_home)"
T="$H/.config/omarchy/plugins/$ID"
D="$H/.local/share/applications/barkeep.desktop"
B="$H/.local/bin/barkeep"

assert_installs "$H" "a fresh install succeeds"
assert_file "$T/manifest.json" "plugin manifest is installed"
assert_file "$T/Barkeep.qml" "overlay is installed"
assert_contains "$T/manifest.json" "\"id\": \"$ID\"" "installed manifest is ours"
if [[ -x $T/bin/barkeep && -x $T/bin/barkeep-ops ]]; then
  ok "launchers are executable"
else
  bad "launchers are executable"
fi
assert_absent "$T/install.sh" "installer itself is not copied"
assert_absent "$T/README.md" "markdown is not copied"
assert_absent "$T/LICENSE" "LICENSE is not copied"
assert_absent "$T/tests" "tests are not copied"
assert_file "$D" "app entry is a plain file"
assert_contains "$D" "Exec=\"$T/bin/barkeep\" toggle" "app entry points at the install"
if [[ -L $B && $(readlink "$B") == "$T/bin/barkeep" ]]; then
  ok "launcher symlink points at the install"
else
  bad "launcher symlink points at the install"
fi

note "re-install"
touch "$T/stale-file-from-an-older-version"
assert_installs "$H" "a re-install succeeds"
assert_absent "$T/stale-file-from-an-older-version" "a stale file from the previous install is gone"

note "uninstall"
mkdir -p "$H/.config/omarchy/plugins/someone.else"
printf '{"id":"someone.else"}\n' >"$H/.config/omarchy/plugins/someone.else/manifest.json"
if run_install "$H" --uninstall >/dev/null; then ok "uninstall succeeds"; else bad "uninstall succeeds"; fi
assert_absent "$T" "plugin folder is removed"
assert_absent "$D" "app entry is removed"
assert_absent "$B" "launcher symlink is removed"
assert_file "$H/.config/omarchy/plugins/someone.else/manifest.json" "another plugin is left alone"
rm -rf "$H"

# ------------------------------------------------------------- refusal cases

note "symlinked destinations"

H="$(new_home)"
mkdir -p "$H/.config/omarchy/plugins" "$H/decoy"
printf 'keep me\n' >"$H/decoy/precious"
ln -s "$H/decoy" "$H/.config/omarchy/plugins/$ID"
assert_refuses "$H" "a symlinked plugin folder is refused" "is a symlink"
assert_contains "$H/decoy/precious" "keep me" "the symlink target is not written or deleted"
rm -rf "$H"

H="$(new_home)"
mkdir -p "$H/.config/omarchy" "$H/elsewhere"
ln -s "$H/elsewhere" "$H/.config/omarchy/plugins"
assert_refuses "$H" "a symlinked path component is refused" "is a symlink"
assert_absent "$H/elsewhere/$ID" "nothing was written through the linked component"
rm -rf "$H"

H="$(new_home)"
mkdir -p "$H/.local/share/applications"
printf 'export SECRET=1\n' >"$H/.bashrc"
ln -s "$H/.bashrc" "$H/.local/share/applications/barkeep.desktop"
assert_refuses "$H" "a symlinked app entry is refused" "is a symlink"
assert_contains "$H/.bashrc" "export SECRET=1" "the file behind the link is not truncated"
rm -rf "$H"

H="$(new_home)"
mkdir -p "$H/.local/bin"
ln -s /usr/bin/true "$H/.local/bin/barkeep"
assert_refuses "$H" "a foreign launcher name is refused" "does not point at Barkeep"
if [[ $(readlink "$H/.local/bin/barkeep") == /usr/bin/true ]]; then
  ok "the existing launcher name is left as it was"
else
  bad "the existing launcher name is left as it was"
fi
rm -rf "$H"

note "unrelated targets"

H="$(new_home)"
mkdir -p "$H/.config/omarchy/plugins/$ID"
printf '{"id":"someone.else"}\n' >"$H/.config/omarchy/plugins/$ID/manifest.json"
assert_refuses "$H" "a folder that is not a Barkeep install is not replaced" "not a Barkeep install"
out="$(run_install "$H" --uninstall 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && [[ $out == *"refusing to delete"* ]]; then
  ok "uninstall refuses to delete a folder that is not ours"
else
  bad "uninstall refuses to delete a folder that is not ours: $out"
fi
assert_contains "$H/.config/omarchy/plugins/$ID/manifest.json" "someone.else" "that folder is still there"
rm -rf "$H"

H="$(new_home)"
mkdir -p "$H/.local/share/applications"
printf '[Desktop Entry]\nName=Something Else\n' >"$H/.local/share/applications/barkeep.desktop"
assert_refuses "$H" "an app entry we did not write is not overwritten" "refusing to overwrite"
out="$(run_install "$H" --uninstall 2>&1)"
assert_contains "$H/.local/share/applications/barkeep.desktop" "Something Else" "uninstall leaves that entry alone"
rm -rf "$H"

note "ownership"

if unshare --map-auto --map-root-user true 2>/dev/null; then
  # The nested run prints its own result lines; fold its tally into ours.
  nested="$(unshare --map-auto --map-root-user "$REPO/tests/install_test.sh" --ownership-case 2>&1)"
  printf '%s\n' "$nested"
  pass=$((pass + $(grep -c '^  ok ' <<<"$nested")))
  fail=$((fail + $(grep -c '^  FAIL ' <<<"$nested")))
else
  skipt "foreign-owned targets (no user-namespace uid mapping available)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
