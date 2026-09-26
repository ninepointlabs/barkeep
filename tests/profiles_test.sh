#!/bin/bash

# tests/profiles_test.sh — bar profiles: what a switch writes, and what it keeps.
#
#   tests/profiles_test.sh
#
# Runs bin/barkeep-profiles against a throwaway HOME and a fake OMARCHY_PATH
# holding a handful of first-party manifests. omarchy-shell is a stub that
# answers "ok" and logs its calls; omarchy-shell-config is Omarchy's real
# helper, copied in, so shell.json is written by the same jq commit the stock
# `omarchy bar` commands use. Nothing outside the temp directory is touched.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

ok()   { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '\n%s\n' "$*"; }

HELPER="$(command -v omarchy-shell-config || true)"
if [[ -z $HELPER ]]; then
  echo "omarchy-shell-config is not on PATH; these tests need Omarchy's shell.json helper" >&2
  exit 1
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/barkeep-profiles-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
H="$ROOT/home"
OP="$ROOT/omarchy"
STUB="$ROOT/stub"
PLUGINS="$H/.config/omarchy/plugins"
CONFIG="$H/.config/omarchy/shell.json"
STORE="$H/.config/omarchy/barkeep/profiles.json"
OPS="$PLUGINS/ninepointlabs.barkeep/bin/barkeep-profiles"

mkdir -p "$STUB" "$PLUGINS" "$OP/config/omarchy" "$OP/shell/plugins"
cp "$HELPER" "$STUB/omarchy-shell-config"
cat >"$STUB/omarchy-shell" <<EOF
#!/bin/sh
echo "\$*" >>"$ROOT/shell-calls"
echo ok
EOF
chmod +x "$STUB/omarchy-shell"

manifest() { # dir id kinds-json [barWidget-json]
  mkdir -p "$1"
  jq -n --arg id "$2" --argjson kinds "$3" --argjson bw "${4:-null}" \
    '{schemaVersion: 1, id: $id, name: $id, kinds: $kinds} + (if $bw then {barWidget: $bw} else {} end)' >"$1/manifest.json"
}
manifest "$OP/shell/plugins/clock" omarchy.clock '["bar-widget"]' '{"allowMultiple": true}'
manifest "$OP/shell/plugins/audio" omarchy.audio '["bar-widget"]'
manifest "$OP/shell/plugins/menu" omarchy.menu '["menu", "bar-widget"]'
manifest "$PLUGINS/acme.mail" acme.mail '["service", "bar-widget"]'
manifest "$PLUGINS/acme.rotate" acme.rotate '["bar-widget"]'
manifest "$PLUGINS/acme.video" acme.video '["bar-widget"]'
mkdir -p "$PLUGINS/ninepointlabs.barkeep"
cp -r "$REPO/bin" "$REPO/manifest.json" "$PLUGINS/ninepointlabs.barkeep/"
echo '{"version": 1, "bar": {"layout": {"left": [], "center": [], "right": []}}, "plugins": []}' >"$OP/config/omarchy/shell.json"

cat >"$CONFIG" <<'EOF'
{
  "version": 1,
  "bar": {
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left": [{"id": "omarchy.menu"}],
      "center": [{"id": "omarchy.clock", "format": "HH:mm"}, {"id": "acme.rotate", "theme": "A"}],
      "right": [{"id": "ninepointlabs.barkeep"}, {"id": "acme.mail", "folders": "x"}, {"id": "omarchy.audio"}]
    }
  },
  "plugins": [{"id": "ninepointlabs.barkeep"}],
  "idle": {"lock": 300}
}
EOF

run() {
  env -i HOME="$H" OMARCHY_PATH="$OP" PATH="$STUB:/usr/bin:/bin" TERM=dumb "$OPS" "$@" 2>&1
}

# jq expression against a file must be true.
check() { # file expr description
  if jq -e "$2" "$1" >/dev/null 2>&1; then ok "$3"; else bad "$3"; printf '        %s\n' "$(jq -c "${4:-.}" "$1" 2>&1 | head -c 400)"; fi
}
ids() { printf '[.bar.layout.%s[].id]' "$1"; }

expect_ok() { # description args...
  local desc="$1" out; shift
  if out=$(run "$@"); then ok "$desc"; else bad "$desc: $out"; fi
}
expect_fail() { # description want args...
  local desc="$1" want="$2" out; shift 2
  if out=$(run "$@"); then bad "$desc — succeeded: $out"
  elif [[ $out == *"$want"* ]]; then ok "$desc"
  else bad "$desc — failed, but not with '$want': $out"; fi
}

# ---------------------------------------------------------------- first run

