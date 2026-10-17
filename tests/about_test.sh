#!/bin/bash

# tests/about_test.sh — the About page's facts, checked against the repo.
#
#   tests/about_test.sh
#
# Loads BarkeepModel.js in node and checks what the About page shows against
# the real manifest.json, LICENSE and first commit, the support email it
# prefills, and that the privacy statement names every way Barkeep reaches the
# network: adding a host or a network command to the code without naming it
# there fails this test. Reads the repo only; touches nothing else.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v node >/dev/null; then
  echo "node is not on PATH; these tests load BarkeepModel.js with it" >&2
  exit 1
fi

FIRST_COMMIT="$(git -C "$REPO" log --reverse --format=%ad --date=format:'%B %Y' 2>/dev/null | head -n 1)"

REPO="$REPO" FIRST_COMMIT="$FIRST_COMMIT" node - <<'EOF'
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const repo = process.env.REPO
const read = (name) => fs.readFileSync(path.join(repo, name), "utf8")
let pass = 0
let fail = 0
function check(desc, ok, detail) {
  if (ok) { console.log("  ok    " + desc); pass++ }
  else { console.log("  FAIL  " + desc + (detail !== undefined ? " (" + detail + ")" : "")); fail++ }
}
function note(text) { console.log("\n" + text) }

// QML's `.pragma library` line is not JavaScript; everything after it is.
const Model = {}
vm.runInNewContext(read("BarkeepModel.js").replace(/^\.pragma library/m, ""), Model)
const manifest = JSON.parse(read("manifest.json"))
const license = read("LICENSE")

note("facts")
check("version comes from manifest.json", Model.manifestVersion(read("manifest.json")) === manifest.version,
  Model.manifestVersion(read("manifest.json")))
check("unreadable manifest gives no version", Model.manifestVersion("not json") === "" && Model.manifestVersion("") === "")
check("odd version strings are refused", Model.manifestVersion('{"version":"1.0 <b>"}') === "")
check("name matches manifest.json", Model.ABOUT.name === manifest.name)
check("made by Nine Point Labs", Model.ABOUT.organization === "Nine Point Labs" && manifest.author === "Nine Point Labs")
check("support address", Model.ABOUT.supportEmail === "help@ninepointlabs.com")
check("license name is LICENSE's first line", license.split("\n")[0].trim() === Model.ABOUT.license)
check("copyright as written in LICENSE", license.includes(Model.ABOUT.copyright.replace("©", "Copyright (c)")))
if (process.env.FIRST_COMMIT) check("created date is the first commit's month", Model.ABOUT.created === process.env.FIRST_COMMIT,
  process.env.FIRST_COMMIT)
else check("created date: no git history to check against", false)

note("license text")
const reflowed = Model.reflowLicense(license)
check("starts with the license name and copyright", reflowed.startsWith("MIT License\n\nCopyright (c) 2026 Nine Point Labs\n\nPermission"))
check("one line per paragraph", !reflowed.includes("a copy\nof"))
check("keeps the warranty disclaimer", reflowed.includes('THE SOFTWARE IS PROVIDED "AS IS"'))

note("versions and support email")
check("probes a minor version", Model.probedVersion((a, b) => a === 6 && b <= 11, 6) === "6.11")
check("probes Quickshell 0.x", Model.probedVersion((a, b) => a === 0 && b <= 3, 0) === "0.3")
check("unknown version is blank", Model.probedVersion(() => false, 6) === "" && Model.probedVersion(null, 6) === "")
check("built with, nothing known", Model.builtWith("", "") === "Quickshell and Qt")
const details = Model.aboutDetails("0.2.0", "0.3", "6.11", "Hyprland, wayland")
check("version details", details === "Barkeep 0.2.0\nQuickshell 0.3, Qt 6.11\nHyprland, wayland", JSON.stringify(details))
const mail = Model.supportMailto("0.2.0", details)
check("mailto subject", mail.startsWith("mailto:help@ninepointlabs.com?subject=Barkeep%200.2.0&body="), mail)
check("mailto body carries the details", decodeURIComponent(mail.split("&body=")[1]) === "\n\n--\n" + details)

