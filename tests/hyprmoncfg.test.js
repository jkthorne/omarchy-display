const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Hypr = require("../Hyprmoncfg.js")

const qml = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")

test("installation uses Omarchy's presented AUR flow, restarts the daemon, and opens a centered TUI", () => {
  assert.deepEqual(Hypr.installProcessArgs(), [
    "omarchy",
    "launch",
    "floating",
    "terminal",
    "with",
    "presentation",
    "rm -f \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.failed\" \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.complete\"; status=0; omarchy pkg aur add hyprmoncfg && systemctl --user enable hyprmoncfgd.service && systemctl --user restart hyprmoncfgd.service && setsid -f gtk-launch hyprmoncfg-omarchy >/dev/null 2>&1 || status=$?; if (( status == 0 )); then : > \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.complete\"; else printf '%s\\n' \"$status\" > \"$XDG_RUNTIME_DIR/hyprmoncfg-panel-install.failed\"; fi; (exit \"$status\")"
  ])
})

test("installation completion and failure are observable and cannot leave the panel spinning forever", () => {
  assert.match(qml, /hyprmoncfg-panel-install\.failed/)
  assert.match(qml, /hyprmoncfg-panel-install\.complete/)
  assert.match(qml, /id: installPreparationProcess/)
  assert.match(qml, /root\.installing && exitCode === 2/)
  assert.match(qml, /exitCode === 3 && root\.installing/)
  assert.match(qml, /id: installTimeout/)
  assert.match(qml, /interval: 300000/)
  assert.doesNotMatch(Hypr.installCommand(), /&\s*$/)
})

test("IPC envelopes require protocol version one", () => {
  assert.deepEqual(Hypr.parseEnvelope('{"type":"event","protocol_version":1,"event":"status"}'), {
    type: "event",
    protocol_version: 1,
    event: "status"
  })
  assert.equal(Hypr.parseEnvelope('{"type":"event","protocol_version":2}'), null)
  assert.equal(Hypr.parseEnvelope("nope"), null)
})

test("version compatibility accepts the IPC release and development builds", () => {
  assert.equal(Hypr.versionAtLeast("hyprmoncfg 1.15.0 (abc)", "1.15.0"), true)
  assert.equal(Hypr.versionAtLeast("hyprmoncfg v1.16.0", "1.15.0"), true)
  assert.equal(Hypr.versionAtLeast("hyprmoncfg dev", "1.15.0"), true)
  assert.equal(Hypr.versionAtLeast("hyprmoncfg 1.14.0", "1.15.0"), false)
  assert.equal(Hypr.versionAtLeast("not installed", "1.15.0"), false)
})

test("layout display data comes from daemon status and matches TUI labels", () => {
  const displays = Hypr.layoutDisplays([{
    name: "eDP-1",
    description: "Samsung Display Corp. ATNA60CL10-0",
    make: "Samsung Display Corp.",
    model: "ATNA60CL10-0",
    mode: "2880x1800@120.00Hz",
    scale: 1.5,
    internal: true,
    focused: true,
    enabled: true,
    x: 3840,
    y: 0,
    logical_width: 1920,
    logical_height: 1200
  }], [{ name: "fallback" }])

  assert.equal(displays.length, 1)
  assert.equal(Hypr.displayModelLabel(displays[0]), "Internal · Samsung Display Corp. ATNA60CL10-0")
  assert.equal(Hypr.displayModelLabel(displays[0], true), "Internal · ATNA60CL10-0")
  assert.equal(Hypr.displayDetailLabel(displays[0]), "2880×1800 · 120 Hz · 1.5x")
})

test("layout preview preserves relative placement", () => {
  const bounds = Hypr.layoutBounds([
    { x: 0, y: 0, width: 200, height: 100 },
    { x: 200, y: 50, width: 100, height: 100 }
  ])
  const left = Hypr.layoutRect({ x: 0, y: 0, width: 200, height: 100 }, bounds, 330, 140, 10)
  const right = Hypr.layoutRect({ x: 200, y: 50, width: 100, height: 100 }, bounds, 330, 140, 10)

  assert.equal(left.x, 45)
  assert.equal(left.width, 160)
  assert.equal(right.x, 205)
  assert.equal(right.y, 50)
})

