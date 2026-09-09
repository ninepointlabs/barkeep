import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "BarkeepModel.js" as Model

// Barkeep — the overlay that tends the Omarchy bar.
//
// One fullscreen overlay (same surface tokens as the menu and clipboard) with
// a strip that mirrors the bar, a grouped list of every plugin the shell
// knows about, and a details pane with the actions that apply to the one
// under the cursor. Layout changes go straight through the shell's own
// PluginRegistry (the same code `omarchy bar move` and `omarchy plugin
// enable` end up in), so shell.json stays canonical and the bar updates live.
// Updates and removals run through the stock `omarchy plugin` commands from a
// detached helper, because both make the shell rebuild every overlay —
// including this one — and the helper brings Barkeep back afterwards.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string selfId: manifest && manifest.id ? String(manifest.id) : "ninepointlabs.barkeep"
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/ninepointlabs.barkeep"
  readonly property string opsPath: sourceDir + "/bin/barkeep-ops"
  readonly property var sections: ["left", "center", "right"]
  readonly property int inspectMaxAgeMs: 5 * 60 * 1000

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: -1
  property var rows: []
  property var strip: []
  property var current: null
  property var actions: []
  property bool checking: false
  property bool confirmOpen: false
  property var pendingConfirm: null
  property string statusText: ""
  property bool statusUrgent: false
  property int onBarCount: 0
  property int updateCount: 0

  // Menu surface tokens so themes that style the menu style Barkeep too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color dim: Util.alpha(foreground, 0.55)
  readonly property color faint: Util.alpha(foreground, 0.22)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX)
  property int groupHeight: Style.space(28)
  property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(680), panel.height - Style.gapsOut * 2)

  // ------------------------------------------------------------ lifecycle

  // Answered over IPC by `barkeep status` and by barkeep-ops when it brings
  // the overlay back after an update.
  function isOpen() {
    return root.opened ? "true" : "false"
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (!Util.isPlainObject(payload)) payload = ({})

    if (payload.select) Model.state.lastSelectedId = String(payload.select)
    if (payload.status !== undefined) {
      root.statusText = String(payload.status || "")
      root.statusUrgent = payload.urgent === true
    }

    root.opened = true
    root.filterText = ""
    root.confirmOpen = false
    root.pendingConfirm = null
    root.rebuild()
    root.refreshCatalog()
    if (Date.now() - Model.state.inspectedAt > root.inspectMaxAgeMs || payload.recheck === true) root.checkUpdates()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.confirmOpen = false
    root.opened = false
  }

  function dismiss() {
    root.confirmOpen = false
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Development aid: `omarchy-shell shell call ninepointlabs.barkeep renderTo
  // /tmp/barkeep.png` renders the card to a PNG without going through the
  // compositor's screencopy, which agents driving the overlay may not have.
  function renderTo(path) {
    var target = String(path || "")
    // Reachable by any process that can talk to the shell's IPC socket, so it
    // only ever writes a fresh PNG under the user's cache directory.
    var allowed = Quickshell.env("HOME") + "/.cache/"
    if (!root.opened || target.indexOf(allowed) !== 0 || target.indexOf("..") !== -1 || !/\.png$/.test(target))
      return "refused: path must be a .png under ~/.cache"
    card.grabToImage(function(result) { result.saveToFile(target) })
    return "ok"
  }

  // The shell rebuilds every panel loader when the set of enabled panels
  // changes (say, Barkeep just switched an overlay off). The rebuilt instance
  // is still marked open in the shell, but nobody calls open() on it — so if
  // that is our situation, reopen ourselves where the user left off.
  // Since Omarchy 4.0.3 the facade only answers isPluginOpen() for our own id.
  onShellChanged: {
    if (!root.shell) return
    Qt.callLater(function() {
      if (root.opened || !root.shell) return
      if (typeof root.shell.isPluginOpen === "function" && root.shell.isPluginOpen(root.selfId) === true)
        root.open("{}")
    })
  }

  // ---------------------------------------------------------------- model

  // Omarchy 4.0.3 stopped handing third-party plugins the shell's plugin
  // registry and config (each now gets a facade scoped to itself). Barkeep
  // needs the whole picture, so barkeep-ops rebuilds it from disk with the
  // same scan the shell runs, plus shell.json. Snapshot lives here; rebuild()
  // is pure over it. Refreshed on every open and after each change.
  property var catalogPlugins: ({})
  property var catalogConfig: ({})
  property bool catalogLoaded: false

  function refreshCatalog() {
    if (catalogProcess.running) { root.catalogDirty = true; return }
    catalogProcess.running = true
  }
  property bool catalogDirty: false

  function applyCatalog(text) {
    var parsed = null
    try { parsed = JSON.parse(text || "") } catch (e) { parsed = null }
    if (!parsed || !Util.isPlainObject(parsed.plugins)) {
      root.say("Could not read the plugin catalog (barkeep-ops catalog).", true)
      return
    }
    root.catalogPlugins = parsed.plugins
    root.catalogConfig = Util.isPlainObject(parsed.config) ? parsed.config : ({})
    root.catalogLoaded = true
    if (root.opened) root.rebuild()
  }

  function rebuild() {
    var plugins = root.catalogPlugins
    var config = root.catalogConfig
    var keepId = root.current ? root.current.id : Model.state.lastSelectedId

    root.rows = Model.buildRows(plugins, config, Model.state.inspect, root.filterText, root.selfId)
    root.strip = Model.buildStrip(plugins, config)
    root.updateCount = Model.countUpdates(root.rows)
    var placed = Model.placements(config)
    var n = 0
    for (var key in placed) n++
    root.onBarCount = n

    displayModel.clear()
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      displayModel.append({
        rowType: row.rowType,
        rowId: row.id,
        name: row.name,
        metaText: row.metaText || "",
        rowEnabled: row.enabled === true,
        rowOnBar: row.onBar === true,
        rowPinned: row.pinned === true,
        rowUpdate: row.updateAvailable === true,
        rowBarOption: row.isBarOption === true,
        rowActive: row.active === true
      })
    }

    var idx = Model.indexOfId(root.rows, keepId)
    if (idx === -1) idx = Model.firstPluginIndex(root.rows, Math.max(0, Math.min(root.selectedIndex, root.rows.length - 1)), 1)
    root.selectedIndex = idx
    root.syncCurrent()
    Qt.callLater(function() {
      // Start from the top so the first group header is visible, then scroll
      // only as far as the cursor row needs.
      resultList.positionViewAtBeginning()
      if (root.selectedIndex >= 0 && root.selectedIndex < displayModel.count)
        resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function syncCurrent() {
    var row = root.selectedIndex >= 0 && root.selectedIndex < root.rows.length ? root.rows[root.selectedIndex] : null
    root.current = row && row.rowType === "plugin" ? row : null
    root.actions = Model.actionsFor(root.current)
    Model.state.lastSelectedId = root.current ? root.current.id : ""
  }

  function select(delta) {
    if (root.rows.length === 0) return
    root.selectedIndex = root.selectedIndex < 0
      ? Model.firstPluginIndex(root.rows, delta < 0 ? root.rows.length - 1 : 0, delta < 0 ? -1 : 1)
      : Model.nextPluginIndex(root.rows, root.selectedIndex, delta)
    root.syncCurrent()
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectEdge(end) {
    if (root.rows.length === 0) return
    root.selectedIndex = end
      ? Model.firstPluginIndex(root.rows, root.rows.length - 1, -1)
      : Model.firstPluginIndex(root.rows, 0, 1)
    root.syncCurrent()
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectIndex(index) {
    if (index < 0 || index >= root.rows.length || root.rows[index].rowType !== "plugin") return
    root.selectedIndex = index
    root.syncCurrent()
  }

  function selectId(id) {
    var idx = Model.indexOfId(root.rows, id)
    if (idx === -1) return
    root.selectedIndex = idx
    root.syncCurrent()
    resultList.positionViewAtIndex(idx, ListView.Contain)
  }

  function setFilter(text) {
    root.filterText = text
    root.rebuild()
  }

  function say(text, isUrgent) {
    root.statusText = text || ""
    root.statusUrgent = isUrgent === true
  }

  // -------------------------------------------------------------- actions

  function runAction(action) {
    var row = root.current
    if (!row) return
    switch (action) {
      case "toggle": root.toggleEnabled(row); break
      case "sectionLeft": root.moveToSection(row, "left"); break
      case "sectionCenter": root.moveToSection(row, "center"); break
      case "sectionRight": root.moveToSection(row, "right"); break
      case "sectionPrev": root.slide(row, -1); break
      case "sectionNext": root.slide(row, 1); break
      case "nudgeLeft": root.reorder(row, -1); break
      case "nudgeRight": root.reorder(row, 1); break
      case "pin": root.togglePin(row); break
      case "open": root.openPlugin(row); break
      case "update": root.update(row); break
      case "remove": root.requestRemove(row); break
    }
  }

  // Every change goes out through `barkeep-ops mutate`, which wraps the stock
  // `omarchy plugin` / `omarchy bar` commands: they write shell.json
  // atomically and ask the shell to reload it, so the bar updates live and
  // the next catalog read sees the new state. One at a time; the CLI itself
  // serialises on shell.json.
  property var mutateQueue: []
  property string mutateOkText: ""
  property string mutateFailText: ""

  function mutate(args, okText, failText) {
    root.mutateQueue = root.mutateQueue.concat([{ args: args, ok: okText, fail: failText }])
    root.pumpMutate()
  }

  function pumpMutate() {
    if (mutateProcess.running || root.mutateQueue.length === 0) return
    var job = root.mutateQueue[0]
    root.mutateQueue = root.mutateQueue.slice(1)
    root.mutateOkText = job.ok
    root.mutateFailText = job.fail
    mutateProcess.command = [root.opsPath, "mutate"].concat(job.args)
    mutateProcess.running = true
  }

  function finishMutate(exitCode, text) {
    var line = String(text || "").trim().split("\n").pop() || ""
    if (exitCode === 0) root.say(root.mutateOkText, false)
    else root.say((root.mutateFailText ? root.mutateFailText + " " : "") + (line || ("barkeep-ops exited " + exitCode)), true)
    root.refreshCatalog()
    root.pumpMutate()
  }

  function toggleEnabled(row) {
    if (row.custom) { root.say("Custom modules are declared in shell.json; edit them there.", false); return }
    if (row.isSelf) { root.say("Barkeep cannot switch itself off from inside. Run: omarchy plugin disable " + root.selfId, false); return }
    if (row.isBarOption) {
      if (row.active) { root.say("A bar has no off switch; pick another bar option to replace it.", false); return }
      root.mutate(["use-bar", row.id], "Now using " + row.name + " as the bar.", "Could not switch bars.")
      return
    }
    var turnOn = row.isBarWidget ? !row.onBar : !row.enabled
    if (turnOn) {
      root.mutate(["enable", row.id],
        row.isBarWidget ? row.name + " is on the bar." : "Enabled " + row.name + ".",
        "Could not enable " + row.name + ".")
    } else {
      root.mutate(["disable", row.id],
        row.isBarWidget ? row.name + " is off the bar; its component stays available." : "Disabled " + row.name + ".",
        "Could not disable " + row.name + ".")
    }
  }

  function slide(row, direction) {
    var at = root.sections.indexOf(row.section)
    var next = at + direction
    if (next < 0 || next >= root.sections.length) return
    root.moveToSection(row, root.sections[next])
  }

  // Moving toward the left of the bar lands at the end of the new section,
  // moving right lands at its start, so the widget stays next to its old
  // neighbours instead of jumping across the screen.
  function moveToSection(row, target) {
    if (!row.onBar) { root.say("Put " + row.name + " on the bar first (Enter).", false); return }
    if (row.section === target) return
    var movingLeft = root.sections.indexOf(target) < root.sections.indexOf(row.section)
    root.mutate(["move", row.id, "--section", target, "--index", String(movingLeft ? 9999 : 0)],
      "Moved " + row.name + " to the " + target + " section.", "Could not move " + row.name + ".")
  }

  function reorder(row, direction) {
    if (!row.onBar) { root.say("Put " + row.name + " on the bar first (Enter).", false); return }
    var index = row.index + direction
    if (index < 0 || index >= row.count) return
    root.mutate(["move", row.id, "--section", row.section, "--index", String(index)],
      row.name + " is now " + (index + 1) + " of " + row.count + " in the " + row.section + " section.",
      "Could not move " + row.name + ".")
  }

  // "Fixed position": the bar's centerAnchor pins one center widget to the
  // exact middle of the screen and flanks the rest around it.
  function togglePin(row) {
    if (row.custom && !row.onBar) return
    if (!row.onBar) { root.say("Put " + row.name + " on the bar first (Enter).", false); return }
    if (row.pinned) {
      root.mutate(["unpin", row.id], row.name + " unpinned; the center section is centered as a group again.", "Could not unpin " + row.name + ".")
      return
    }
    root.mutate(["pin", row.id], row.name + " is pinned to the exact center of the bar.", "Could not pin " + row.name + ".")
  }

  // The facade only summons plugins Barkeep owns, so opening another
  // plugin's panel goes through the shell CLI, which is not scoped.
  function openPlugin(row) {
    if (!row.canOpen) return
    if (!(row.enabled || row.onBar)) { root.say("Enable " + row.name + " first (Enter).", false); return }
    var id = row.id
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.selfId)
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", id, "{}"])
  }

  function dirName(row) {
    return row && row.dir ? String(row.dir).split("/").pop() : ""
  }

  function update(row) {
    if (!row.updatable) { root.say(row.name + " is not a git checkout, so there is nothing to pull.", false); return }
    var name = root.dirName(row)
    if (!name) return
    var info = row.inspect || {}
    var what = info.behind > 0
      ? "Pull " + info.behind + " commit" + (info.behind === 1 ? "" : "s") + " into " + row.name + "?"
      : "Fetch and fast-forward " + row.name + "?"
    root.askConfirm({
      kind: "update",
      names: [name],
      select: row.id,
      message: what + " Plugin code runs unsandboxed inside omarchy-shell; the update is applied only if the manifest still validates.",
      confirmText: "Update"
    })
  }

  function updateAll() {
    var names = Model.updatableDirs(root.rows)
    if (names.length === 0) { root.say("Every git-managed plugin is up to date.", false); return }
    root.askConfirm({
      kind: "update",
      names: names,
      select: "",
      message: "Pull updates into " + names.length + " plugin" + (names.length === 1 ? "" : "s") + " (" + names.join(", ") + ")? Plugin code runs unsandboxed inside omarchy-shell.",
      confirmText: "Update all"
    })
  }

  function requestRemove(row) {
    if (!row.removable) {
      root.say(row.firstParty ? row.name + " ships with Omarchy; switch it off instead (Enter)." : "Barkeep cannot remove itself from inside.", false)
      return
    }
    var name = root.dirName(row)
    if (!name) return
    root.askConfirm({
      kind: "remove",
      row: row,
      names: [name],
      message: "Remove " + row.name + " (" + row.id + ")?"
        + (row.inspect && row.inspect.git
          ? " The folder is deleted; the git remote keeps the code."
          : " The folder is moved to a hidden backup next to it."),
      confirmText: "Remove"
    })
  }

  // Every action that changes files on disk goes through the same dialog, so
  // an accidental key press never pulls or deletes code.
  function askConfirm(request) {
    root.pendingConfirm = request
    confirmDialog.selectedIndex = 1
    root.confirmOpen = true
  }

  function cancelConfirm() {
    root.confirmOpen = false
    root.pendingConfirm = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function acceptConfirm() {
    var request = root.pendingConfirm
    root.confirmOpen = false
    root.pendingConfirm = null
    if (!request) return
    if (request.kind === "update") {
      Quickshell.execDetached([root.opsPath, "update"].concat(request.names))
      root.dismiss()
    } else if (request.kind === "remove") {
      var row = request.row
      // The stock remove command looks the plugin up by folder name; when the
      // folder is not named after the id, it would leave the shell.json entry
      // behind. Switch it off through the CLI first so the config is clean.
      // Detached, since the removal that follows tears this overlay down.
      if (row && (row.enabled || row.onBar) && !row.isBarOption)
        Quickshell.execDetached(["bash", "-c", "\"$0\" mutate disable \"$1\" >/dev/null 2>&1; exec \"$0\" remove \"$2\"", root.opsPath, row.id, request.names[0]])
      else
        Quickshell.execDetached([root.opsPath, "remove", request.names[0]])
      root.dismiss()
    }
  }

  function checkUpdates() {
    if (root.checking) return
    root.checking = true
    inspectProcess.running = true
  }

  function finishInspect(text) {
    root.checking = false
    Model.state.inspect = Model.parseInspect(text)
    Model.state.inspectedAt = Date.now()
    root.rebuild()
    if (root.statusUrgent) return
    var n = root.updateCount
    root.say(n === 0 ? "Checked for updates: everything is current." : n + " update" + (n === 1 ? "" : "s") + " available — Ctrl+Shift+U pulls them all.", false)
  }

  // ------------------------------------------------------------ processes

  ListModel { id: displayModel }

  Process {
    id: catalogProcess
    command: [root.opsPath, "catalog"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCatalog(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.say("Could not read the plugin catalog (barkeep-ops exited " + exitCode + ").", true)
      // A refresh asked for while this one ran: go again so the newest state wins.
      if (root.catalogDirty) { root.catalogDirty = false; catalogProcess.running = true }
    }
  }

  Process {
    id: mutateProcess
    command: []
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: mutateProcess.collected = text
    }
    onExited: function(exitCode) {
      var text = mutateProcess.collected
      mutateProcess.collected = ""
      root.finishMutate(exitCode, text)
    }
  }

  Process {
    id: inspectProcess
    command: [root.opsPath, "inspect"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishInspect(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.checking) {
        root.checking = false
        root.say("Could not inspect plugin folders (barkeep-ops exited " + exitCode + ").", true)
      }
    }
  }

  // ------------------------------------------------------------------ keys

  function handleKey(event) {
    if (root.confirmOpen) {
      if (confirmDialog.handleKey(event)) event.accepted = true
      return
    }

    // Omarchy pickers filter as you type; every action lives on a
    // non-printing key so typing never has to be switched on.
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

    if (event.key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else root.dismiss()
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
    } else if (event.key === Qt.Key_Down && shift) {
      root.runAction("sectionNext")
    } else if (event.key === Qt.Key_Up && shift) {
      root.runAction("sectionPrev")
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
    } else if (event.key === Qt.Key_Left) {
      root.runAction("nudgeLeft")
    } else if (event.key === Qt.Key_Right) {
      root.runAction("nudgeRight")
    } else if (event.key === Qt.Key_PageDown) {
      root.select(6)
    } else if (event.key === Qt.Key_PageUp) {
      root.select(-6)
    } else if (event.key === Qt.Key_Home) {
      root.selectEdge(false)
    } else if (event.key === Qt.Key_End) {
      root.selectEdge(true)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.runAction("toggle")
    } else if (event.key === Qt.Key_Delete) {
      root.runAction("remove")
    } else if (ctrl && event.key === Qt.Key_P) {
      root.runAction("pin")
    } else if (ctrl && event.key === Qt.Key_O) {
      root.runAction("open")
    } else if (ctrl && shift && event.key === Qt.Key_U) {
      root.updateAll()
    } else if (ctrl && event.key === Qt.Key_U) {
      root.runAction("update")
    } else if (ctrl && event.key === Qt.Key_R) {
      root.checkUpdates()
    } else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
    } else {
      return
    }
    event.accepted = true
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-barkeep"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.confirmOpen ? 20 : 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event) }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.confirmOpen
          z: 10
          message: root.pendingConfirm ? root.pendingConfirm.message : ""
          confirmText: root.pendingConfirm ? root.pendingConfirm.confirmText : "Confirm"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelConfirm()
          onConfirmed: root.acceptConfirm()
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ------------------------------------------------------- header
        Item {
          width: parent.width
          height: root.headerHeight

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Text {
              textFormat: Text.PlainText
              text: "󰐱"
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: "Barkeep"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? root.filterText + "▏" : "Type to filter…"
              color: root.filterText ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Text {
              textFormat: Text.PlainText
              visible: root.checking
              text: "󰑓"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              anchors.verticalCenter: parent.verticalCenter
              RotationAnimation on rotation {
                from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                running: root.checking
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.onBarCount + " on the bar"
                + (root.checking ? " · checking updates" : (root.updateCount > 0 ? " · " + root.updateCount + " update" + (root.updateCount === 1 ? "" : "s") : ""))
              color: root.updateCount > 0 && !root.checking ? root.selectedText : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        // ---------------------------------------------------- bar strip
        // Three rows, one per bar section, so the bar's structure is visible
        // and "move it to the right section" means the row below.
        BorderSurface {
          id: stripSurface
          width: parent.width
          height: stripColumn.implicitHeight + Style.spacing.md * 2
          radius: root.cornerRadius
          color: "transparent"
          borderSpec: Border.flat(root.faint, Style.normalBorderWidth)

          Column {
            id: stripColumn
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            spacing: 0

            Repeater {
              model: root.strip

              delegate: Item {
                id: sectionRow
                required property var modelData
                required property int index
                readonly property bool holdsCurrent: root.current && root.current.onBar && root.current.section === modelData.section

                width: parent.width
                height: Math.max(Style.spacing.controlHeight, chipFlow.implicitHeight + Style.spacing.sm * 2)

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  height: Style.normalBorderWidth
                  visible: sectionRow.index > 0
                  color: root.faint
                }

                Text {
                  id: sectionLabel
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(58)
                  text: sectionRow.modelData.label
                  color: sectionRow.holdsCurrent ? root.selectedText : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Flow {
                  id: chipFlow
                  anchors.left: sectionLabel.right
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.sm

                  Text {
                    textFormat: Text.PlainText
                    visible: sectionRow.modelData.chips.length === 0
                    text: "nothing here"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.italic: true
                    height: Style.spacing.controlHeight - Style.spacing.sm
                    verticalAlignment: Text.AlignVCenter
                  }

                  Repeater {
                    model: sectionRow.modelData.chips

                    delegate: Item {
                      id: chip
                      required property var modelData
                      readonly property bool selected: root.current && root.current.id === modelData.id

                      width: chipLabel.implicitWidth + Style.spacing.rowPaddingX * 2
                      height: Style.spacing.controlHeight - Style.spacing.sm

                      Rectangle {
                        anchors.fill: parent
                        radius: root.cornerRadius
                        color: chip.selected ? root.selectedBackground : "transparent"
                        border.width: Style.normalBorderWidth
                        border.color: chip.selected ? root.selectedText : root.faint
                      }

                      Text {
                        id: chipLabel
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: (chip.modelData.pinned ? "󰐃 " : "") + chip.modelData.label
                        color: chip.selected ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: chip.selected
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectId(chip.modelData.id)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---------------------------------------------------------- body
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - stripSurface.height - footer.height - root.contentSpacing * 3

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              id: listPane
              width: Math.round(parent.width * 0.42)
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                  id: row
                  required property int index
                  required property string rowType
                  required property string rowId
                  required property string name
                  required property string metaText
                  required property bool rowEnabled
                  required property bool rowOnBar
                  required property bool rowPinned
                  required property bool rowUpdate
                  required property bool rowBarOption
                  required property bool rowActive

                  readonly property bool isHeader: rowType === "header"
                  readonly property bool hasCursor: !isHeader && index === root.selectedIndex
                  readonly property bool isOn: rowBarOption ? rowActive : (rowOnBar || rowEnabled)

                  width: ListView.view.width
                  height: isHeader ? root.groupHeight : root.rowHeight

                  PanelSectionHeader {
                    visible: row.isHeader
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.spacing.xs
                    text: row.name
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Rectangle {
                    visible: !row.isHeader
                    anchors.fill: parent
                    radius: root.cornerRadius
                    color: row.hasCursor ? root.selectedBackground : "transparent"

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.spacing.rowPaddingX
                      anchors.rightMargin: Style.spacing.rowPaddingX
                      spacing: Style.spacing.lg

                      Text {
                        textFormat: Text.PlainText
                        width: Style.space(14)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.rowPinned ? "󰐃" : (row.isOn ? "●" : "○")
                        color: row.isOn ? (row.hasCursor ? root.selectedText : root.foreground) : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        horizontalAlignment: Text.AlignHCenter
                      }

                      Column {
                        width: parent.width - Style.space(14) - parent.spacing * 2 - metaLabel.width
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.xxs

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: row.name
                          color: row.hasCursor ? root.selectedText : root.foreground
                          opacity: row.isOn ? 1 : 0.7
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: row.hasCursor
                          elide: Text.ElideRight
                        }

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: row.rowId
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideMiddle
                        }
                      }

                      Text {
                        id: metaLabel
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: (row.rowUpdate ? "󰚰 " : "") + row.metaText
                        color: row.rowUpdate ? root.selectedText : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignRight
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      acceptedButtons: Qt.LeftButton
                      onClicked: root.selectIndex(row.index)
                      onDoubleClicked: { root.selectIndex(row.index); root.runAction("toggle") }
                    }
                  }
                }
              }

              Column {
                anchors.centerIn: parent
                width: parent.width - root.contentMargin
                spacing: Style.spacing.lg
                visible: displayModel.count === 0

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "󰐱"
                  color: root.selectedText
                  opacity: 0.8
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.filterText ? "Nothing matches “" + root.filterText + "”" : "No plugins found"
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                }
              }
            }

            Rectangle {
              width: Style.normalBorderWidth
              height: parent.height
              color: root.faint
            }

            Item {
              id: detailPane
              width: parent.width - listPane.width - Style.normalBorderWidth
              height: parent.height
              clip: true

              Flickable {
                id: detailFlick
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                contentWidth: width
                contentHeight: detailColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: detailColumn
                  width: detailFlick.width
                  spacing: Style.spacing.lg
                  visible: root.current !== null

                  Row {
                    width: parent.width
                    spacing: Style.spacing.lg

                    Text {
                      id: nameLabel
                      textFormat: Text.PlainText
                      text: root.current ? root.current.name : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, parent.width - versionLabel.width - parent.spacing)
                    }

                    Text {
                      id: versionLabel
                      textFormat: Text.PlainText
                      text: root.current && root.current.version ? "v" + root.current.version : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.baseline: nameLabel.baseline
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.current ? root.current.id + "  ·  " + root.current.kindsText : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: text !== ""
                    text: root.current ? root.current.description : ""
                    color: root.foreground
                    opacity: 0.85
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                  }

                  Rectangle { width: parent.width; height: Style.normalBorderWidth; color: root.faint }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.sm

                    Repeater {
                      model: root.current ? [
                        { label: "Where", value: root.current.isBarOption
                            ? (root.current.active ? "The bar in use" : "Bar option, not in use")
                            : root.current.onBar
                              ? "On the bar: " + Model.sectionLabel(root.current.section) + " section, " + (root.current.index + 1) + " of " + root.current.count
                                + (root.current.pinned ? " · pinned to the exact center" : "")
                              : (root.current.isBarWidget ? "Off the bar (component still available)" : (root.current.enabled ? "Enabled" : "Disabled")) },
                        { label: "Source", value: root.current.sourceText },
                        { label: "Folder", value: root.current.dir || "—" },
                        { label: "Updates", value: root.current.updateText || (root.current.firstParty ? "arrive with omarchy update" : "not git-managed; update by hand") }
                      ] : []

                      delegate: Row {
                        required property var modelData
                        width: parent.width
                        spacing: Style.spacing.lg

                        Text {
                          textFormat: Text.PlainText
                          width: Style.space(64)
                          text: modelData.label
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width - Style.space(64) - parent.spacing
                          text: modelData.value
                          color: modelData.label === "Updates" && root.current && root.current.updateAvailable ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          wrapMode: Text.WrapAnywhere
                          maximumLineCount: 3
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xs
                    visible: root.current && root.current.inspect && Array.isArray(root.current.inspect.incoming) && root.current.inspect.incoming.length > 0

                    PanelSectionHeader {
                      text: "Incoming commits"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }

                    Repeater {
                      model: root.current && root.current.inspect && Array.isArray(root.current.inspect.incoming)
                        ? root.current.inspect.incoming.slice(0, 6) : []

                      delegate: Text {
                        required property var modelData
                        textFormat: Text.PlainText
                        width: parent.width
                        text: "• " + modelData
                        color: root.foreground
                        opacity: 0.8
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }

                  Rectangle { width: parent.width; height: Style.normalBorderWidth; color: root.faint }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.lg

                    Repeater {
                      model: root.actions

                      delegate: Column {
                        id: actionGroup
                        required property var modelData
                        width: parent.width
                        spacing: Style.spacing.xs

                        PanelSectionHeader {
                          visible: actionGroup.modelData.title !== ""
                          text: actionGroup.modelData.title
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                        }

                        Flow {
                          width: parent.width
                          spacing: Style.spacing.md

                          Repeater {
                            model: actionGroup.modelData.items

                            delegate: Button {
                              required property var modelData
                              iconText: modelData.icon || ""
                              text: modelData.label + (modelData.hint ? "  " + modelData.hint : "")
                              bordered: true
                              selected: modelData.selected === true
                              enabled: modelData.enabled
                              opacity: modelData.enabled ? 1 : 0.4
                              foreground: modelData.danger ? root.urgent : root.foreground
                              accent: modelData.danger ? root.urgent : root.accent
                              fontFamily: root.fontFamily
                              fontSize: Style.font.bodySmall
                              iconSize: Style.font.bodySmall
                              onClicked: if (modelData.enabled) root.runAction(modelData.action)
                            }
                          }
                        }
                      }
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.current === null
                  width: detailFlick.width
                  text: "Pick a plugin on the left."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }

        // -------------------------------------------------------- footer
        Item {
          id: footer
          width: parent.width
          height: Math.max(Style.space(20), Style.font.caption + Style.spacing.sm)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: hints.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText
            color: root.statusUrgent ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: hints
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "↑↓ pick   ⏎ on/off   ←→ nudge along the bar   ⇧↑↓ change section   ^P pin   ^U update   ⌦ remove"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
