#!/bin/bash

# Install (or refresh) Barkeep into the Omarchy shell.
#
#   ./install.sh            copy the plugin, enable it, add the app entry
#   ./install.sh --uninstall  remove all of that again
#
# The plugin is copied rather than symlinked: the shell's folder watcher only
# hot-reloads real files under ~/.config/omarchy/plugins. Re-run after edits.
#
# Everything this script writes lives at three well-known paths, and it will
# only ever create, replace or delete those three:
#
#   ~/.config/omarchy/plugins/ninepointlabs.barkeep   the plugin folder
#   ~/.local/share/applications/barkeep.desktop       the app entry
#   ~/.local/bin/barkeep                              the launcher symlink
#
# Before touching any of them it walks the path component by component and
# refuses to continue if a component is a symlink or is owned by another user,
# so a planted link cannot redirect a copy, a chmod or a delete somewhere else.
# The plugin folder is staged in a sibling temp directory and renamed into
# place, and the .desktop file is written to a temp file and renamed over the
# old one, so nothing live is ever truncated in place.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="ninepointlabs.barkeep"

die() {
  echo "install.sh: $*" >&2
  exit 1
}

# ------------------------------------------------------------------ identity

# Resolve HOME once and work from the resolved path: every destination below
# is built from it, so the checks that follow cover the whole path.
[[ -n ${HOME:-} ]] || die "HOME is not set"
[[ -d $HOME ]] || die "HOME ($HOME) is not a directory"
HOME_DIR="$(realpath -e -- "$HOME")" || die "cannot resolve HOME ($HOME)"

RUN_UID="$(id -u)"
HOME_UID="$(stat -c '%u' -- "$HOME_DIR")"

if [[ $RUN_UID != 0 && $HOME_UID != "$RUN_UID" ]]; then
  die "HOME ($HOME_DIR) is owned by uid $HOME_UID, not by you (uid $RUN_UID); refusing to install into another user's home"
fi

# Owners we accept on anything we create, replace or delete. Normally that is
# just the invoking user. A root-run install legitimately owns what root made,
# and still has to write into the target account's home.
ALLOWED_UIDS=("$RUN_UID")
if [[ $RUN_UID == 0 ]]; then
  ALLOWED_UIDS+=("$HOME_UID")
fi

PLUGINS_DIR="$HOME_DIR/.config/omarchy/plugins"
TARGET="$PLUGINS_DIR/$ID"
DESKTOP_DIR="$HOME_DIR/.local/share/applications"
DESKTOP="$DESKTOP_DIR/barkeep.desktop"
BIN_DIR="$HOME_DIR/.local/bin"
BIN_LINK="$BIN_DIR/barkeep"
# Written into the .desktop file so a later run can tell our entry from a
# same-named file that belongs to someone else.
MARKER="X-Barkeep-Install=$ID"

# --------------------------------------------------------------- path checks

# uid of a path without following it: GNU stat uses lstat unless -L is given,
# so a symlink reports the link's own owner, never the target's.
lowner() {
  stat -c '%u' -- "$1" 2>/dev/null || echo "-1"
}

