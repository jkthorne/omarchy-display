function installCommand() {
  return "rm -f \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.failed\" \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.complete\"; status=0; omarchy pkg aur add hyprmoncfg && systemctl --user enable hyprmoncfgd.service && systemctl --user restart hyprmoncfgd.service && setsid -f gtk-launch hyprmoncfg-omarchy >/dev/null 2>&1 || status=$?; if (( status == 0 )); then : > \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.complete\"; else printf '%s\\n' \"$status\" > \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.failed\"; fi; (exit \"$status\")"
}

function installProcessArgs() {
  return [
    "omarchy",
    "launch",
    "floating",
    "terminal",
    "with",
    "presentation",
    installCommand()
  ]
}

function parseEnvelope(raw) {
  try {
    var value = JSON.parse(String(raw || ""))
    if (!value || typeof value !== "object") return null
    if (value.protocol_version !== 1) return null
    if (value.type !== "response" && value.type !== "event") return null
    return value
  } catch (e) {
    return null
  }
}

function mirrorTarget(monitor) {
  return String((monitor || {}).mirror_of || "").trim()
}

// A monitor only earns a rectangle when it drives its own image. One that is
// off has no place on the canvas, and one that mirrors another shares its
// source's position, so drawing it would stack two cards on the same spot.
function drawsOwnImage(monitor) {
  return !!monitor
    && monitor.enabled !== false
    && mirrorTarget(monitor) === ""
    && Number(monitor.logical_width || 0) > 0
    && Number(monitor.logical_height || 0) > 0
}

// hiddenDisplays names what the canvas leaves out, so a display never vanishes
// without a trace. Mirrors: the TUI canvas strip.
function hiddenDisplays(monitors) {
  var summaries = monitors instanceof Array ? monitors : []
  var off = []
  var mirrored = []

  for (var i = 0; i < summaries.length; i++) {
    var monitor = summaries[i] || {}
    var name = String(monitor.name || "Display")
    if (monitor.enabled === false) {
      off.push(name)
    } else if (mirrorTarget(monitor) !== "") {
      mirrored.push(name + " → " + mirrorTarget(monitor))
    }
  }

  var parts = []
  if (off.length > 0) parts.push("Off: " + off.join(", "))
  if (mirrored.length > 0) parts.push("Mirrored: " + mirrored.join(", "))
  return parts.join("   ")
}

function layoutDisplays(monitors, screens) {
  var summaries = monitors instanceof Array ? monitors : []
  var enriched = summaries.filter(drawsOwnImage).map(function(monitor) {
    return {
      name: String(monitor.name || "Display"),
      description: String(monitor.description || ""),
      make: String(monitor.make || ""),
      model: String(monitor.model || ""),
      mode: String(monitor.mode || ""),
      scale: Number(monitor.scale || 1),
      internal: monitor.internal === true,
      focused: monitor.focused === true,
      x: Number(monitor.x || 0),
      y: Number(monitor.y || 0),
      width: Number(monitor.logical_width),
      height: Number(monitor.logical_height)
    }
  })
  return enriched.length > 0 ? enriched : (screens || [])
}

function displayModelLabel(display, compact) {
  var monitor = display || {}
  var makeModel = compact === true
    ? String(monitor.model || "").trim()
    : (String(monitor.make || "") + " " + String(monitor.model || "")).trim()
  var label = makeModel || String(monitor.description || "").trim() || "Unknown display"
  return monitor.internal === true ? "Internal · " + label : label
}

function displayDetailLabel(display) {
  var monitor = display || {}
  var mode = String(monitor.mode || "").trim()
  var match = mode.match(/^(\d+)x(\d+)(?:@([\d.]+)Hz)?$/)
  var parts = []
  if (match) {
    parts.push(match[1] + "×" + match[2])
    if (match[3]) parts.push(Math.round(Number(match[3])) + " Hz")
  } else if (mode !== "") {
    parts.push(mode)
  }
  var scale = Number(monitor.scale || 1)
  if (!isFinite(scale) || scale <= 0) scale = 1
  parts.push(String(Math.round(scale * 100) / 100) + "x")
  return parts.join(" · ")
}

function layoutBounds(displays) {
  var list = displays || []
  if (list.length === 0) return { x: 0, y: 0, width: 1, height: 1 }

  var minX = Infinity
  var minY = Infinity
  var maxX = -Infinity
  var maxY = -Infinity
  for (var i = 0; i < list.length; i++) {
    var display = list[i] || {}
    var x = Number(display.x || 0)
    var y = Number(display.y || 0)
    var width = Math.max(1, Number(display.width || 1))
    var height = Math.max(1, Number(display.height || 1))
    minX = Math.min(minX, x)
    minY = Math.min(minY, y)
    maxX = Math.max(maxX, x + width)
    maxY = Math.max(maxY, y + height)
  }

  return {
    x: minX,
    y: minY,
    width: Math.max(1, maxX - minX),
    height: Math.max(1, maxY - minY)
  }
}