test("the layout draws only displays that own their image and names the rest", () => {
  const monitors = [
    { name: "DP-1", enabled: true, x: 0, y: 0, logical_width: 2880, logical_height: 1620 },
    { name: "HDMI-A-1", enabled: true, mirror_of: "DP-1", x: 0, y: 0, logical_width: 2560, logical_height: 1440 },
    { name: "eDP-1", enabled: false, x: 0, y: 1620, logical_width: 1920, logical_height: 1200 }
  ]

  const displays = Hypr.layoutDisplays(monitors, [{ name: "fallback" }])
  assert.deepEqual(displays.map(function(display) { return display.name }), ["DP-1"])
  assert.equal(Hypr.hiddenDisplays(monitors), "Off: eDP-1   Mirrored: HDMI-A-1 → DP-1")
  assert.equal(Hypr.hiddenDisplays([monitors[0]]), "")

  assert.match(qml, /id: hiddenDisplaysLabel/)
  assert.match(qml, /visible: root\.hiddenDisplays !== ""/)
})

test("the panel hands monitor management over, not the user service", () => {
  assert.match(qml, /text: "MONITOR MANAGEMENT"/)
  assert.match(qml, /label: "Managed by hyprmoncfg"/)
  assert.match(qml, /Automatic switching on monitor hotplug and lid events/)
  assert.match(qml, /systemctl --user enable --now hyprmoncfgd\.service && hyprmoncfg manage/)
  assert.match(qml, /\["hyprmoncfg", "unmanage"\]/)
  assert.match(qml, /\["systemctl", "--user", "is-enabled", "--quiet", "hyprmoncfgd\.service"\]/)
  assert.match(qml, /\["systemctl", "--user", "is-active", "--quiet", "hyprmoncfgd\.service"\]/)
  assert.doesNotMatch(qml, /"disable", "--now"/)
  assert.doesNotMatch(qml, /set_automation/)
  assert.match(qml, /root\.serviceTargetManaged === !unmanaged/)
  assert.match(qml, /daemon\.unmanaged/)
})

test("the panel waits for daemon status before calling a layout custom", () => {
  assert.match(qml, /property bool documentReady: false/)
  assert.match(qml, /if \(!root\.documentReady\) return root\.serviceActionPending \? "Starting hyprmoncfg…" : "Loading profile…"/)
  assert.match(qml, /root\.documentReady = true/)
})

test("an enabled service without IPC is a recoverable failure", () => {
  assert.match(qml, /readonly property bool serviceBroken:/)
  assert.match(qml, /title: "Restart hyprmoncfg"/)
  assert.match(qml, /\["systemctl", "--user", "restart", "hyprmoncfgd\.service"\]/)
})

test("an upgraded package whose daemon is still the old binary offers a restart", () => {
  assert.equal(Hypr.daemonNeedsRestart("hyprmoncfg 1.14.0 (abc, 2026-08-18)", "1.13.0"), true)
  assert.equal(Hypr.daemonNeedsRestart("hyprmoncfg 1.14.0 (abc, 2026-08-18)", "1.14.0"), false)
  assert.equal(Hypr.daemonNeedsRestart("", "1.13.0"), false)
  assert.equal(Hypr.daemonNeedsRestart("hyprmoncfg 1.14.0", ""), false)
  assert.equal(Hypr.daemonNeedsRestart("hyprmoncfg dev", "1.13.0"), false)

  assert.match(qml, /readonly property bool daemonOutdated:/)
  assert.match(qml, /title: "Restart daemon"/)
  const subtitles = qml.match(/subtitle: "[^"]+"/g) || []
  for (const subtitle of subtitles) {
    const text = subtitle.slice('subtitle: "'.length, -1)
    assert.ok(text.length <= 40, `subtitle too long to fit the row: ${text}`)
  }
})

test("daily display controls stay on the panel even without hyprmoncfg", () => {
  assert.match(qml, /text: "TEXT SIZE"/)
  assert.match(qml, /text: "SCALE"/)
  assert.match(qml, /ipcTarget: "omarchy.monitor"/)
  assert.match(qml, /jack\.display\/set-scale\.sh/)
  assert.match(qml, /displays\.length > 1 && !root\.managedChecked/)
})