note "first run"
expect_ok "list creates the store" list
check "$STORE" '.version == 1 and .active == "default" and (.profiles | length) == 1' "the current bar becomes the Default profile"
check "$STORE" '.profiles[0].centerAnchor == "omarchy.clock" and ([.profiles[0].layout[][]] | length) == 6' "Default holds all six widgets and the pin"
check "$STORE" '.settings["acme.rotate"].theme == "A" and .settings["acme.mail"].folders == "x"' "single-instance settings are captured"
check "$STORE" '.settings["omarchy.clock"] == null' "a multi-instance widget keeps its settings in the profile only"
if [[ $(stat -c '%a' "$STORE") == 600 ]]; then ok "the store is private to you"; else bad "the store is private to you"; fi
check "$CONFIG" '.idle.lock == 300' "shell.json is not rewritten by a read"

# ---------------------------------------------------------- save and switch

note "save as"
expect_ok "save the current bar as Video" save Video
check "$STORE" '.active == "video" and (.profiles | map(.key)) == ["default", "video"]' "Video is saved and in use"
expect_ok "a second Video gets its own key, not an error" save Video
check "$STORE" '(.profiles | map(.key)) == ["default", "video", "video-2"]' "duplicate names get a numbered key"
expect_ok "switch away from the copy" use video
expect_ok "delete video-2" delete video-2

note "arranging the live bar, then switching"
# Rearrange the live bar the way the user would while in Video: mail off, a
# video widget on, the rotate widget's setting changed, a different clock.
jq '.bar.layout.center = [{"id": "omarchy.clock", "format": "HH"}, {"id": "acme.rotate", "theme": "B"}]
  | .bar.layout.right = [{"id": "ninepointlabs.barkeep"}, {"id": "acme.video"}, {"id": "omarchy.audio"}]' \
  "$CONFIG" >"$ROOT/c.json" && mv "$ROOT/c.json" "$CONFIG"
: >"$ROOT/shell-calls"
expect_ok "switch to Default" use default
check "$STORE" '.active == "default"' "Default is in use"
check "$STORE" '(.profiles[] | select(.key == "video") | [.layout.right[].id]) == ["ninepointlabs.barkeep", "acme.video", "omarchy.audio"]' "the edits made in Video were saved into Video"
check "$CONFIG" "$(ids right) == [\"ninepointlabs.barkeep\", \"acme.mail\", \"omarchy.audio\"]" "Default's widgets are back on the bar"
check "$CONFIG" '(.bar.layout.right[] | select(.id == "acme.mail") | .folders) == "x"' "mail comes back with its settings"
check "$CONFIG" '(.bar.layout.center[] | select(.id == "acme.rotate") | .theme) == "B"' "a shared setting follows the widget across profiles"
check "$CONFIG" '(.bar.layout.center[] | select(.id == "omarchy.clock") | .format) == "HH:mm"' "a multi-instance widget keeps its per-profile settings"
check "$CONFIG" '.bar.centerAnchor == "omarchy.clock"' "the center pin is restored"
check "$CONFIG" '.idle.lock == 300 and .version == 1' "everything outside the bar layout is untouched"
if grep -qx 'shell reloadConfig' "$ROOT/shell-calls"; then ok "the shell is asked to reload"; else bad "the shell is asked to reload"; fi

note "services that leave the bar"
expect_ok "switch to Video" use video
check "$CONFIG" "$(ids right) == [\"ninepointlabs.barkeep\", \"acme.video\", \"omarchy.audio\"]" "Video's layout is on the bar"
check "$CONFIG" '[.plugins[].id] | index("acme.mail") != null' "mail's service stays enabled through plugins[]"
check "$CONFIG" '[.plugins[].id] | index("acme.rotate") == null' "a widget without a service is not kept alive"
expect_ok "and back to Default" use default
check "$CONFIG" '[.plugins[].id | select(. == "acme.mail")] | length == 1' "the keep-alive entry is not added twice"

note "the switcher stays on the bar"
jq '(.profiles[] | select(.key == "video") | .layout.right) |= map(select(.id != "ninepointlabs.barkeep"))' "$STORE" >"$ROOT/s.json" && cp "$ROOT/s.json" "$STORE"
expect_ok "switch to a profile saved without the switcher" use video
check "$CONFIG" "$(ids right)[0] == \"ninepointlabs.barkeep\"" "the switcher keeps its place"
expect_ok "and back" use default

note "plugins that are gone, and the pin"
jq '(.profiles[] | select(.key == "video") | .layout.left) += [{"id": "gone.plugin"}, {"id": "vpn", "type": "command", "exec": "true"}]
  | (.profiles[] | select(.key == "video") | .centerAnchor) = "acme.video"' "$STORE" >"$ROOT/s.json" && cp "$ROOT/s.json" "$STORE"
