.pragma library

// Pure model code for the Barkeep overlay. No QML imports here so every
// function is plain JavaScript: rows in, rows out. `.pragma library` makes
// the `state` object survive a shell.json-triggered re-instantiation of the
// overlay (the shell rebuilds every panel loader whenever the set of enabled
// panels changes), which is how the cursor and the last update check stay
// put when Barkeep itself gets rebuilt under the user.

var SECTIONS = ["left", "center", "right"]

var state = {
  lastSelectedId: "",
  inspect: {},          // sourceDir -> git/inspect info
  inspectedAt: 0,
  status: "",
  statusUrgent: false
}

function canonical(id) {
  return String(id || "").trim()
}

function entryId(entry) {
  if (entry && typeof entry === "object") return canonical(entry.id)
  return canonical(entry)
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function hasKind(manifest, kind) {
  return !!(manifest && Array.isArray(manifest.kinds) && manifest.kinds.indexOf(kind) !== -1)
}

function layoutOf(config) {
  var bar = config && isObject(config.bar) ? config.bar : {}
  var layout = isObject(bar.layout) ? bar.layout : {}
  var out = {}
  for (var i = 0; i < SECTIONS.length; i++) {
    var list = layout[SECTIONS[i]]
    out[SECTIONS[i]] = Array.isArray(list) ? list : []
  }
  return out
}

// id -> { section, index, count } for every entry on the bar.
function placements(config) {
  var layout = layoutOf(config)
  var placed = {}
  for (var s = 0; s < SECTIONS.length; s++) {
    var list = layout[SECTIONS[s]]
    for (var i = 0; i < list.length; i++) {
      var id = entryId(list[i])
      if (!id || placed[id]) continue
      placed[id] = { section: SECTIONS[s], index: i, count: list.length }
    }
  }
  return placed
}

function activeBarId(config) {
  var bar = config && isObject(config.bar) ? config.bar : {}
  return canonical(bar.id) || "omarchy.bar"
}

function centerAnchor(config) {
  var bar = config && isObject(config.bar) ? config.bar : {}
  return canonical(bar.centerAnchor)
}

function isDisabled(config, id) {
  return !!(config && Array.isArray(config.disabledPlugins) && config.disabledPlugins.indexOf(id) !== -1)
}

function inPluginsList(config, id) {
  if (!config || !Array.isArray(config.plugins)) return false
  for (var i = 0; i < config.plugins.length; i++) {
    if (entryId(config.plugins[i]) === id) return true
  }
  return false
}

function shortName(manifest, id) {
  var name = manifest && manifest.name ? String(manifest.name) : ""
  if (name) return name
  var tail = String(id || "").split(".").pop()
  return tail || String(id || "")
}

function sourceLabel(row) {
  if (row.custom) return "custom module from shell.json"
  if (row.firstParty) return "ships with Omarchy"
  if (row.clonedFrom) return "clone of " + row.clonedFrom
  if (!row.inspect) return "local folder"
  if (row.inspect.symlink) return "symlink to " + (row.inspect.target || "another folder")
  if (row.inspect.git) return row.inspect.remote ? "git · " + row.inspect.remote.replace(/^https?:\/\//, "").replace(/\.git$/, "") : "git checkout"
  return "local folder (not git-managed)"
}

function updateLabel(row) {
  if (!row.inspect || !row.inspect.git) return ""
  var info = row.inspect
  if (info.fetchError) return "fetch failed: " + info.fetchError
  if (!info.fetched) return "not checked yet"
  if (info.dirty) return "local changes in the checkout; update will refuse to fast-forward"
  if (info.behind > 0) return info.behind + " commit" + (info.behind === 1 ? "" : "s") + " behind"
  if (info.ahead > 0) return "up to date (" + info.ahead + " local commit" + (info.ahead === 1 ? "" : "s") + " ahead)"
  return "up to date"
}

function makeRow(id, manifest, config, placed, inspectMap, selfId) {
  var placement = placed[id] || null
  var kinds = manifest && Array.isArray(manifest.kinds) ? manifest.kinds.slice() : []
  var isBarOption = hasKind(manifest, "bar")
  var isBarWidget = hasKind(manifest, "bar-widget")
  var hasPanel = hasKind(manifest, "panel") || hasKind(manifest, "overlay") || hasKind(manifest, "menu")
  var isService = hasKind(manifest, "service")
  var firstParty = !!(manifest && manifest.__isFirstParty)
  var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  var metadata = manifest && isObject(manifest.omarchy) ? manifest.omarchy : null
  var clonedFrom = metadata ? canonical(metadata.clonedFrom) : ""
  var inspect = dir && inspectMap ? inspectMap[dir] || null : null

  // Same answer `omarchy plugin list` gives: a bar option is enabled while it
  // is the bar in use, a widget while it sits on the bar, anything else while
  // it is not switched off (first-party) or is listed in shell.json.
  var enabled
  if (isBarOption) enabled = activeBarId(config) === id
  else if (isBarWidget) enabled = !!placement
  else if (firstParty) enabled = !isDisabled(config, id)
  else enabled = inPluginsList(config, id)

  var row = {
    rowType: "plugin",
    id: id,
    name: shortName(manifest, id),
    version: manifest && manifest.version ? String(manifest.version) : "",
    description: manifest && manifest.description ? String(manifest.description) : "",
    kinds: kinds,
    kindsText: kinds.join(", "),
    firstParty: firstParty,
    clonedFrom: clonedFrom,
    dir: dir,
    inspect: inspect,
    custom: false,
    isSelf: id === selfId,
    isBarOption: isBarOption,
    isBarWidget: isBarWidget,
    hasPanel: hasPanel,
    isService: isService,
    active: isBarOption && activeBarId(config) === id,
    enabled: enabled,
    onBar: !!placement,
    section: placement ? placement.section : "",
    index: placement ? placement.index : -1,
    count: placement ? placement.count : 0,
    pinned: !!placement && centerAnchor(config) === id,
    updatable: !!(inspect && inspect.git && !inspect.symlink),
    updateAvailable: !!(inspect && inspect.git && inspect.behind > 0 && !inspect.dirty),
    removable: !firstParty && !!dir && id !== selfId,
    canOpen: isBarWidget || hasPanel
  }
  row.sourceText = sourceLabel(row)
  row.updateText = updateLabel(row)
  row.metaText = metaFor(row)
  return row
}

function customRow(entry, placed) {
  var id = entryId(entry)
  var placement = placed[id] || null
  var row = {
    rowType: "plugin",
    id: id,
    name: id,
    version: "",
    description: "Custom " + (entry && entry.type ? String(entry.type) : "command") + " module declared in shell.json.",
    kinds: ["custom"],
    kindsText: "custom module",
    firstParty: false,
    clonedFrom: "",
    dir: "",
    inspect: null,
    custom: true,
    isSelf: false,
    isBarOption: false,
    isBarWidget: true,
    hasPanel: false,
    isService: false,
    active: false,
    enabled: true,
    onBar: !!placement,
    section: placement ? placement.section : "",
    index: placement ? placement.index : -1,
    count: placement ? placement.count : 0,
    pinned: false,
    updatable: false,
    updateAvailable: false,
    removable: false,
    canOpen: false
  }
  row.sourceText = sourceLabel(row)
  row.updateText = ""
  row.metaText = metaFor(row)
  return row
}

function metaFor(row) {
  var bits = []
  if (row.isBarOption) bits.push(row.active ? "bar in use" : "not in use")
  else if (row.onBar) bits.push(sectionLabel(row.section) + " " + (row.index + 1) + " of " + row.count)
  else if (row.isBarWidget) bits.push("off the bar")
  else bits.push(row.enabled ? "on" : "off")
  if (row.pinned) bits.push("pinned")
  if (row.updateAvailable) bits.push("update")
  return bits.join(" · ")
}

function headerRow(title) {
  return { rowType: "header", id: "", name: title, metaText: "", kindsText: "" }
}

function matches(row, filter) {
  if (!filter) return true
  var needle = filter.toLowerCase()
  var hay = (row.name + " " + row.id + " " + row.kindsText + " " + row.metaText + " " + (row.description || "")).toLowerCase()
  return hay.indexOf(needle) !== -1
}

function byName(a, b) {
  var an = a.name.toLowerCase(), bn = b.name.toLowerCase()
  if (an < bn) return -1
  if (an > bn) return 1
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

// Flat list of header + plugin rows, grouped the way the user thinks about
// the bar: what is on it (in bar order), what could be, and everything that
// lives outside the bar.
function buildRows(plugins, config, inspectMap, filter, selfId) {
  plugins = plugins || {}
  var placed = placements(config)
  var layout = layoutOf(config)
  var seen = {}
  var groups = { onBar: [], offBar: [], panels: [], services: [], bars: [] }

  for (var s = 0; s < SECTIONS.length; s++) {
    var list = layout[SECTIONS[s]]
    for (var i = 0; i < list.length; i++) {
      var id = entryId(list[i])
      if (!id || seen[id]) continue
      seen[id] = true
      if (plugins[id]) groups.onBar.push(makeRow(id, plugins[id], config, placed, inspectMap, selfId))
      else groups.onBar.push(customRow(list[i], placed))
    }
  }

  var rest = []
  for (var pid in plugins) {
    if (seen[pid]) continue
    rest.push(makeRow(pid, plugins[pid], config, placed, inspectMap, selfId))
  }
  rest.sort(byName)
  for (var r = 0; r < rest.length; r++) {
    var row = rest[r]
    if (row.isBarOption) groups.bars.push(row)
    else if (row.isBarWidget) groups.offBar.push(row)
    else if (row.hasPanel) groups.panels.push(row)
    else groups.services.push(row)
  }

  var out = []
  function emit(title, rows) {
    var kept = []
    for (var k = 0; k < rows.length; k++) if (matches(rows[k], filter)) kept.push(rows[k])
    if (kept.length === 0) return
    out.push(headerRow(title + " · " + kept.length))
    for (var e = 0; e < kept.length; e++) out.push(kept[e])
  }
  emit("On the bar", groups.onBar)
  emit("Off the bar", groups.offBar)
  emit("Panels, overlays & menus", groups.panels)
  emit("Services", groups.services)
  emit("Bar options", groups.bars)
  return out
}

// One row per bar section, chips in bar order. Drawn as three labelled rows
// so "move it to the right section" is literally the row below.
function buildStrip(plugins, config) {
  var layout = layoutOf(config)
  var anchor = centerAnchor(config)
  var out = []
  for (var s = 0; s < SECTIONS.length; s++) {
    var list = layout[SECTIONS[s]]
    var chips = []
    for (var i = 0; i < list.length; i++) {
      var id = entryId(list[i])
      if (!id) continue
      var label = plugins && plugins[id] ? shortName(plugins[id], id) : id
      if (label.length > 16) label = label.slice(0, 15) + "…"
      chips.push({ id: id, label: label, pinned: id === anchor })
    }
    out.push({ section: SECTIONS[s], label: SECTIONS[s].charAt(0).toUpperCase() + SECTIONS[s].slice(1), chips: chips })
  }
  return out
}

function sectionLabel(section) {
  return section ? section.charAt(0).toUpperCase() + section.slice(1) : ""
}

function indexOfId(rows, id) {
  for (var i = 0; i < rows.length; i++) if (rows[i].rowType === "plugin" && rows[i].id === id) return i
  return -1
}

function firstPluginIndex(rows, from, step) {
  if (rows.length === 0) return -1
  var i = from
  for (var n = 0; n < rows.length; n++) {
    i = (i + rows.length) % rows.length
    if (rows[i].rowType === "plugin") return i
    i += step
  }
  return -1
}

function nextPluginIndex(rows, current, step) {
  if (rows.length === 0) return -1
  var i = current
  for (var n = 0; n < rows.length; n++) {
    i = (i + step + rows.length) % rows.length
    if (rows[i].rowType === "plugin") return i
  }
  return current
}

function parseInspect(text) {
  var map = {}
  try {
    var list = JSON.parse(text || "[]")
    if (!Array.isArray(list)) return map
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (item && item.dir) map[String(item.dir)] = item
    }
  } catch (e) {
    return map
  }
  return map
}

function updatableDirs(rows) {
  var dirs = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (row.rowType !== "plugin" || !row.updateAvailable || !row.dir) continue
    dirs.push(row.dir.split("/").pop())
  }
  return dirs
}

function countUpdates(rows) {
  var n = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].rowType === "plugin" && rows[i].updateAvailable) n++
  return n
}