owner_ok() {
  local uid
  uid="$(lowner "$1")"
  local allowed
  for allowed in "${ALLOWED_UIDS[@]}"; do
    if [[ $uid == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

require_owner() {
  owner_ok "$1" || die "$1 is owned by uid $(lowner "$1"), not by you (uid $RUN_UID); refusing to touch it"
}

# Walk $HOME_DIR/<rel> one component at a time, creating what is missing.
# Every component that already exists must be a real directory (not a symlink)
# owned by us; anything else stops the install rather than being written
# through. Returns with the directory existing and vetted.
ensure_dir_under_home() {
  local rel="$1" cur="$HOME_DIR" comp
  require_owner "$cur"
  local IFS=/
  # shellcheck disable=SC2086 # deliberate split on /
  set -- $rel
  unset IFS
  for comp in "$@"; do
    [[ -n $comp && $comp != "." && $comp != ".." ]] || die "refusing path component '$comp' in $rel"
    cur="$cur/$comp"
    if [[ -L $cur ]]; then
      die "$cur is a symlink; refusing to install through it (remove or repoint it, then re-run)"
    elif [[ -e $cur ]]; then
      [[ -d $cur ]] || die "$cur exists and is not a directory"
      require_owner "$cur"
    else
      mkdir -m 755 -- "$cur" || die "could not create $cur"
    fi
    if [[ $(stat -c '%a' -- "$cur") == *[2367] ]]; then
      echo "install.sh: warning: $cur is writable by other users; that weakens these checks" >&2
    fi
  done
}

# --------------------------------------------------------- our own artifacts

manifest_id() {
  local f="$1"
  [[ -f $f && ! -L $f ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.id // ""' "$f" 2>/dev/null
  else
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1
  fi
}

# True only for a real, self-owned directory carrying our own manifest, i.e.
# a Barkeep install and not some unrelated folder that landed on the path.
is_our_plugin_dir() {
  local d="$1"
  [[ -d $d && ! -L $d ]] || return 1
  owner_ok "$d" || return 1
  [[ $(manifest_id "$d/manifest.json" 2>/dev/null || true) == "$ID" ]]
}

# True for a real, self-owned .desktop file that we wrote. Entries written by
# older versions of this script carry no marker, so accept their Name/Exec.
is_our_desktop() {
  local f="$1"
  [[ -f $f && ! -L $f ]] || return 1
  owner_ok "$f" || return 1
  if grep -qxF "$MARKER" -- "$f"; then
    return 0
  fi
  grep -qxF "Name=Barkeep" -- "$f" && grep -qF "/$ID/bin/barkeep" -- "$f"
}

# True for a symlink of ours: points at the launcher inside our plugin folder.
is_our_bin_link() {
  local l="$1" dest
  [[ -L $l ]] || return 1
  owner_ok "$l" || return 1
  dest="$(readlink -- "$l")"
  [[ $dest == "$TARGET/bin/barkeep" ]]
}

# ------------------------------------------------------------------ uninstall

if [[ ${1:-} == "--uninstall" ]]; then
  omarchy-shell -q shell hide "$ID" || true
  omarchy-shell -q shell setPluginEnabled "$ID" false || true

  if [[ -L $TARGET ]]; then
    echo "install.sh: $TARGET is a symlink, not our plugin folder; leaving it alone" >&2
  elif [[ -e $TARGET ]]; then
    if is_our_plugin_dir "$TARGET"; then
      rm -rf -- "$TARGET"
    else
      die "$TARGET is not a Barkeep install owned by you; refusing to delete it"
    fi
  fi

  if [[ -L $DESKTOP ]]; then
    echo "install.sh: $DESKTOP is a symlink; leaving it alone" >&2
  elif [[ -e $DESKTOP ]]; then
    if is_our_desktop "$DESKTOP"; then
      rm -f -- "$DESKTOP"
    else
      echo "install.sh: $DESKTOP was not written by Barkeep; leaving it alone" >&2
    fi
  fi

  if [[ -e $BIN_LINK || -L $BIN_LINK ]]; then
    if is_our_bin_link "$BIN_LINK"; then
      rm -f -- "$BIN_LINK"
    else
      echo "install.sh: $BIN_LINK does not point at Barkeep; leaving it alone" >&2
    fi
  fi

  omarchy-shell -q shell rescanPlugins || true
  echo "Barkeep removed. Drop the SUPER + B binding from ~/.config/hypr/bindings.lua if you added one."
  exit 0
fi

[[ ${1:-} == "" ]] || die "unknown argument '$1' (use --uninstall)"

# -------------------------------------------------------------------- install

ensure_dir_under_home ".config/omarchy/plugins"
ensure_dir_under_home ".local/share/applications"
ensure_dir_under_home ".local/bin"

# Refuse early on a destination we must not replace, before anything is built.
if [[ -L $TARGET ]]; then
  die "$TARGET is a symlink; refusing to copy through it (remove it, then re-run)"
elif [[ -e $TARGET ]] && ! is_our_plugin_dir "$TARGET"; then
  die "$TARGET exists but is not a Barkeep install owned by you; refusing to replace it"
fi
if [[ -L $DESKTOP ]]; then
  die "$DESKTOP is a symlink; refusing to write through it (remove it, then re-run)"
elif [[ -e $DESKTOP ]] && ! is_our_desktop "$DESKTOP"; then
  die "$DESKTOP exists and was not written by Barkeep; refusing to overwrite it"
fi
if [[ -e $BIN_LINK || -L $BIN_LINK ]] && ! is_our_bin_link "$BIN_LINK"; then
  die "$BIN_LINK exists and does not point at Barkeep; refusing to replace it"
fi

# Stage inside the destination's own directory: same filesystem, so the swap
# below is a rename and never a half-copied plugin folder. mktemp -d creates
# exclusively, and both temp names are ours alone.
STAGE=""
BACKUP=""
cleanup() {
  local rc=$?
  if [[ -n $STAGE && -d $STAGE ]]; then
    rm -rf -- "$STAGE"
  fi
  if [[ -n $BACKUP && -d $BACKUP ]]; then
    if [[ -e $TARGET ]]; then
      rm -rf -- "$BACKUP"
    else
      # The swap did not finish; put the previous install back rather than
      # leave the user with no plugin folder at all.
      mv -T -- "$BACKUP" "$TARGET" || true
    fi
  fi
  return $rc
}
trap cleanup EXIT

STAGE="$(mktemp -d "$PLUGINS_DIR/.barkeep-stage.XXXXXX")"
chmod 755 "$STAGE"
rsync -a \
  --exclude '.git' --exclude 'install.sh' --exclude 'tests' --exclude '*.md' --exclude 'LICENSE' --exclude 'preview.png' \
  "$HERE/" "$STAGE/"
# The staged copy is not reachable under its final name yet, so this cannot
# mark anything outside it executable.
if compgen -G "$STAGE/bin/*" >/dev/null; then
  chmod +x "$STAGE/bin/"*
fi

# Swap: move any previous install aside, rename the staged copy into place.
# There is no atomic directory exchange in the shell, so the window between
# the two renames is the one moment the plugin folder is absent; the shell
# treats that as a plugin that vanished and reappeared, which is what a
# re-install looked like before as well.
if [[ -d $TARGET && ! -L $TARGET ]]; then
  BACKUP="$(mktemp -d "$PLUGINS_DIR/.barkeep-old.XXXXXX")"
  rmdir -- "$BACKUP"
  mv -T -- "$TARGET" "$BACKUP"
fi
mv -T -- "$STAGE" "$TARGET"
STAGE=""
if [[ -n $BACKUP ]]; then
  rm -rf -- "$BACKUP"
  BACKUP=""
fi

# Launcher symlink: build it under a fresh name (ln -s without -f fails if the
# name is taken, so it cannot clobber) and rename it over the old link.
TMP_LINK="$BIN_DIR/.barkeep.link.$$"
rm -f -- "$TMP_LINK"
ln -s -- "$TARGET/bin/barkeep" "$TMP_LINK"
mv -T -- "$TMP_LINK" "$BIN_LINK"

# App entry: written to a temp file in the same directory and renamed over the
# old one, so a live file is never opened for truncation.
TMP_DESKTOP="$(mktemp "$DESKTOP_DIR/.barkeep.desktop.XXXXXX")"
cat >"$TMP_DESKTOP" <<EOF
[Desktop Entry]
Version=1.0
Name=Barkeep
Comment=Tend the Omarchy bar: arrange, pin, update and remove shell plugins
Exec="$TARGET/bin/barkeep" toggle
Terminal=false
Type=Application
Icon=preferences-desktop
Categories=Settings;
Keywords=omarchy;plugins;bar;widgets;
StartupNotify=false
$MARKER
EOF
chmod 644 "$TMP_DESKTOP"
mv -T -- "$TMP_DESKTOP" "$DESKTOP"

if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null
  # The scan runs in the background; give it a moment before enabling.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if omarchy-shell shell listPlugins 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null; then
      break
    fi
    sleep 0.3
  done
  result=$(omarchy-shell shell enablePlugin "$ID" '{}' 2>&1 || true)
  if [[ $result == "ok" ]]; then
    echo "Barkeep installed and enabled."
  else
    echo "Barkeep copied, but enabling answered: $result" >&2
    echo "Run: omarchy plugin enable $ID" >&2
  fi
else
  echo "Barkeep copied. Start omarchy-shell, then run: omarchy plugin enable $ID"
fi

echo "Launch: barkeep   ·   or SUPER + B once bound   ·   or Apps > Barkeep"