test("the panel notices its own updates, since Omarchy never pulls plugins on its own", () => {
  const check = Hypr.pluginUpdateCheckCommand("jack.display", 6)
  assert.equal(check[0], "sh")
  assert.deepEqual(check.slice(4), ["jack.display", "6"])
  assert.doesNotMatch(check[2], /jack\.display/)
  assert.match(check[2], /git -C "\$dir" fetch --quiet origin HEAD/)
  assert.match(check[2], /rev-parse HEAD/)
  assert.match(check[2], /rev-parse FETCH_HEAD/)
  assert.match(check[2], /newermt/)
  assert.match(check[2], /exit 10/)

  assert.deepEqual(Hypr.pluginUpdateCommand("jack.display"), [
    "omarchy", "plugin", "update", "jack.display", "--yes"
  ])

  assert.match(qml, /root\.pluginUpdateAvailable = exitCode === 10/)
  assert.match(qml, /Update this panel/)
  assert.match(qml, /pluginId: "jack\.display"/)
  assert.doesNotMatch(qml, /pluginUpdateCheckCommand\(root\.moduleName/)
})

test("updating the panel finishes the job by reloading the shell", () => {
  assert.deepEqual(Hypr.shellRestartCommand(), [
    "sh", "-c", "setsid -f omarchy-restart-shell >/dev/null 2>&1"
  ])
  assert.match(Hypr.shellRestartCommand()[2], /setsid/)
  assert.equal(Hypr.pluginUpdated("Updated jack.display."), true)
  assert.equal(Hypr.pluginUpdated("jack.display is up to date."), false)
  assert.equal(Hypr.pluginUpdated(""), false)

  assert.match(qml, /if \(Hypr\.pluginUpdated\(pluginUpdateOutput\.text\)\)/)
  assert.match(qml, /shellRestartProcess\.startDetached\(\)/)
})

test("updating touches only this plugin, and asks nothing", () => {
  const command = Hypr.pluginUpdateCommand("jack.display")
  assert.ok(command.includes("jack.display"), "the plugin id must be passed")
  assert.ok(command.includes("--yes"), "the update must not wait on a prompt")
})

test("the layout editor delegates window behavior to the packaged desktop launcher", () => {
  assert.match(qml, /\["gtk-launch", "hyprmoncfg-omarchy"\]/)
  assert.doesNotMatch(qml, /TUI\.float/)
  assert.doesNotMatch(qml, /--app-id=hyprmoncfg/)
})

test("the managed panel still leads with a live layout", () => {
  assert.match(qml, /Style\.space\(560\)/)
  assert.match(qml, /ScrollView \{/)
  assert.ok(qml.indexOf('text: "LAYOUT AND SETTINGS"') < qml.indexOf('text: "PROFILE"'))
  assert.match(qml, /id: layoutCanvas/)
  assert.match(qml, /Hypr\.displayModelLabel\(modelData, parent\.parent\.compactCard\)/)
  assert.match(qml, /Hypr\.displayDetailLabel\(modelData\)/)
  assert.match(qml, /onClicked: root\.launchTui\(\)/)
  assert.match(qml, /centerOnBar: false/)
})

test("the profile explains the unmanaged state", () => {
  assert.match(qml, /if \(!root\.managedChecked\) return "Not managed by hyprmoncfg"/)
  assert.match(qml, /if \(!root\.managedChecked\) return "Turn on management for automatic profiles"/)
  assert.match(qml, /Item \{\s+id: profileInfo/)
})

test("keyboard navigation walks hyprmoncfg rows as sections", () => {
  assert.match(qml, /list\.push\("hypr-install"\)/)
  assert.match(qml, /list\.push\("hypr-managed"\)/)
  assert.match(qml, /list\.push\("hypr-actions"\)/)
  assert.match(qml, /list\.push\("hypr-layout"\)/)
  assert.match(qml, /focusSection === "hypr-actions"/)
  assert.match(qml, /readonly property var actionRows:/)
})

test("the bar icon keeps a connected check and dims only when unmanaged", () => {
  assert.match(qml, /dimmed: root\.barIconDimmed/)
  assert.match(qml, /visible: root\.backendConnected/)
  assert.match(qml, /text: "󰄬"/)
  assert.doesNotMatch(qml, /dimmed: !root\.backendConnected/)
})
