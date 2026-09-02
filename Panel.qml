import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "mihai.displays"
  ipcTarget: "mihai.displays"
  manageIpc: true

  property var monitors: []
  property string selected: ""
  property var terminalSizes: ({})

  // --- Ported from omarchy.monitor: brightness, text size, display power ---
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string focusedMonitor: ""
  property var displayStates: []
  property int enabledDisplayCount: 0
  property int kbdBrightnessPercent: 0
  property int pendingKbdBrightnessPercent: 0
  property bool kbdBrightnessSetQueued: false
  property bool kbdBrightnessAvailable: false

  // Carries sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Curated stops (px). The CLI accepts any integer in range; the slider snaps.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // Holds the chosen stop while the change round-trips through the file Style
  // watches, so the knob does not snap back mid-flight. -1 = follow Style.
  property int textSizePreviewIndex: -1

  // Absolute path to this plugin's bundled scripts, so the panel works on
  // install without relying on the shell's PATH. (Qt.resolvedUrl(".") is the
  // directory of this Panel.qml.)
  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace("file://", "") + "/bin"

  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var transformPresets: ["0", "1", "2", "3"]
  readonly property var terminals: ["alacritty", "kitty", "ghostty", "foot"]

  function shellEscape(s) {
    if (s === undefined || s === null) return "''"
    var str = String(s)
    return "'" + str.replace(/'/g, "'\\''") + "'"
  }

  function selectedMonitor() {
    if (!root.monitors || root.monitors.length === 0) return null
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === root.selected) return root.monitors[i]
    for (var j = 0; j < root.monitors.length; j++)
      if (root.monitors[j].focused) return root.monitors[j]
    return root.monitors[0]
  }

  function currentModeString(m) {
    if (!m || !m.modes || m.modes.length === 0) return ""
    var best = ""
    var bestDiff = 1e9
    var cur = Number(m.refreshRate)
    for (var i = 0; i < m.modes.length; i++) {
      var s = m.modes[i]
      var at = s.indexOf("@")
      if (at < 0) continue
      var dims = s.slice(0, at)
      var rate = parseFloat(s.slice(at + 1).replace("Hz", ""))
      if (!isNaN(rate) && dims === (m.width + "x" + m.height)) {
        var diff = Math.abs(rate - cur)
        if (diff < bestDiff) { bestDiff = diff; best = s }
      }
    }
    return best
  }

  function modeOptions(m) {
    if (!m || !m.modes) return []
    var seen = {}
    var out = []
    for (var i = 0; i < m.modes.length; i++) {
      var s = m.modes[i]
      if (!s || seen[s]) continue
      seen[s] = true
      out.push({ value: s, label: s })
    }
    return out
  }

  function refresh() {
    if (!monitorProc.running) monitorProc.running = true
    if (!termProc.running) termProc.running = true
    if (!stateProc.running) stateProc.running = true
    if (!kbdStateProc.running) kbdStateProc.running = true
  }

  function setMonitor(flag, val) {
    var m = root.selectedMonitor()
    if (!m) return
    actionProc.command = ["bash", "-c", root.scriptDir + "/omarchy-display-monitor set " + root.shellEscape(m.name) + " " + root.shellEscape(flag) + " " + root.shellEscape(val)]
    if (!actionProc.running) actionProc.running = true
  }

  function setTerminal(term, size) {
    actionProc.command = ["bash", "-c", root.scriptDir + "/omarchy-display-terminal set " + root.shellEscape(term) + " " + root.shellEscape(size)]
    if (!actionProc.running) actionProc.running = true
  }

  function stepTerminal(term, delta) {
    var cur = Number(root.terminalSizes[term] || 0)
    if (!(cur > 0)) return
    var next = cur + delta
    if (next < 6) next = 6
    if (next > 40) next = 40
    root.setTerminal(term, next)
  }

  function clampBrightness(value) {
    var n = Number(value)
    if (!isFinite(n)) return 1
    return Math.max(1, Math.min(100, Math.round(n)))
  }

  function setBrightness(value) {
    var percent = root.clampBrightness(value)
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
    root.brightnessPercent = root.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!root.bar || !root.bar.shell) return
    root.bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: percent }))
  }

  function setKbdBrightness(value) {
    var percent = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (!isFinite(percent)) return
    root.kbdBrightnessPercent = percent
    root.pendingKbdBrightnessPercent = percent
    if (setKbdBrightnessProc.running) {
      root.kbdBrightnessSetQueued = true
      return
    }
    root.kbdBrightnessSetQueued = false
    setKbdBrightnessProc.command = ["bash", "-c", root.scriptDir + "/omarchy-display-keyboard set " + root.shellEscape(percent)]
    setKbdBrightnessProc.running = true
  }

  function previewKbdBrightness(value) {
    root.kbdBrightnessPercent = Math.max(0, Math.min(100, Math.round(Number(value))))
    kbdBrightnessDebounce.restart()
  }

  function nearestTextStop(px) {
    var best = 0
    var bestDiff = 1e9
    for (var i = 0; i < root.textSizeStops.length; i++) {
      var diff = Math.abs(root.textSizeStops[i] - px)
      if (diff < bestDiff) { bestDiff = diff; best = i }
    }
    return best
  }

  function currentTextIndex() {
    return root.textSizePreviewIndex >= 0 ? root.textSizePreviewIndex : root.nearestTextStop(Style.font.baseSize)
  }

  function displayedTextPx() {
    return root.textSizePreviewIndex >= 0 ? root.textSizeStops[root.textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  // Refuses to disable the last enabled output, which would black out the session.
  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return
    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function posFor(selected, other, dir) {
    var sw = selected.width, sh = selected.height
    var ox = other.x, oy = other.y, ow = other.width, oh = other.height
    if (dir === "left") return (ox - sw) + "x" + oy
    if (dir === "right") return (ox + ow) + "x" + oy
    if (dir === "above") return ox + "x" + (oy - sh)
    if (dir === "below") return ox + "x" + (oy + oh)
    return "auto"
  }

  function monitorByName(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === name) return root.monitors[i]
    return null
  }

  function positionButtons() {
    var sel = root.selectedMonitor()
    if (!sel) return []
    var out = []
    var dirs = [
      { dir: "left", glyph: "◀" },
      { dir: "right", glyph: "▶" },
      { dir: "above", glyph: "▲" },
      { dir: "below", glyph: "▼" }
    ]
    for (var i = 0; i < root.monitors.length; i++) {
      var o = root.monitors[i]
      if (o.name === root.selected) continue
      for (var d = 0; d < dirs.length; d++)
        out.push({ label: dirs[d].glyph + " " + o.name, other: o.name, dir: dirs[d].dir })
    }
    return out
  }

  Component.onCompleted: {
    root.refresh()
    // Install the backend scripts onto PATH on first load so the `omarchy
    // display` CLI group and the Display menu submenu work after the plugin
    // is added/enabled. Idempotent — safe to run every load.
    if (!installProc.running) installProc.running = true
  }

  onOpenedChanged: if (opened) refresh()

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: monitorProc
    command: ["bash", "-c", "hyprctl monitors -j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "[]"))
          var out = []
          for (var i = 0; i < arr.length; i++) {
            var d = arr[i]
            var modeStrings = []
            if (Array.isArray(d.modes)) {
              for (var mi = 0; mi < d.modes.length; mi++) {
                var rm = d.modes[mi]
                if (rm && rm.width) modeStrings.push(rm.width + "x" + rm.height + "@" + rm.refreshRate)
              }
            }
            if (modeStrings.length === 0 && Array.isArray(d.availableModes))
              modeStrings = d.availableModes.slice()
            out.push({
              name: d.name,
              width: d.width, height: d.height,
              x: d.x, y: d.y,
              scale: d.scale, transform: d.transform,
              focused: !!d.focused,
              modes: modeStrings
            })
          }
          root.monitors = out
          if (!root.selected) {
            for (var k = 0; k < out.length; k++) if (out[k].focused) root.selected = out[k].name
            if (!root.selected && out.length) root.selected = out[0].name
          }
        } catch (e) { /* ignore parse errors */ }
      }
    }
  }

  Process {
    id: termProc
    command: ["bash", "-c", root.scriptDir + "/omarchy-display-terminal list --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.terminalSizes = JSON.parse(String(text || "{}")) }
        catch (e) { /* ignore */ }
      }
    }
  }

  Process {
    id: installProc
    command: ["bash", "-c", root.scriptDir + "/../install --silent"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // omarchy-monitor-state emits one field per line. We use brightness (0),
  // the focused output (5) and the displays JSON (7) -- unlike
  // `hyprctl monitors -j`, that JSON also lists outputs currently disabled,
  // which is what makes re-enabling them possible.
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
        root.focusedMonitor = String(lines[5] || "").trim()
        try {
          var parsed = JSON.parse(String(lines[7] || "[]").trim())
          var count = 0
          for (var i = 0; i < parsed.length; i++) if (parsed[i].enabled) count++
          root.displayStates = parsed
          root.enabledDisplayCount = count
        } catch (e) { /* ignore parse errors */ }
      }
    }
  }

  // Unlike the display backlight, there is no omarchy CLI that sets an
  // absolute keyboard level (omarchy-brightness-keyboard only steps), so this
  // uses the bundled script.
  Process {
    id: kbdStateProc
    command: ["bash", "-c", root.scriptDir + "/omarchy-display-keyboard get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        root.kbdBrightnessAvailable = value !== "unavailable" && value !== ""
        if (root.kbdBrightnessAvailable)
          root.kbdBrightnessPercent = Math.max(0, Math.min(100, parseInt(value, 10)))
      }
    }
  }

  Timer {
    id: kbdBrightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setKbdBrightness(root.kbdBrightnessPercent)
  }

  // Same reasoning as setBrightnessProc: no refresh on completion, since
  // re-reading can race the LED driver and snap the knob back.
  Process {
    id: setKbdBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.kbdBrightnessSetQueued) root.setKbdBrightness(root.pendingKbdBrightnessPercent)
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  // Deliberately does NOT refresh on completion: the percent just written is
  // authoritative, and re-reading races the backlight driver -- it can return
  // an empty string, which parses to 0 and bounces the slider to zero.
  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) root.setBrightness(root.pendingBrightnessPercent)
    }
  }

  // Rewrites the shell override file; Style picks the new base size up through
  // its own file watch, so there is nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Once Style's base size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      if (root.textSizePreviewIndex < 0) return
      if (Style.font.baseSize === root.textSizeStops[root.textSizePreviewIndex])
        root.textSizePreviewIndex = -1
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢹"
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: heroIcon.implicitHeight
          Text {
            id: heroIcon
            text: "󰢹"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "Displays"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Brightness ----------
        PanelSeparator { visible: root.brightnessAvailable; foreground: root.bar.foreground }
        Column {
          visible: root.brightnessAvailable
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessValue.implicitHeight)
            PanelSectionHeader {
              id: brightnessHeader
              text: "BRIGHTNESS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: brightnessValue
              textFormat: Text.PlainText
              text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: brightnessSlider
            bar: root.bar
            width: parent.width
            minimum: 1
            maximum: 100
            step: 1
            integer: true
            value: root.brightnessPercent
            onMoved: function(v) { root.previewBrightness(v) }
            onReleased: function(v) {
              brightnessDebounce.stop()
              root.setBrightness(v)
            }
          }
        }

        // ---------- Keyboard backlight ----------
        Column {
          visible: root.kbdBrightnessAvailable
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(kbdHeader.implicitHeight, kbdValue.implicitHeight)
            PanelSectionHeader {
              id: kbdHeader
              text: "KEYBOARD"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: kbdValue
              textFormat: Text.PlainText
              text: Math.round(kbdSlider.dragging ? kbdSlider.liveValue : root.kbdBrightnessPercent) + "%"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: kbdSlider
            bar: root.bar
            width: parent.width
            // Unlike the display backlight, 0 is valid here -- the keyboard
            // light off is a normal state, not a black screen.
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: root.kbdBrightnessPercent
            onMoved: function(v) { root.previewKbdBrightness(v) }
            onReleased: function(v) {
              kbdBrightnessDebounce.stop()
              root.setKbdBrightness(v)
            }
          }
        }

        // ---------- Monitor selector ----------
        PanelSeparator { foreground: root.bar.foreground }
        PanelSectionHeader { text: "MONITOR"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

        Row {
          width: parent.width
          spacing: Style.spacing.xs
          Repeater {
            model: root.monitors
            Button {
              required property var modelData
              text: modelData.name
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              bordered: true
              active: root.selected === modelData.name
              onClicked: root.selected = modelData.name
            }
          }
        }

        // ---------- Resolution / Scale / Position / Orientation ----------
        PanelSeparator { foreground: root.bar.foreground }
        Column {
          width: parent.width
          spacing: Style.space(10)
          PanelSectionHeader { text: "RESOLUTION"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          SearchableDropdown {
            width: parent.width
            foreground: root.bar.foreground
            value: root.currentModeString(root.selectedMonitor())
            options: root.modeOptions(root.selectedMonitor())
            onChanged: function(v) { root.setMonitor("--mode", v) }
          }

          PanelSectionHeader { text: "SCALE"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          Row {
            width: parent.width
            spacing: Style.spacing.xs
            Repeater {
              model: root.scalePresets
              Button {
                required property string modelData
                text: modelData + "x"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                bordered: true
                active: {
                  var m = root.selectedMonitor()
                  m && Math.abs(Number(m.scale) - Number(modelData)) < 0.001
                }
                onClicked: root.setMonitor("--scale", modelData)
              }
            }
          }

          PanelSectionHeader { text: "POSITION"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          Flow {
            width: parent.width
            spacing: Style.spacing.xs
            Button {
              text: "Auto"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              bordered: true
              onClicked: root.setMonitor("--pos", "auto")
            }
            Repeater {
              model: root.positionButtons()
              Button {
                required property var modelData
                text: modelData.label
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                bordered: true
                onClicked: {
                  var m = root.selectedMonitor()
                  var other = root.monitorByName(modelData.other)
                  if (m && other) root.setMonitor("--pos", root.posFor(m, other, modelData.dir))
                }
              }
            }
          }

          PanelSectionHeader { text: "ORIENTATION"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          Row {
            width: parent.width
            spacing: Style.spacing.xs
            Repeater {
              model: root.transformPresets
              Button {
                required property string modelData
                text: ({ "0": "0°", "1": "90°", "2": "180°", "3": "270°" })[modelData]
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                bordered: true
                active: {
                  var m = root.selectedMonitor()
                  m && Number(m.transform) === Number(modelData)
                }
                onClicked: root.setMonitor("--transform", modelData)
              }
            }
          }
        }

        // ---------- Display power ----------
        PanelSeparator { visible: root.displayStates.length > 1; foreground: root.bar.foreground }
        Column {
          visible: root.displayStates.length > 1
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader { text: "DISPLAYS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          Repeater {
            model: root.displayStates
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.spacing.sm
              Text {
                text: modelData.name + (modelData.focused ? " \u00b7 focused" : "")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - powerToggle.width - Style.spacing.sm
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }
              Button {
                id: powerToggle
                text: modelData.enabled ? "On" : "Off"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                bordered: true
                active: modelData.enabled
                // The last enabled output must stay on.
                enabled: !modelData.enabled || root.enabledDisplayCount > 1
                onClicked: root.toggleDisplay(modelData.name, modelData.enabled)
              }
            }
          }
        }

        // ---------- Text size ----------
        PanelSeparator { foreground: root.bar.foreground }
        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizeValue.implicitHeight)
            PanelSectionHeader {
              id: textSizeHeader
              text: "TEXT SIZE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: textSizeValue
              textFormat: Text.PlainText
              text: (textSizeSlider.dragging
                     ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                     : root.displayedTextPx()) + "px"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: textSizeSlider
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: root.textSizeStops.length - 1
            step: 1
            integer: true
            tickCount: root.textSizeStops.length
            value: root.currentTextIndex()
            onReleased: function(v) {
              root.textSizePreviewIndex = Math.round(v)
              root.setTextSize(root.textSizeStops[Math.round(v)])
            }
          }
        }

        // ---------- Terminal fonts ----------
        PanelSeparator { foreground: root.bar.foreground }
        PanelSectionHeader { text: "TERMINAL FONT"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
        Column {
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.terminals
            Row {
              required property string modelData
              width: parent.width
              spacing: Style.spacing.sm
              Text {
                text: modelData
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(86)
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }
              Button {
                text: "−"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.body
                bordered: true
                onClicked: root.stepTerminal(modelData, -1)
              }
              Text {
                text: String(root.terminalSizes[modelData] || "—")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                width: Style.space(34)
                anchors.verticalCenter: parent.verticalCenter
              }
              Button {
                text: "+"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.body
                bordered: true
                onClicked: root.stepTerminal(modelData, 1)
              }
            }
          }
        }

        Item { width: parent.width; height: Style.space(4) }
      }
    }
  }
}
