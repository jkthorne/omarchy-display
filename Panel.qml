import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "Hyprmoncfg.js" as Hypr

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below. ipcTarget stays
  // omarchy.monitor so SUPER+CTRL+D and clone routing keep working.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  property real wheelAccumulator: 0

  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  property int textSizePreviewIndex: -1
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- hyprmoncfg backend ----
  property bool installed: false
  property string installedVersion: ""
  property bool compatible: false
  property bool checkingInstallation: true
  property bool installationStateKnown: false
  property bool installing: false
  property bool serviceEnabled: false
  property bool serviceActive: false
  property bool serviceStateKnown: false
  property bool serviceActionPending: false
  property bool serviceTargetManaged: false
  property string serviceAction: ""
  property bool connectionGrace: false
  property bool backendConnected: backendSocket.connected
  property var document: ({ profiles: [], monitors: [], daemon: { running: false } })
  property bool documentReady: false
  property string lastError: ""
  property int requestSequence: 0
  property var pendingMethods: ({})

  readonly property var monitorSummaries: document && document.monitors instanceof Array ? document.monitors : []
  readonly property var layoutDisplays: Hypr.layoutDisplays(
    root.backendConnected ? monitorSummaries : [],
    Quickshell.screens || []
  )
  readonly property var layoutBounds: Hypr.layoutBounds(layoutDisplays)
  readonly property string hiddenDisplays: Hypr.hiddenDisplays(
    root.backendConnected ? monitorSummaries : []
  )
  readonly property int monitorCount: layoutDisplays.length
  readonly property string activeProfile: root.managedChecked && document && document.active_profile
    ? String(document.active_profile.name || "")
    : ""
  readonly property string recommendedProfile: root.managedChecked && document && document.recommended_profile
    ? String(document.recommended_profile.name || "")
    : ""
  readonly property string displayedProfile: activeProfile !== "" ? activeProfile : recommendedProfile
  readonly property string profileStatusTitle: {
    if (!root.managedChecked) return "Not managed by hyprmoncfg"
    if (!root.documentReady) return root.serviceActionPending ? "Starting hyprmoncfg…" : "Loading profile…"
    if (displayedProfile !== "") return displayedProfile
    return "Custom layout"
  }
  readonly property string profileStatusSubtitle: {
    if (!root.managedChecked) return "Turn on management for automatic profiles"
    if (!root.documentReady) return "Reading the active display layout"
    var displaysLabel = monitorCount === 1 ? "1 display" : monitorCount + " displays"
    if (activeProfile !== "") return displaysLabel + " · Active"
    if (recommendedProfile !== "") return displaysLabel + " · Best match, not active"
    return displaysLabel + " · No matching profile"
  }
  readonly property bool daemonUnmanaged: !!(root.document && root.document.daemon && root.document.daemon.unmanaged)
  readonly property bool managedChecked: serviceActionPending
    ? serviceTargetManaged
    : (root.documentReady && root.backendConnected
      ? !root.daemonUnmanaged
      : (serviceEnabled || serviceActive || backendConnected))
  readonly property string runningVersion: Hypr.releaseVersion(root.document ? root.document.version : "")
  readonly property string installedRelease: Hypr.releaseVersion(root.installedVersion)
  readonly property bool daemonOutdated: root.backendConnected
    && root.documentReady
    && Hypr.daemonNeedsRestart(root.installedVersion, root.document ? root.document.version : "")
  readonly property var actionRows: {
    var rows = []
    if (root.serviceBroken)
      rows.push({
        id: "restart-service",
        icon: "󰑓",
        title: "Restart hyprmoncfg",
        subtitle: "Try the background service again"
      })
    else if (root.daemonOutdated)
      rows.push({
        id: "restart-service",
        icon: "󰑓",
        title: "Restart daemon",
        subtitle: "Running " + root.runningVersion + ", installed " + root.installedRelease
      })
    return rows
  }
  readonly property bool serviceBroken: serviceStateKnown
    && serviceEnabled
    && !backendConnected
    && !connectionGrace
    && !serviceActionPending
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string socketPath: root.runtimeDir + "/hyprmoncfgd.sock"
  readonly property string installFailurePath: root.runtimeDir + "/hyprmoncfg-panel-install.failed"
  readonly property string installCompletePath: root.runtimeDir + "/hyprmoncfg-panel-install.complete"
  readonly property bool barIconDimmed: root.installationStateKnown
    && root.compatible
    && root.serviceStateKnown
    && !root.managedChecked
    && !root.serviceActionPending

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1 && !root.managedChecked) list.push("monitors")
    if (!root.compatible && !root.checkingInstallation) list.push("hypr-install")
    if (root.compatible) list.push("hypr-managed")
    if (root.compatible && root.actionRows.length > 0) list.push("hypr-actions")
    if (root.compatible) list.push("hypr-layout")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0
    if (section === "textsize") return 0
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    if (section === "hypr-install") return 0
    if (section === "hypr-managed") return 0
    if (section === "hypr-actions") return root.actionRows.length
    if (section === "hypr-layout") return 0
    return 0
  }

  function sectionIsSingleRow(section) {
    return section === "brightness" || section === "textsize" || section === "scale"
      || section === "hypr-install" || section === "hypr-managed" || section === "hypr-layout"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize" || section === "hypr-install"
        || section === "hypr-managed" || section === "hypr-layout")
      return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
      return
    }
    if (focusSection === "hypr-install") {
      root.install()
      return
    }
    if (focusSection === "hypr-managed") {
      root.setManaged(!root.managedChecked)
      return
    }
    if (focusSection === "hypr-actions" && selectedIndex >= 0 && selectedIndex < root.actionRows.length) {
      root.activateRow(String(root.actionRows[selectedIndex].id))
      return
    }
    if (focusSection === "hypr-layout") root.launchTui()
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      if (focusSection === "scale") {
        if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      } else {
        selectedIndex = -1
      }
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays,
      profile: root.displayedProfile,
      managed: root.managedChecked
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (root.managedChecked) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = [Quickshell.env("HOME") + "/.config/omarchy/plugins/jack.display/set-scale.sh", String(scale)]
    if (!actionProc.running) actionProc.running = true
  }

  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  function checkInstallation() {
    if (whichProcess.running) return
    if (!root.installationStateKnown) root.checkingInstallation = true
    whichProcess.command = [
      "sh",
      "-c",
      "if test \"$3\" = \"1\"; then if test -f \"$1\"; then cat \"$1\"; exit 2; elif ! test -f \"$2\"; then exit 3; fi; fi; if command -v hyprmoncfg >/dev/null 2>&1; then hyprmoncfg version; else exit 1; fi",
      "sh",
      root.installFailurePath,
      root.installCompletePath,
      root.installing ? "1" : "0"
    ]
    whichProcess.running = true
  }

  function checkServiceState() {
    if (!root.compatible || serviceProcess.running || enabledProcess.running || activeProcess.running) return
    enabledProcess.command = ["systemctl", "--user", "is-enabled", "--quiet", "hyprmoncfgd.service"]
    enabledProcess.running = true
  }

  function install() {
    if (root.runtimeDir === "") {
      root.lastError = "Could not find the user runtime directory."
      return
    }
    root.installing = true
    root.lastError = ""
    installPreparationProcess.command = ["rm", "-f", root.installFailurePath, root.installCompletePath]
    installPreparationProcess.running = true
  }

  function setManaged(enabled) {
    if (!root.compatible || serviceProcess.running || root.serviceActionPending) return
    root.lastError = ""
    root.serviceActionPending = true
    root.serviceTargetManaged = enabled === true
    root.serviceAction = enabled === true ? "enable" : "disable"
    serviceProcess.command = enabled === true
      ? ["sh", "-c", "systemctl --user enable --now hyprmoncfgd.service && hyprmoncfg manage"]
      : ["hyprmoncfg", "unmanage"]
    serviceProcess.running = true
  }

  function restartService() {
    if (!root.compatible || serviceProcess.running || root.serviceActionPending) return
    root.lastError = ""
    root.serviceActionPending = true
    root.serviceTargetManaged = true
    root.serviceAction = "restart"
    serviceProcess.command = ["systemctl", "--user", "restart", "hyprmoncfgd.service"]
    serviceProcess.running = true
  }

  function launchTui() {
    tuiProcess.command = ["gtk-launch", "hyprmoncfg-omarchy"]
    tuiProcess.startDetached()
    root.close()
  }

  function connectBackend() {
    if (!root.compatible || backendSocket.connected || root.socketPath === "/hyprmoncfgd.sock") return
    if (!root.serviceEnabled && !root.serviceActive && !(root.serviceActionPending && root.serviceTargetManaged)) return
    backendSocket.connected = true
  }

  function send(method, params) {
    if (!backendSocket.connected) return ""
    root.requestSequence++
    var id = String(root.requestSequence)
    var request = {
      type: "request",
      protocol_version: 1,
      id: id,
      method: method
    }
    if (params !== undefined && params !== null) request.params = params
    root.pendingMethods[id] = method
    backendSocket.write(JSON.stringify(request) + "\n")
    backendSocket.flush()
    return id
  }

  function subscribe() { root.send("subscribe", {}) }

  function updateDocument(value) {
    if (!value || typeof value !== "object") return
    root.document = value
    root.documentReady = true
    if (root.serviceActionPending) {
      var unmanaged = !!(value.daemon && value.daemon.unmanaged)
      if (root.serviceTargetManaged === !unmanaged) {
        root.serviceActionPending = false
        root.serviceAction = ""
        serviceConfirmationTimer.stop()
      }
    }
  }

  function handleMessage(line) {
    var envelope = Hypr.parseEnvelope(line)
    if (!envelope) {
      root.lastError = "hyprmoncfg returned an invalid IPC message."
      return
    }
    if (envelope.type === "event") {
      if (envelope.event === "status") root.updateDocument(envelope.data)
      return
    }

    var method = root.pendingMethods[String(envelope.id)] || ""
    delete root.pendingMethods[String(envelope.id)]
    if (envelope.error) {
      root.lastError = String(envelope.error.message || "hyprmoncfg request failed")
      return
    }
    if (method === "status" || method === "subscribe") root.updateDocument(envelope.result)
  }

  function activateRow(id) {
    if (id === "restart-service") root.restartService()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    root.refresh()
    root.checkInstallation()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      root.checkInstallation()
      if (root.compatible) root.checkServiceState()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  Socket {
    id: backendSocket
    path: root.socketPath
    connected: false
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleMessage(line) }
    }
    onConnectedChanged: {
      if (connected) {
        root.connectionGrace = false
        root.lastError = ""
        root.installing = false
        root.subscribe()
      } else {
        root.pendingMethods = ({})
        if (root.compatible && (root.serviceEnabled || root.serviceActive))
          serviceRefreshTimer.restart()
      }
    }
    onError: function(error) { backendSocket.connected = false }
  }

  Process {
    id: whichProcess
    stdout: StdioCollector { id: versionOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 3 && root.installing) return

      root.checkingInstallation = false
      root.installationStateKnown = true
      var probedInstalled = exitCode === 0
      var probedCompatible = probedInstalled && Hypr.versionAtLeast(versionOutput.text, "1.15.0")

      if (root.installing && exitCode === 2) {
        root.installing = false
        installPoll.stop()
        installTimeout.stop()
        root.lastError = String(versionOutput.text || "").trim() === "130"
          ? "Installation was canceled."
          : "Installation did not finish. Check the Omarchy terminal and try again."
        return
      }

      if (root.installing && !probedCompatible) {
        root.installing = false
        installPoll.stop()
        installTimeout.stop()
        root.lastError = "The update finished, but hyprmoncfg 1.15.0 or newer is still required."
        return
      }

      root.installed = probedInstalled
      root.installedVersion = probedInstalled ? String(versionOutput.text || "") : ""
      root.compatible = probedCompatible
      if (root.compatible) {
        root.installing = false
        installPoll.stop()
        installTimeout.stop()
        root.checkServiceState()
      } else {
        backendSocket.connected = false
        root.serviceStateKnown = false
      }
    }
  }

  Process {
    id: enabledProcess
    onExited: function(exitCode) {
      root.serviceEnabled = exitCode === 0
      activeProcess.command = ["systemctl", "--user", "is-active", "--quiet", "hyprmoncfgd.service"]
      activeProcess.running = true
    }
  }

  Process {
    id: activeProcess
    onExited: function(exitCode) {
      var wasActive = root.serviceActive
      root.serviceActive = exitCode === 0
      root.serviceStateKnown = true
      if (root.serviceActive) {
        if (!root.backendConnected) {
          if (!wasActive) {
            root.connectionGrace = true
            connectionGraceTimer.restart()
          }
          root.connectBackend()
        }
      } else {
        root.connectionGrace = false
        backendSocket.connected = false
      }
      if (root.serviceActionPending && !serviceProcess.running) {
        var confirmed = root.serviceTargetManaged
          && root.serviceEnabled
          && root.serviceActive
        if (confirmed) {
          root.serviceActionPending = false
          root.serviceAction = ""
          serviceConfirmationTimer.stop()
        } else {
          serviceRefreshTimer.restart()
        }
      }
    }
  }

  Process {
    id: installPreparationProcess
    onExited: function(exitCode) {
      if (!root.installing) return
      if (exitCode !== 0) {
        root.installing = false
        root.lastError = "Could not prepare the hyprmoncfg update."
        return
      }
      installerProcess.command = Hypr.installProcessArgs()
      installerProcess.startDetached()
      installPoll.restart()
      installTimeout.restart()
    }
  }

  Process { id: installerProcess }

  Process {
    id: serviceProcess
    stderr: StdioCollector { id: serviceStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var action = root.serviceAction
      if (exitCode !== 0) {
        root.serviceActionPending = false
        root.serviceAction = ""
        var fallback = action === "disable" ? "Could not return display management to Omarchy." : "Could not start hyprmoncfg."
        root.lastError = String(serviceStderr.text || fallback).trim()
      } else if (action === "disable") {
        root.checkServiceState()
      } else {
        root.connectionGrace = true
        connectionGraceTimer.restart()
        reconnectTimer.restart()
      }
      if (exitCode === 0) serviceConfirmationTimer.restart()
      serviceRefreshTimer.restart()
    }
  }

  Process { id: tuiProcess }

  Timer {
    id: installPoll
    interval: 1000
    repeat: true
    running: root.installing && !root.compatible
    onTriggered: root.checkInstallation()
  }

  Timer {
    id: installTimeout
    interval: 300000
    onTriggered: {
      if (!root.installing) return
      root.installing = false
      installPoll.stop()
      root.lastError = "Installation is still waiting. Check the Omarchy terminal and try again."
    }
  }

  Timer {
    id: serviceRefreshTimer
    interval: 250
    onTriggered: root.checkServiceState()
  }

  Timer {
    id: serviceDiscoveryTimer
    interval: 2000
    repeat: true
    running: root.compatible && !root.backendConnected && !root.serviceActionPending
    onTriggered: root.checkServiceState()
  }

  Timer {
    id: connectionGraceTimer
    interval: 2000
    onTriggered: root.connectionGrace = false
  }

  Timer {
    id: serviceConfirmationTimer
    interval: 5000
    onTriggered: {
      if (!root.serviceActionPending) return
      root.serviceActionPending = false
      root.serviceAction = ""
      root.lastError = "Could not confirm the automatic switching state."
      root.checkServiceState()
    }
  }

  Timer {
    id: reconnectTimer
    interval: 1000
    repeat: true
    running: root.compatible
      && (root.serviceActive || (root.serviceActionPending && root.serviceTargetManaged))
      && !root.backendConnected
    onTriggered: {
      root.checkServiceState()
      root.connectBackend()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    dimmed: root.barIconDimmed
    tooltipText: root.displayedProfile !== "" ? "Display · " + root.displayedProfile : "Display"
    iconComponent: Component {
      Item {
        OpticalGlyph {
          id: barDisplayGlyph
          anchors.fill: parent
          text: button.text
          color: button.foreground
          fontFamily: button.fontFamily
          fontSize: button.fontSize
        }

        Text {
          visible: root.backendConnected
          anchors.right: barDisplayGlyph.right
          anchors.bottom: barDisplayGlyph.bottom
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          text: "󰄬"
          color: Color.accent
          font.family: button.fontFamily
          font.pixelSize: Math.max(7, Math.round(button.fontSize * 0.45))
          font.bold: true
        }
      }
    }
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Item {
              id: heroIcon
              implicitWidth: heroDisplayGlyph.implicitWidth
              implicitHeight: heroDisplayGlyph.implicitHeight
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: heroDisplayGlyph
                text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                visible: root.backendConnected
                anchors.right: heroDisplayGlyph.right
                anchors.bottom: heroDisplayGlyph.bottom
                anchors.rightMargin: -Style.space(2)
                anchors.bottomMargin: -Style.space(1)
                text: "󰄬"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                visible: root.managedChecked && root.displayedProfile !== ""
                text: root.displayedProfile
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: scaleMonitor
                text: root.focusedMonitor
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          PanelSeparator {
            visible: root.displays.length > 1 && !root.managedChecked
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1 && !root.managedChecked

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: !root.compatible && !root.checkingInstallation
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "MULTI-MONITOR"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: root.installed
                ? "Bring hyprmoncfg up to date."
                : "Build layouts visually."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: root.installed
                ? "Update once for live layouts and automatic switching."
                : "hyprmoncfg switches them on hotplug and lid events."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: root.installing
                ? (root.installed ? "Updating hyprmoncfg…" : "Installing hyprmoncfg…")
                : (root.installed ? "Update hyprmoncfg" : "Install hyprmoncfg")
              iconText: root.installed ? "\uf021" : (root.installing ? "󰦖" : "󰏔")
              iconSpinning: root.installing
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              iconSize: Style.font.icon
              foreground: root.foreground
              accent: Color.accent
              verticalPadding: Style.space(14)
              bordered: true
              selected: !root.installed
              hasCursor: root.cursorActive && root.focusSection === "hypr-install" && root.selectedIndex === -1
              enabled: !root.installing
              onHovered: function(hovered) {
                if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "hypr-install"
                  root.selectedIndex = -1
                }
              }
              onClicked: root.install()
            }
          }

          Column {
            visible: root.compatible
            width: parent.width
            spacing: Style.space(14)

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "MONITOR MANAGEMENT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Toggle {
                width: parent.width
                label: "Managed by hyprmoncfg"
                description: {
                  if (root.serviceActionPending)
                    return root.serviceTargetManaged ? "Starting on monitor hotplug and lid events…" : "Turning off automatic switching…"
                  if (root.serviceBroken) return "The background service could not start"
                  return "Automatic switching on monitor hotplug and lid events"
                }
                checked: root.managedChecked
                enabled: !root.serviceActionPending
                hasCursor: root.cursorActive && root.focusSection === "hypr-managed" && root.selectedIndex === -1
                foreground: root.foreground
                fontFamily: root.fontFamily
                onHovered: function(hovered) {
                  if (hovered && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "hypr-managed"
                    root.selectedIndex = -1
                  }
                }
                onClicked: root.setManaged(!root.managedChecked)
              }
            }

            Column {
              visible: root.actionRows.length > 0
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.actionRows

                ActionRow {
                  required property var modelData
                  required property int index

                  width: parent.width
                  rowIndex: index
                  icon: String(modelData.icon)
                  title: String(modelData.title)
                  subtitle: String(modelData.subtitle)
                  onActivated: root.activateRow(String(modelData.id))
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(14)

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(10)

                PanelSectionHeader {
                  text: "LAYOUT AND SETTINGS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                CursorSurface {
                  id: layoutEditor
                  width: parent.width
                  implicitHeight: Style.space(150)
                  bordered: true
                  hasCursor: root.cursorActive && root.focusSection === "hypr-layout" && root.selectedIndex === -1
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(layoutEditor)
                  foreground: root.foreground

                  Text {
                    id: hiddenDisplaysLabel
                    visible: root.hiddenDisplays !== ""
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(12)
                    text: root.hiddenDisplays
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Item {
                    id: layoutCanvas
                    anchors.fill: parent
                    anchors.margins: Style.space(12)
                    anchors.topMargin: Style.space(12)
                      + (hiddenDisplaysLabel.visible ? hiddenDisplaysLabel.height + Style.space(4) : 0)

                    Repeater {
                      model: root.layoutDisplays

                      Rectangle {
                        required property var modelData
                        readonly property bool compactCard: width < Style.space(190)
                        readonly property var previewRect: Hypr.layoutRect(
                          modelData,
                          root.layoutBounds,
                          layoutCanvas.width,
                          layoutCanvas.height,
                          0
                        )

                        x: previewRect.x
                        y: previewRect.y
                        width: previewRect.width
                        height: previewRect.height
                        radius: Math.min(Style.cornerRadius, 5)
                        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
                        border.width: 1
                        border.color: root.foreground

                        Column {
                          anchors.centerIn: parent
                          width: Math.max(0, parent.width - Style.space(8))
                          spacing: Style.space(1)

                          Text {
                            width: parent.width
                            text: String(modelData.name || "Display")
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                          }

                          Text {
                            visible: parent.parent.height >= Style.space(58)
                            width: parent.width
                            text: Hypr.displayModelLabel(modelData, parent.parent.compactCard)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: parent.parent.compactCard ? Text.WordWrap : Text.NoWrap
                            maximumLineCount: parent.parent.compactCard ? 2 : 1
                            elide: Text.ElideRight
                          }

                          Text {
                            visible: !parent.parent.compactCard && text !== "" && parent.parent.height >= Style.space(78)
                            width: parent.width
                            text: Hypr.displayDetailLabel(modelData)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                          }
                        }
                      }
                    }

                    Text {
                      visible: root.layoutDisplays.length === 0
                      anchors.centerIn: parent
                      text: "Waiting for displays…"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: {
                      if (root.reflowingText) return
                      root.cursorActive = true
                      root.focusSection = "hypr-layout"
                      root.selectedIndex = -1
                    }
                    onClicked: root.launchTui()
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "PROFILE"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Item {
                  id: profileInfo
                  width: parent.width
                  implicitHeight: profileContent.implicitHeight + Style.spacing.rowPaddingX

                  Row {
                    id: profileContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(12)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.monitorCount > 1 ? "󰍺" : "󰍹"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }

                    Column {
                      width: parent.width - parent.children[0].width - parent.spacing
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: root.profileStatusTitle
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: root.profileStatusSubtitle
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.foreground
    fill: Style.hoverFillFor(root.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property int rowIndex: 0
    property string icon: ""
    property string title: ""
    property string subtitle: ""
    signal activated()

    hasCursor: root.cursorActive && root.focusSection === "hypr-actions" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(actionRow)
    foreground: root.foreground
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: actionRow.enabled
      onEntered: {
        if (root.reflowingText) return
        root.cursorActive = true
        root.focusSection = "hypr-actions"
        root.selectedIndex = actionRow.rowIndex
      }
      onClicked: actionRow.activated()
    }

    Row {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(12)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: actionRow.icon
        color: actionRow.enabled ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        width: parent.width - parent.children[0].width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: actionRow.title
          color: actionRow.enabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