note("privacy")
const privacy = Model.PRIVACY
for (const phrase of ["no telemetry", "git fetch", "omarchy plugin update", "origin remote",
  "~/.config/omarchy/plugins", "~/.config/omarchy/shell.json", "~/.config/omarchy/barkeep/profiles.json"])
  check("names " + phrase, privacy.includes(phrase))

// Every file that ships, scanned for hosts and for anything that reaches the
// network. Each must be named in the privacy statement.
const files = ["Barkeep.qml", "Switcher.qml", "BarkeepModel.js", "install.sh"]
  .concat(fs.readdirSync(path.join(repo, "bin")).map((f) => "bin/" + f))
const code = files.map((f) => read(f)).join("\n")
const hosts = new Set()
for (const m of code.matchAll(/\b(?:https?|wss?|ftp):\/\/([^\/"'\s$)]+)/g)) hosts.add(m[1])
for (const m of code.matchAll(/\bgit@([^:\s"']+):/g)) hosts.add(m[1])
for (const host of hosts) check("host " + host + " is named in the privacy statement", privacy.includes(host))
check("no URL in the code reaches a fixed host", hosts.size === 0, [...hosts].join(", "))
// Network-capable commands and APIs, and the words the statement uses for them.
const reaches = [
  [/\bgit\b[^\n]*\bfetch\b/, "git fetch"],
  [/\bomarchy-plugin-update\b/, "omarchy plugin update"],
  [/\bgit(?:\s+(?:-\S+|"\$\{[A-Z_]+\[@\]\}"|"\$[a-z_]+"))*\s+(clone|pull|ls-remote|push)\b/, "git clone/pull/ls-remote/push"],
  [/\bomarchy-plugin-add\b|\bomarchy plugin add\b/, "omarchy plugin add"],
  // ssh in GIT_SSH_COMMAND is git fetch's own transport, covered above.
  [/\b(curl|wget|nc|ncat|scp)\b|(?<!GIT_SSH_COMMAND=[^\n]*)\bssh\b/, "curl/wget/nc/ssh"],
  [/\bXMLHttpRequest\b|\bNetworkAccessManager\b|\bWebSocket\b|\bfetch\(/, "a network API"],
]
for (const [pattern, name] of reaches)
  if (pattern.test(code)) check("code uses " + name + "; the privacy statement names it", privacy.includes(name))

note("wiring")
const qml = read("Barkeep.qml")
check("F1 opens About", /Qt\.Key_F1[^\n]*\n\s*root\.showAboutPage\(\)/.test(qml))
check("info button in the header", qml.includes('objectName: "aboutButton"') && qml.includes('iconText: "󰋽"'))
check("both key-hint lines list F1", (qml.match(/F1 about"/g) || []).length === 2)
check("closing the overlay leaves About", (qml.match(/root\.showAbout = false\n/g) || []).length >= 2)
check("IPC about()", /function about\(\)/.test(qml))
check("barkeep about", /^\s*about\) omarchy-shell shell summon "\$SELF_ID" '\{"about":true\}'/m.test(read("bin/barkeep")))
check("README documents F1", /\| F1 \| About/.test(read("README.md")))

note("spelling")
const everything = fs.readdirSync(repo).filter((f) => /\.(qml|js|md|json|sh)$|^LICENSE$/.test(f)).map((f) => read(f)).join("\n")
  + files.map((f) => read(f)).join("\n")
// Built from pieces so this file never matches itself.
const misspelt = new RegExp(["Nine" + "point Labs", "NINE" + "POINT LABS", "Nine" + "Point Labs"].join("|"))
check("spelled Nine Point Labs everywhere", !misspelt.test(everything))

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail === 0 ? 0 : 1)
EOF
