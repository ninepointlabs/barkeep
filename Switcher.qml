import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "BarkeepModel.js" as Model

// Barkeep's bar chip: shows the bar profile in use and switches profiles.
//
// It reads ~/.config/omarchy/barkeep/profiles.json directly (and watches it),
// so a switch made anywhere — this chip, the overlay, `barkeep profile next`
// from a key binding — shows up here at once. Every change goes through
// bin/barkeep-profiles, launched detached: a switch rewrites the bar layout,
// and the bar rebuilds every widget, this one included, while it runs.
//
//   left click   the profile list, plus "save the current bar as…"
//   right click  Barkeep's Profiles view
//   scroll       next / previous profile
//   IPC          omarchy-shell ninepointlabs.barkeep-switcher toggle
Panel {
  id: root
  moduleName: "ninepointlabs.barkeep"
  // `omarchy-shell ninepointlabs.barkeep-switcher toggle` opens this list from
  // a key binding. With a bar on every monitor, the first one registered wins.
  ipcTarget: "ninepointlabs.barkeep-switcher"

  property var manifest: null

  readonly property string selfId: "ninepointlabs.barkeep"
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/ninepointlabs.barkeep"
  readonly property string profilesPath: sourceDir + "/bin/barkeep-profiles"
  readonly property string storePath: Quickshell.env("HOME") + "/.config/omarchy/barkeep/profiles.json"

  property var profiles: []
  property string activeKey: ""
  readonly property var activeProfile: Model.profileByKey(root.profiles, root.activeKey)
  property int cursor: 0
  property bool naming: false
  property bool initTried: false
  property string errorText: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function applyStore(text) {
    var parsed = Model.parseStore(text)
    if (!parsed) {
      root.errorText = "profiles.json could not be read; run barkeep profile list"
      return
    }
    root.errorText = ""
    root.profiles = parsed.profiles
    root.activeKey = parsed.active
  }

  function run(args) {
    Quickshell.execDetached([root.profilesPath, "--notify"].concat(args))
  }

  function use(key) {
    root.close()
    if (key && key !== root.activeKey) root.run(["use", key])
  }

  function saveAs(name) {
    var trimmed = String(name || "").trim()
    if (!trimmed) return
    root.naming = false
    root.run(["save", trimmed])
    root.close()
  }

  function openManager() {
    root.close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.selfId, JSON.stringify({ view: "profiles" })])
  }

  // Wheel ticks arrive in bursts; one switch per gesture is plenty, since
  // each one rebuilds the whole bar.
  function step(direction) {
    if (wheelGate.running || root.profiles.length < 2) return
    wheelGate.start()
    root.run([direction > 0 ? "next" : "prev"])
  }

  function moveCursor(delta) {
    var count = root.profiles.length + 2 // profiles, "save as", "manage"
    root.cursor = (root.cursor + delta + count) % count
  }

  function activateCursor() {
    if (root.cursor < root.profiles.length) root.use(root.profiles[root.cursor].key)
    else if (root.cursor === root.profiles.length) root.naming = true
    else root.openManager()
  }

  onOpenedChanged: {
    if (!opened) { root.naming = false; return }
    storeFile.reload()
    var at = Model.profileIndex(root.profiles, root.activeKey)
    root.cursor = at >= 0 ? at : 0
  }

  onNamingChanged: if (naming) Qt.callLater(function() { nameField.text = ""; nameField.forceActiveFocus() })

  FileView {
    id: storeFile
    path: root.storePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyStore(text())
    // First run: seed the store from the current bar, then read it.
    onLoadFailed: function(error) {
      if (root.initTried) return
      root.initTried = true
      initProcess.running = true
    }
  }

  Process {
    id: initProcess
    command: [root.profilesPath, "init"]
    onExited: storeFile.reload()
  }

  Timer {
    id: wheelGate
    interval: 700
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.activeProfile && root.activeProfile.icon ? root.activeProfile.icon : Model.PROFILE_ICONS[0]
    tooltipText: root.opened ? "" : "Bar profile: " + (root.activeProfile ? root.activeProfile.name : "none yet")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openManager()
      else root.toggle()
    }
    onWheelMoved: function(delta) { if (delta !== 0) root.step(delta < 0 ? 1 : -1) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      blocked: nameField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        PanelHero {
          width: parent.width
          title: "Bar profiles"
          meta: root.activeProfile ? "In use: " + root.activeProfile.name : "Loading…"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.profiles

          delegate: Button {
            required property var modelData
            required property int index
            width: column.width
            leftAlign: true
            iconText: modelData.icon || Model.PROFILE_ICONS[0]
            text: modelData.name + "   " + modelData.widgets + " widgets"
            selected: modelData.key === root.activeKey
            hasCursor: root.cursor === index
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            iconSize: Style.font.icon
            onClicked: root.use(modelData.key)
            onHovered: function(isHovered) { if (isHovered) root.cursor = index }
          }
        }

        PanelSeparator { width: parent.width }

        Button {
          visible: !root.naming
          width: parent.width
          leftAlign: true
          iconText: "󰐕"
          text: "Save the current bar as…"
          hasCursor: root.cursor === root.profiles.length
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          onClicked: root.naming = true
          onHovered: function(isHovered) { if (isHovered) root.cursor = root.profiles.length }
        }

        TextField {
          id: nameField
          visible: root.naming
          width: parent.width
          placeholderText: "Profile name, then Enter"
          foreground: root.foreground
          maximumLength: 40
          Keys.onReturnPressed: root.saveAs(text)
          Keys.onEnterPressed: root.saveAs(text)
          Keys.onEscapePressed: { root.naming = false; keys.forceActiveFocus() }
        }

        Button {
          width: parent.width
          leftAlign: true
          iconText: "󰐱"
          text: "Manage profiles in Barkeep"
          hasCursor: root.cursor === root.profiles.length + 1
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          onClicked: root.openManager()
          onHovered: function(isHovered) { if (isHovered) root.cursor = root.profiles.length + 1 }
        }
      }
    }
  }
}