function layoutRect(display, bounds, canvasWidth, canvasHeight, padding) {
  var item = display || {}
  var area = bounds || layoutBounds([])
  var inset = Math.max(0, Number(padding || 0))
  var usableWidth = Math.max(1, Number(canvasWidth || 1) - inset * 2)
  var usableHeight = Math.max(1, Number(canvasHeight || 1) - inset * 2)
  var scale = Math.min(usableWidth / area.width, usableHeight / area.height)
  var contentWidth = area.width * scale
  var contentHeight = area.height * scale
  var offsetX = inset + (usableWidth - contentWidth) / 2
  var offsetY = inset + (usableHeight - contentHeight) / 2

  return {
    x: offsetX + (Number(item.x || 0) - area.x) * scale,
    y: offsetY + (Number(item.y || 0) - area.y) * scale,
    width: Math.max(1, Number(item.width || 1) * scale),
    height: Math.max(1, Number(item.height || 1) * scale)
  }
}

// Omarchy installs plugins as git checkouts under ~/.config/omarchy/plugins and
// never updates them on its own, so the panel has to notice for itself. The
// check mirrors `omarchy plugin update`: fetch, then compare HEAD to FETCH_HEAD.
// Fetching is throttled, because opening a panel is not a reason to talk to a
// remote every time. Exit 10 means an update is waiting; anything else means
// there is nothing to say.
function pluginUpdateCheckCommand(pluginId, throttleHours) {
  var hours = Number(throttleHours || 6)
  return [
    "sh",
    "-c",
    'set -e; ' +
      'dir="$HOME/.config/omarchy/plugins/$1"; ' +
      'stamp="${XDG_RUNTIME_DIR:-/tmp}/$1.update-check"; ' +
      '[ -d "$dir/.git" ] || exit 3; ' +
      'if [ -z "$(find "$stamp" -newermt "-$2 hours" 2>/dev/null)" ]; then ' +
      'git -C "$dir" fetch --quiet origin HEAD 2>/dev/null || exit 4; ' +
      ': > "$stamp"; fi; ' +
      'head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || exit 5; ' +
      'remote=$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null) || exit 5; ' +
      '[ "$head" = "$remote" ] || exit 10',
    "sh",
    String(pluginId || ""),
    String(hours)
  ]
}

// Omarchy's rescanPlugins discovers plugins but does not re-execute the QML of
// one already loaded, so a plugin that updates itself keeps showing its old
// code until the shell restarts. setsid takes the restart out of the shell's
// own process group, so killing the shell cannot kill the command relaunching it.
function shellRestartCommand() {
  return ["sh", "-c", "setsid -f omarchy-restart-shell >/dev/null 2>&1"]
}

// pluginUpdated reports whether `omarchy plugin update` actually pulled
// something, so an already-current plugin does not restart the shell for nothing.
function pluginUpdated(output) {
  return /^Updated /m.test(String(output || ""))
}

function pluginUpdateCommand(pluginId) {
  return ["omarchy", "plugin", "update", String(pluginId || ""), "--yes"]
}

// releaseVersion pulls the plain version out of `hyprmoncfg version` output,
// which also carries a commit and a build date.
function releaseVersion(output) {
  var match = String(output || "").match(/(\d+\.\d+\.\d+)/)
  return match ? match[1] : ""
}

// daemonNeedsRestart reports an upgraded package whose daemon is still the
// previous binary. Installing runs as root and cannot restart a user service,
// so the old daemon keeps serving profiles until someone restarts it.
function daemonNeedsRestart(installedOutput, daemonVersion) {
  var installed = releaseVersion(installedOutput)
  var running = releaseVersion(daemonVersion)
  return installed !== "" && running !== "" && installed !== running
}

function versionAtLeast(output, minimum) {
  var text = String(output || "")
  if (/\bdev\b/.test(text)) return true

  function parts(value) {
    var match = String(value || "").match(/v?(\d+)\.(\d+)\.(\d+)/)
    return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null
  }

  var current = parts(text)
  var wanted = parts(minimum)
  if (!current || !wanted) return false
  for (var i = 0; i < 3; i++) {
    if (current[i] > wanted[i]) return true
    if (current[i] < wanted[i]) return false
  }
  return true
}

if (typeof module !== "undefined") {
  module.exports = {
    installCommand: installCommand,
    installProcessArgs: installProcessArgs,
    parseEnvelope: parseEnvelope,
    hiddenDisplays: hiddenDisplays,
    layoutDisplays: layoutDisplays,
    displayModelLabel: displayModelLabel,
    displayDetailLabel: displayDetailLabel,
    layoutBounds: layoutBounds,
    layoutRect: layoutRect,
    pluginUpdateCheckCommand: pluginUpdateCheckCommand,
    pluginUpdateCommand: pluginUpdateCommand,
    shellRestartCommand: shellRestartCommand,
    pluginUpdated: pluginUpdated,
    releaseVersion: releaseVersion,
    daemonNeedsRestart: daemonNeedsRestart,
    versionAtLeast: versionAtLeast
  }
}