expect_ok "switch to a profile naming an uninstalled plugin" use video
check "$CONFIG" "$(ids left) == [\"omarchy.menu\", \"vpn\"]" "the uninstalled plugin is skipped, a custom module is kept"
check "$STORE" '[.profiles[] | select(.key == "default") | .layout.left[].id] == ["omarchy.menu"]' "Default was saved on the way out"
check "$CONFIG" '.bar.centerAnchor == null' "a pin on a widget outside the center is dropped"
check "$STORE" '[.profiles[] | select(.key == "video") | .layout.left[].id] | index("gone.plugin") != null' "the profile still remembers the uninstalled plugin"

# ------------------------------------------------------------ housekeeping

note "cycling, naming, deleting"
expect_ok "next" next
check "$STORE" '.active == "default"' "next wraps around to the first profile"
expect_ok "prev" prev
check "$STORE" '.active == "video"' "prev goes back"
expect_ok "a profile can be named by its name, any case" use DEFAULT
expect_ok "rename" rename video "Video editing"
check "$STORE" '(.profiles[] | select(.key == "video") | .name) == "Video editing"' "the name changes, the key does not"
expect_ok "set an icon" icon video $'\xf3\xb0\xbf\x8e'
check "$STORE" '(.profiles[] | select(.key == "video") | .icon | explode) == [987086]' "the icon is stored"
expect_fail "a long icon is refused" "one to four characters" icon video "not an icon"
expect_fail "an empty name is refused" "needs a name" rename video "   "
expect_ok "duplicate" duplicate video "Gaming"
check "$STORE" '(.profiles | map(.key)) == ["default", "video", "gaming"] and (.profiles[2].layout == .profiles[1].layout)' "the copy has the same layout"
expect_ok "duplicating the profile in use copies the live bar" duplicate default "Work"
check "$STORE" '(.profiles[] | select(.key == "work") | [.layout.right[].id]) == ["ninepointlabs.barkeep", "acme.mail", "omarchy.audio"]' "Work matches the live bar"
expect_fail "the profile in use cannot be deleted" "switch to another one first" delete default
expect_ok "another profile can" delete gaming
expect_fail "an unknown profile is reported" "no profile called" use nope

note "the switcher chip"
chip() {
  env -i HOME="$H" OMARCHY_PATH="$OP" PATH="$STUB:/usr/bin:/bin" TERM=dumb \
    "$PLUGINS/ninepointlabs.barkeep/bin/barkeep-ops" mutate "$1" ninepointlabs.barkeep 2>&1
}
jq '.plugins = []' "$CONFIG" >"$ROOT/c.json" && mv "$ROOT/c.json" "$CONFIG"
if chip chip-off >/dev/null; then ok "chip-off succeeds"; else bad "chip-off succeeds"; fi
check "$CONFIG" '[.bar.layout[][] | .id] | index("ninepointlabs.barkeep") == null' "the chip leaves the bar"
check "$CONFIG" '[.plugins[].id] | index("ninepointlabs.barkeep") != null' "the overlay stays enabled"
if chip chip-on >/dev/null; then ok "chip-on succeeds"; else bad "chip-on succeeds"; fi
check "$CONFIG" '.bar.layout.right[0].id == "ninepointlabs.barkeep" and ([.plugins[].id | select(. == "ninepointlabs.barkeep")] | length) == 1' "the chip is back at the start of the right section, the overlay listed once"
chip chip-on >/dev/null
check "$CONFIG" '[.bar.layout[][] | select(.id == "ninepointlabs.barkeep")] | length == 1' "putting it on twice leaves one chip"

note "refusals"
cp "$STORE" "$ROOT/good.json"
echo '{"version": 2}' >"$STORE"
expect_fail "a store it does not understand is not overwritten" "not a valid profile store" save Other
check "$STORE" '.version == 2' "that store is left as it was"
cp "$ROOT/good.json" "$STORE"

mv "$H/.config/omarchy/barkeep" "$ROOT/real-store"
ln -s "$ROOT/real-store" "$H/.config/omarchy/barkeep"
expect_fail "a symlinked store directory is refused" "is a symlink" list
rm "$H/.config/omarchy/barkeep"
mv "$ROOT/real-store" "$H/.config/omarchy/barkeep"

cp "$STORE" "$ROOT/good.json"
rm "$STORE"
ln -s "$ROOT/good.json" "$STORE"
expect_fail "a symlinked store file is refused" "not a plain file" list
rm "$STORE"
cp "$ROOT/good.json" "$STORE"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
