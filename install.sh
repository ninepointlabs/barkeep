#!/bin/bash

# Install (or refresh) Barkeep into the Omarchy shell.
#
#   ./install.sh            copy the plugin, enable it, add the app entry
#   ./install.sh --uninstall  remove all of that again
#
# The plugin is copied rather than symlinked: the shell's folder watcher only
# hot-reloads real files under ~/.config/omarchy/plugins. Re-run after edits.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="ninepointlabs.barkeep"
TARGET="$HOME/.config/omarchy/plugins/$ID"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP="$DESKTOP_DIR/barkeep.desktop"
BIN_LINK="$HOME/.local/bin/barkeep"

if [[ ${1:-} == "--uninstall" ]]; then
  omarchy-shell -q shell hide "$ID" || true
  omarchy-shell -q shell setPluginEnabled "$ID" false || true
  rm -rf "$TARGET"
  rm -f "$DESKTOP" "$BIN_LINK"
  omarchy-shell -q shell rescanPlugins || true
  echo "Barkeep removed. Drop the SUPER + B binding from ~/.config/hypr/bindings.lua if you added one."
  exit 0
fi

mkdir -p "$TARGET" "$DESKTOP_DIR" "$HOME/.local/bin"
rsync -a --delete \
  --exclude '.git' --exclude 'install.sh' --exclude '*.md' --exclude 'LICENSE' --exclude 'preview.png' \
  "$HERE/" "$TARGET/"
chmod +x "$TARGET/bin/"*

ln -sfn "$TARGET/bin/barkeep" "$BIN_LINK"

cat >"$DESKTOP" <<EOF
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
EOF

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