// Action groups for the details pane. Each group is one row of buttons;
// `hint` is the keyboard shortcut shown dimly after the label, `selected`
// marks the current choice in the section picker.
function actionsFor(row) {
  if (!row) return []
  var groups = []
  var primary = []
  if (row.custom) {
    // Declared in shell.json; Barkeep can arrange it but not switch it.
  } else if (row.isBarOption) {
    primary.push({ icon: "", label: row.active ? "This is the bar in use" : "Use this bar", hint: "⏎", action: "toggle", enabled: !row.active, selected: false })
  } else if (row.isBarWidget) {
    primary.push({ icon: row.onBar ? "󰅖" : "󰐕", label: row.onBar ? "Take off the bar" : "Put on the bar", hint: "⏎", action: "toggle", enabled: !row.isSelf, selected: false })
  } else {
    primary.push({ icon: row.enabled ? "󰅖" : "󰐕", label: row.enabled ? "Disable" : "Enable", hint: "⏎", action: "toggle", enabled: !row.isSelf, selected: false })
  }
  if (row.canOpen) primary.push({ icon: "󰁜", label: "Open it", hint: "^O", action: "open", enabled: row.enabled || row.onBar, selected: false })
  if (row.updatable) primary.push({ icon: "󰚰", label: row.updateAvailable ? "Update now" : "Update", hint: "^U", action: "update", enabled: true, selected: false })
  if (row.removable) primary.push({ icon: "󰆴", label: "Remove", hint: "⌦", action: "remove", enabled: true, selected: false, danger: true })
  if (primary.length) groups.push({ title: "", items: primary })

  if (row.isBarWidget && row.onBar) {
    groups.push({ title: "Section", items: [
      { icon: "", label: "Left", hint: "", action: "sectionLeft", enabled: true, selected: row.section === "left" },
      { icon: "", label: "Center", hint: "", action: "sectionCenter", enabled: true, selected: row.section === "center" },
      { icon: "", label: "Right", hint: "", action: "sectionRight", enabled: true, selected: row.section === "right" }
    ]})
    groups.push({ title: "Position", items: [
      { icon: "", label: "Nudge left", hint: "←", action: "nudgeLeft", enabled: row.index > 0, selected: false },
      { icon: "", label: "Nudge right", hint: "→", action: "nudgeRight", enabled: row.index < row.count - 1, selected: false },
      { icon: "󰐃", label: row.pinned ? "Unpin from center" : "Pin to exact center", hint: "^P", action: "pin", enabled: !row.custom, selected: row.pinned }
    ]})
  }
  return groups
}
