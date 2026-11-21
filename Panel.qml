import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Read-only view of the AMD SMU power limits and live readings, taken straight
// from the ryzen_smu module's pm_table (world-readable, so no root and no
// ryzenadj). The bar shows live package power against the sustained limit; the
// popup lists every limit with a plain-English explanation.
Panel {
  id: root
  moduleName: "abagonhishead.amdpower"
  ipcTarget: "abagonhishead.amdpower"

  readonly property string smuDir: "/sys/kernel/ryzen_smu_drv/"
  readonly property int refreshMs: Math.max(1000, Number(setting("refreshIntervalSec", 2)) * 1000)

  property bool moduleLoaded: false
  property real tableVersion: NaN
  property var decoded: ({ ok: false, reason: "", family: "", rows: [] })
  // Only changes when the table becomes readable or stops being readable, so
  // the group list isn't rebuilt on every refresh.
  property bool tableOk: false
  property string activeProfile: ""

  readonly property var rows: decoded.rows

  // Settings live in this widget's shell.json entry; every one defaults to on.
  readonly property bool showLabel: setting("showLabel", true) !== false
  readonly property bool showBars: setting("showBars", true) !== false
  readonly property bool showLimits: setting("showLimits", true) !== false
  // Pixel size of the bar reading; defaults to Omarchy's caption size.
  readonly property int barFontMin: 7
  readonly property int barFontMax: 16
  readonly property int barFontSize: {
    var size = Math.round(Number(setting("barFontSize", Style.font.caption)))
    return isFinite(size) ? Math.max(barFontMin, Math.min(barFontMax, size)) : Style.font.caption
  }
  function graphEnabled(group) {
    return setting(Model.GRAPHS[group].setting, true) !== false
  }

  function setSetting(name, value) {
    var next = Object.assign({}, root.settings)
    next[name] = value
    root.settings = next
    if (root.bar && root.bar.shell) {
      root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    }
  }

  // Collapsed sections, remembered in the widget's shell.json entry as
  // { power: true, ... }; a missing group is expanded.
  function isCollapsed(group) {
    var collapsed = setting("collapsed", {})
    return !!(collapsed && collapsed[group] === true)
  }

  // The group's headline reading as "value unit", e.g. "10 W" for Power.
  function headlineText(group) {
    var row = Model.findRow(rows, Model.GRAPHS[group].key)
    return row ? number(row.value) + " " + row.unit : ""
  }

  function toggleCollapsed(group) {
    var next = Object.assign({}, setting("collapsed", {}))
    next[group] = !isCollapsed(group)
    setSetting("collapsed", next)
  }

  // The popup shows either the readings or the settings.
  property bool settingsMode: false

  // The last minute of samples for each group's graph: { t, values } points,
  // where values maps each row key to { v, max },
  // kept even while the popup is closed so a graph is full when it opens.
  property var history: ({})
  readonly property int historyMs: 60000

  // Mean package power over the samples in the last minute (NaN until there
  // are any). Sampled every refresh, so it's a time average at that rate.
  readonly property real averagePower: {
    var samples = history.power || []
    var sum = 0
    var count = 0
    for (var i = 0; i < samples.length; i++) {
      var burst = samples[i].values.fast
      if (burst) {
        sum += burst.v
        count++
      }
    }
    return count > 0 ? sum / count : NaN
  }
  readonly property var sustainedRow: Model.findRow(rows, "stapm")
  readonly property var burstRow: Model.findRow(rows, "fast")
  readonly property bool onBattery: UPower.onBattery

  // An APU has integrated Radeon graphics, and AMD names those chips "... with
  // Radeon Graphics" or "... w/ Radeon 780M Graphics"; plain CPUs carry no
  // Radeon in their model name. Read once: the CPU doesn't change.
  readonly property bool isApu: /radeon/i.test(cpuModelName())

  function cpuModelName() {
    var text = String(cpuinfoFile.text() || "")
    var match = text.match(/^model name\s*:\s*(.+)$/m)
    return match ? match[1] : ""
  }

  readonly property string title: isApu ? strings.t("title.apu") : strings.t("title.cpu")

  FileView {
    id: cpuinfoFile
    path: "/proc/cpuinfo"
    blockLoading: true
    printErrors: false
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // One colour per reading within a group, shared by its dot and its graph
  // line. Hues are spread around the wheel; lightness follows the theme's
  // foreground so the lines stay readable on light and dark themes.
  readonly property var seriesHues: [0.57, 0.09, 0.36, 0.86, 0.72, 0.0]
  function seriesColor(group, key) {
    var keys = Model.groupKeys(tableVersion, group)
    var index = Math.max(0, keys.indexOf(key))
    var fg = root.bar ? root.bar.foreground : Commons.Color.foreground
    var lightness = Math.max(0.5, Math.min(0.72, fg.hslLightness))
    return Qt.hsla(seriesHues[index % seriesHues.length], 0.62, lightness, 1)
  }

  // How long before the newest sample a sample was taken, for the graph tooltip.
  function sampleAge(sample, newestTime) {
    if (!sample) {
      return ""
    }
    var seconds = Math.round((newestTime - sample.t) / 1000)
    return seconds <= 0 ? strings.t("graph.now") : strings.t("graph.ago").arg(Commons.I18n.formatNumber(seconds, 0))
  }

  // One graph sample as tooltip rows: { name, value, color } per reading, in
  // the group's order.
  function sampleRows(group, sample) {
    var out = []
    if (!sample) {
      return out
    }
    var keys = Model.groupKeys(tableVersion, group)
    for (var i = 0; i < keys.length; i++) {
      var reading = sample.values[keys[i]]
      if (!reading) {
        continue
      }
      var row = Model.findRow(rows, keys[i])
      out.push({
        name: strings.t("row." + keys[i] + ".name"),
        value: strings.t("of").arg(number(reading.v)).arg(number(reading.max)).arg(row ? row.unit : ""),
        color: seriesColor(group, keys[i])
      })
    }
    return out
  }

  // Tooltip text for one graph sample: how long ago, then each reading.
  function sampleSummary(group, sample, newestTime) {
    if (!sample) {
      return ""
    }
    var seconds = Math.round((newestTime - sample.t) / 1000)
    var lines = [seconds <= 0 ? strings.t("graph.now") : strings.t("graph.ago").arg(Commons.I18n.formatNumber(seconds, 0))]
    var keys = Model.groupKeys(tableVersion, group)
    for (var i = 0; i < keys.length; i++) {
      var reading = sample.values[keys[i]]
      if (!reading) {
        continue
      }
      var row = Model.findRow(rows, keys[i])
      var unit = row ? row.unit : ""
      lines.push(strings.t("row." + keys[i] + ".name") + ": " + strings.t("of").arg(number(reading.v)).arg(number(reading.max)).arg(unit))
    }
    return lines.join("\n")
  }

  function number(value) {
    return Model.formatNumber(value, Commons.I18n.formatNumber)
  }

  function refresh() {
    versionFile.reload()
    var versionBuffer = versionFile.data()
    if (!versionBuffer || versionBuffer.byteLength < 4) {
      moduleLoaded = false
      decoded = { ok: false, reason: "", family: "", rows: [] }
      tableOk = false
      return
    }
    moduleLoaded = true
    tableVersion = Model.readVersion(versionBuffer)

    tableFile.reload()
    decoded = Model.decode(tableVersion, tableFile.data())
    tableOk = decoded.ok
    if (tableOk) {
      recordHistory()
    }
  }

  function recordHistory() {
    var now = Date.now()
    var next = {}
    for (var i = 0; i < Model.GROUPS.length; i++) {
      var group = Model.GROUPS[i]
      var kept = []
      var previous = history[group] || []
      for (var j = 0; j < previous.length; j++) {
        if (now - previous[j].t <= historyMs) {
          kept.push(previous[j])
        }
      }
      var groupRows = Model.rowsInGroup(rows, group)
      if (groupRows.length > 0) {
        var values = {}
        for (var k = 0; k < groupRows.length; k++) {
          values[groupRows[k].key] = { v: groupRows[k].value, max: groupRows[k].limit }
        }
        kept.push({ t: now, values: values })
      }
      next[group] = kept
    }
    history = next
  }

  function refreshProfile() {
    if (!profileProc.running) {
      profileProc.running = true
    }
  }

  function barLabel() {
    if (!decoded.ok || !burstRow || !sustainedRow) {
      return ""
    }
    return Math.round(burstRow.value) + "/" + Math.round(sustainedRow.limit) + "W"
  }

  function errorText() {
    if (!moduleLoaded) {
      return strings.t("error.noModule")
    }
    if (decoded.reason === "unsupported") {
      return strings.t("error.unsupported").arg(Model.versionLabel(tableVersion))
    }
    if (decoded.reason === "short") {
      return strings.t("error.short")
    }
    return ""
  }

  function errorHint() {
    if (!moduleLoaded) {
      return strings.t("error.noModuleHint")
    }
    if (decoded.reason === "unsupported") {
      return strings.t("error.unsupportedHint")
    }
    return ""
  }

  function statusLine() {
    var parts = []
    if (activeProfile !== "") {
      var label = strings.t("profile." + activeProfile)
      parts.push(label === "profile." + activeProfile ? activeProfile : label)
    }
    parts.push(onBattery ? strings.t("onBattery") : strings.t("onAc"))
    return parts.join(" · ")
  }

  // FileView reads the whole file on each reload; sysfs regenerates pm_table
  // from the SMU on every read, so each refresh is a fresh sample.
  FileView {
    id: versionFile
    path: root.smuDir + "pm_table_version"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: tableFile
    path: root.smuDir + "pm_table"
    blockLoading: true
    printErrors: false
  }

  Process {
    id: profileProc
    command: ["powerprofilesctl", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var profile = String(text || "").trim()
        if (/^[a-z-]{1,32}$/.test(profile)) {
          root.activeProfile = profile
        }
      }
    }
  }

  Timer {
    interval: root.opened ? 1000 : root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshProfile()
  }

  onOnBatteryChanged: refreshProfile()

  onOpenedChanged: {
    if (!opened) {
      settingsMode = false
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  TextMetrics {
    id: barLabelMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: root.barFontSize
    text: button.labelText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        BrushRing {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          width: button.iconSize
          height: button.iconSize
          color: root.barForeground
        }
      }
    }
    labelText: !vertical && root.showLabel ? root.barLabel() : ""
    // The slot grows with the reading's measured width, so any text size fits
    // without a gap before the next widget.
    slotSize: labelText !== "" ? Style.bar.iconSlot + barLabelMetrics.advanceWidth + Style.space(4) : Style.bar.iconSlot
    fontSize: root.barFontSize
    tooltipText: strings.t("tooltip").arg(root.title)
    onPressed: function(b) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        root.switchPanel(direction)
      }

      // The full list is taller than a laptop screen, so it scrolls inside
      // the panel once the panel reaches the available height.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
        }

      Column {
        id: column
        // When the panel scrolls, the scroll bar gets its own strip rather
        // than sitting on top of the right-aligned numbers (as Omarchy's
        // agents panel does).
        width: panelFlick.width - (panelFlick.interactive ? panelScroll.width + Style.space(6) : 0)
        spacing: Style.space(14)

        // ---------- Title, with the settings button on the right ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(titleColumn.implicitHeight, settingsButton.height)

          // The widget's ring icon, the same one as in the bar.
          BrushRing {
            id: titleRing
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.title * 1.6
            height: width
            color: root.bar.foreground
          }

          Column {
            id: titleColumn
            anchors.left: titleRing.right
            anchors.leftMargin: Style.space(10)
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: root.title
              width: parent.width
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            PlainText {
              visible: isFinite(root.averagePower)
              text: strings.t("averagePower").arg(root.number(root.averagePower))
              width: parent.width
              color: Qt.darker(root.bar.foreground, 1.4)
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Switches the popup between the readings and the settings.
          PanelActionButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf013"
            tooltipText: root.settingsMode ? strings.t("settings.back") : strings.t("settings.open")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: root.settingsMode
            onClicked: root.settingsMode = !root.settingsMode
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ---------- Power profile and source, with live power on the right ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(statusText.implicitHeight, powerText.implicitHeight)

          PlainText {
            id: statusText
            anchors.left: parent.left
            anchors.right: powerText.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusLine()
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          PlainText {
            id: powerText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.burstRow ? root.number(root.burstRow.value) + " W" : "—"
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        // ---------- Error state ----------
        Column {
          visible: root.errorText() !== ""
          width: parent.width
          spacing: Style.space(4)

          PlainText {
            text: root.errorText()
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.bodySmall
          }

          PlainText {
            visible: text !== ""
            text: root.errorHint()
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.6
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Groups of limits ----------
        Repeater {
          model: root.tableOk ? Model.GROUPS : []

          Column {
            required property string modelData
            readonly property var groupKeys: Model.groupKeys(root.tableVersion, modelData)
            visible: !root.settingsMode && Model.rowsInGroup(root.rows, modelData).length > 0
            width: column.width
            spacing: Style.space(10)

            PanelSeparator {
              foreground: root.bar.foreground
            }

            // Click the header to collapse or expand the section.
            Item {
              id: sectionHeader
              readonly property bool collapsed: root.isCollapsed(modelData)
              width: column.width
              implicitHeight: Math.max(headerText.implicitHeight, chevron.implicitHeight)

              PanelSectionHeader {
                id: headerText
                anchors.left: parent.left
                anchors.right: headline.left
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("group." + modelData)
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              // A collapsed section still shows its headline reading.
              PlainText {
                id: headline
                anchors.right: chevron.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: sectionHeader.collapsed
                text: root.headlineText(modelData)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.pixelSize: Style.font.bodySmall
              }

              PlainText {
                id: chevron
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: sectionHeader.collapsed ? "\uf054" : "\uf078"
                font.pixelSize: Style.font.caption
                opacity: headerMouse.containsMouse ? 1 : 0.5
              }

              MouseArea {
                id: headerMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleCollapsed(modelData)
              }

            }

            Column {
              visible: root.graphEnabled(modelData) && !root.isCollapsed(modelData)
              width: column.width
              spacing: Style.space(4)

              Item {
                id: graphBox
                readonly property string group: modelData
                width: parent.width
                height: Style.space(48)

                Sparkline {
                  id: graph
                  anchors.fill: parent
                  samples: root.history[graphBox.group] || []
                  keys: groupKeys
                  colors: groupKeys.map(function(key) { return root.seriesColor(graphBox.group, key) })
                  windowMs: root.historyMs
                  baseColor: root.bar.foreground
                  showLimits: root.showLimits
                  hoverX: graphHover.containsMouse ? graphHover.mouseX : -1
                }

                MouseArea {
                  id: graphHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                // Omarchy's tooltip frame with custom content: the sample's age,
                // then each reading with its colour dot and its name in bold.
                PanelToolTip {
                  id: graphTip
                  x: Math.max(0, Math.min(parent.width - width, graphHover.mouseX - width / 2))
                  width: Math.min(implicitWidth, parent.width)
                  visible: graphHover.containsMouse && graph.hoverSample !== null
                  text: root.sampleSummary(graphBox.group, graph.hoverSample, graph.newestTime)
                  fontFamily: root.bar.fontFamily

                  contentItem: Column {
                    spacing: Style.space(3)
                    leftPadding: Border.left(graphTip.panelBorderSpec) + Style.spacing.controlPaddingX
                    rightPadding: Border.right(graphTip.panelBorderSpec) + Style.spacing.controlPaddingX
                    topPadding: Border.top(graphTip.panelBorderSpec) + Style.spacing.controlPaddingY
                    bottomPadding: Border.bottom(graphTip.panelBorderSpec) + Style.spacing.controlPaddingY

                    Text {
                      textFormat: Text.PlainText
                      text: root.sampleAge(graph.hoverSample, graph.newestTime)
                      color: graphTip.panelForeground
                      opacity: 0.6
                      font.family: graphTip.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Repeater {
                      model: root.sampleRows(graphBox.group, graph.hoverSample)

                      Row {
                        required property var modelData
                        spacing: Style.space(6)

                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(7)
                          height: width
                          radius: width / 2
                          color: modelData.color
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: modelData.name
                          color: graphTip.panelForeground
                          font.family: graphTip.fontFamily
                          font.pixelSize: graphTip.fontSize
                          font.bold: true
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: modelData.value
                          color: graphTip.panelForeground
                          font.family: graphTip.fontFamily
                          font.pixelSize: graphTip.fontSize
                        }
                      }
                    }
                  }
                }
              }

            }

            Repeater {
              model: groupKeys

              LimitRow {
                required property var modelData
                row: Model.findRow(root.rows, modelData)
                visible: row !== null && !root.isCollapsed(row.group)
                width: column.width
              }
            }
          }
        }

        // ---------- Footer: which table is being read ----------
        // ---------- Settings ----------
        // Three unnamed groups split by separators: the bar reading, the
        // readings' bars, and the graphs.
        Column {
          visible: root.settingsMode
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator {
            foreground: root.bar.foreground
          }

          SettingRow {
            label: strings.t("settings.showLabel")
            description: strings.t("settings.showLabelHelp")
            checked: root.showLabel
            onToggled: root.setSetting("showLabel", !root.showLabel)
          }

          // Text size of the bar reading.
          Item {
            width: parent.width
            implicitHeight: Math.max(fontLabel.implicitHeight, fontPlus.height)
            opacity: root.showLabel ? 1 : 0.5

            PlainText {
              id: fontLabel
              anchors.left: parent.left
              anchors.right: fontMinus.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.barFontSize")
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PanelActionButton {
              id: fontMinus
              anchors.right: fontValue.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf068"
              tooltipText: strings.t("settings.smaller")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: root.showLabel && root.barFontSize > root.barFontMin
              onClicked: root.setSetting("barFontSize", root.barFontSize - 1)
            }

            PlainText {
              id: fontValue
              anchors.right: fontPlus.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("settings.px").arg(Commons.I18n.formatNumber(root.barFontSize, 0))
              font.pixelSize: Style.font.bodySmall
            }

            PanelActionButton {
              id: fontPlus
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf067"
              tooltipText: strings.t("settings.larger")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: root.showLabel && root.barFontSize < root.barFontMax
              onClicked: root.setSetting("barFontSize", root.barFontSize + 1)
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          SettingRow {
            label: strings.t("settings.showBars")
            description: strings.t("settings.showBarsHelp")
            checked: root.showBars
            onToggled: root.setSetting("showBars", !root.showBars)
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          PlainText {
            width: parent.width
            text: strings.t("settings.graphsFor")
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: Model.GROUPS

            SettingRow {
              required property string modelData
              label: strings.t("group." + modelData)
              indent: true
              checked: root.graphEnabled(modelData)
              onToggled: root.setSetting(Model.GRAPHS[modelData].setting, !root.graphEnabled(modelData))
            }
          }

          SettingRow {
            label: strings.t("settings.showLimits")
            description: strings.t("settings.showLimitsHelp")
            checked: root.showLimits
            onToggled: root.setSetting("showLimits", !root.showLimits)
          }
        }

        PlainText {
          visible: root.decoded.ok && !root.settingsMode
          text: strings.t(root.decoded.verified ? "table" : "tableUnverified").arg(root.decoded.family).arg(Model.versionLabel(root.tableVersion))
          wrapMode: Text.WordWrap
          opacity: 0.4
          font.pixelSize: Style.font.caption
          width: parent.width
          horizontalAlignment: Text.AlignRight
        }
      }
      }
    }
  }

  // One limit: name with RyzenAdj's row name beside it, "value of limit unit"
  // and a fill bar. The explanation only shows on hover, so the list stays
  // compact.
  component LimitRow: Item {
    property var row: null
    readonly property bool nearLimit: row && row.fraction >= 0.95

    implicitHeight: rowColumn.implicitHeight

    Column {
      id: rowColumn
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: Math.max(rowName.implicitHeight, rowValue.implicitHeight)

        Row {
          anchors.left: parent.left
          anchors.right: rowValue.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          clip: true

          Rectangle {
            anchors.verticalCenter: rowName.verticalCenter
            width: Style.space(7)
            height: width
            radius: width / 2
            color: row ? root.seriesColor(row.group, row.key) : "transparent"
          }

          PlainText {
            id: rowName
            text: row ? strings.t("row." + row.key + ".name") : ""
            font.pixelSize: Style.font.bodySmall
          }

          PlainText {
            anchors.baseline: rowName.baseline
            text: row ? row.ryzenadj : ""
            opacity: 0.4
            font.pixelSize: Style.font.caption
          }
        }

        PlainText {
          id: rowValue
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row ? strings.t("of").arg(root.number(row.value)).arg(root.number(row.limit)).arg(row.unit) : ""
          color: nearLimit ? Commons.Color.urgent : root.bar.foreground
          font.pixelSize: Style.font.bodySmall
        }
      }

      Item {
        visible: root.showBars
        width: parent.width
        implicitHeight: Style.space(5)

        Rectangle {
          id: track
          anchors.fill: parent
          radius: height / 2
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
        }

        Rectangle {
          anchors.left: track.left
          anchors.verticalCenter: track.verticalCenter
          height: track.height
          radius: track.radius
          color: nearLimit ? Commons.Color.urgent : root.bar.foreground
          width: row ? Math.max(track.height, track.width * row.fraction) : 0

          Behavior on width {
            NumberAnimation {
              duration: Style.duration(240)
              easing.type: Easing.OutCubic
            }
          }
        }
      }
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    // Capped to the row's width so long explanations wrap inside the popup
    // instead of running off its edge.
    PanelToolTip {
      x: 0
      width: Math.min(implicitWidth, parent.width)
      visible: rowHover.containsMouse
      text: row ? strings.t("row." + row.key + ".help") : ""
      fontFamily: root.bar.fontFamily
    }
  }

  // An open brush-stroke ring, drawn in one colour: a full-width stroke that
  // starts with a rounded head at the bottom, runs clockwise and thins out to
  // a dry tail, leaving a gap. Original artwork in the spirit of an ensō.
  component BrushRing: Canvas {
    id: ring
    property color color: Commons.Color.foreground

    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var size = Math.min(width, height)
      if (size <= 0) {
        return
      }
      var cx = width / 2
      var cy = height / 2
      var stroke = size * 0.2
      var radius = size / 2 - stroke / 2
      var start = Math.PI * 0.62
      var sweep = Math.PI * 1.72
      var steps = 48

      ctx.strokeStyle = ring.color
      ctx.lineCap = "round"
      for (var i = 0; i < steps; i++) {
        var t = i / steps
        var taper = t < 0.7 ? 1 : 1 - ((t - 0.7) / 0.3) * 0.85
        ctx.lineWidth = Math.max(0.6, stroke * taper)
        ctx.beginPath()
        ctx.arc(cx, cy, radius, start + sweep * t, start + sweep * (i + 1.15) / steps, false)
        ctx.stroke()
      }
    }
  }

  // The last minute of a group's readings, one line per reading, each scaled
  // from 0 to its own limit (the top edge is the limit) so lines with
  // different limits can share a graph. Time runs left to right, with now at
  // the right edge. hoverX picks the nearest sample, drawn as a marker line.
  component Sparkline: Canvas {
    id: spark
    property var samples: []
    property var keys: []
    property var colors: []
    property int windowMs: 60000
    property color baseColor: Commons.Color.foreground
    property real hoverX: -1
    // With limits shown, every line shares one scale in the group's unit (0 to
    // a little above the highest limit in view) and each reading's limit is a
    // faint line in its colour, following the limit as it changes over time.
    // Without them, each line is scaled to its own limit.
    property bool showLimits: false

    readonly property real newestTime: samples && samples.length > 0 ? samples[samples.length - 1].t : 0
    readonly property var hoverSample: {
      if (hoverX < 0 || !samples || samples.length === 0) {
        return null
      }
      var best = null
      var bestDistance = Infinity
      for (var i = 0; i < samples.length; i++) {
        var distance = Math.abs(xFor(samples[i]) - hoverX)
        if (distance < bestDistance) {
          bestDistance = distance
          best = samples[i]
        }
      }
      return best
    }

    function xFor(sample) {
      return width * (1 - (newestTime - sample.t) / windowMs)
    }

    onSamplesChanged: requestPaint()
    onShowLimitsChanged: requestPaint()
    onColorsChanged: requestPaint()
    onHoverSampleChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pad = 1.5

      // Baseline, so an empty or flat graph still reads as a graph.
      ctx.strokeStyle = Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.15)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, height - 0.5)
      ctx.lineTo(width, height - 0.5)
      ctx.stroke()

      if (!samples || samples.length < 2) {
        return
      }

      var scaleMax = 0
      if (showLimits) {
        for (var s = 0; s < samples.length; s++) {
          for (var sk = 0; sk < keys.length; sk++) {
            var r = samples[s].values[keys[sk]]
            if (r) {
              scaleMax = Math.max(scaleMax, r.max, r.v)
            }
          }
        }
        scaleMax *= 1.08
      }
      function yFor(v, max) {
        var fraction = showLimits
          ? (scaleMax > 0 ? v / scaleMax : 0)
          : (max > 0 ? v / max : 0)
        fraction = Math.max(0, Math.min(1, fraction))
        return pad + (height - 2 * pad) * (1 - fraction)
      }

      // Limit lines first, so the readings draw over them. Each holds its
      // value until the next sample, so a changed limit shows as a step.
      if (showLimits) {
        for (var lk = 0; lk < keys.length; lk++) {
          var limitStarted = false
          var lastY = 0
          ctx.beginPath()
          for (var li = 0; li < samples.length; li++) {
            var limitReading = samples[li].values[keys[lk]]
            if (!limitReading) {
              continue
            }
            var lx = xFor(samples[li])
            var ly = yFor(limitReading.max, limitReading.max)
            if (!limitStarted) {
              ctx.moveTo(lx, ly)
              limitStarted = true
            } else {
              ctx.lineTo(lx, lastY)
              ctx.lineTo(lx, ly)
            }
            lastY = ly
          }
          if (limitStarted) {
            var limitColor = colors[lk] || baseColor
            ctx.strokeStyle = Qt.rgba(limitColor.r, limitColor.g, limitColor.b, 0.35)
            ctx.lineWidth = 1
            ctx.stroke()
          }
        }
      }

      for (var k = 0; k < keys.length; k++) {
        var key = keys[k]
        var started = false
        ctx.beginPath()
        for (var i = 0; i < samples.length; i++) {
          var reading = samples[i].values[key]
          if (!reading) {
            continue
          }
          var x = xFor(samples[i])
          var y = yFor(reading.v, reading.max)
          if (!started) {
            ctx.moveTo(x, y)
            started = true
          } else {
            ctx.lineTo(x, y)
          }
        }
        if (started) {
          ctx.strokeStyle = colors[k] || baseColor
          ctx.lineWidth = 1.5
          ctx.lineJoin = "round"
          ctx.stroke()
        }
      }

      if (hoverSample) {
        var hx = Math.round(xFor(hoverSample)) + 0.5
        ctx.strokeStyle = Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.5)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(hx, 0)
        ctx.lineTo(hx, height)
        ctx.stroke()
      }
    }
  }

  // A settings row without a box: label (and optional grey description) on
  // the left, Omarchy's switch on the right.
  component SettingRow: Item {
    id: settingRow
    property string label: ""
    property string description: ""
    property bool checked: false
    property bool indent: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(settingText.implicitHeight, settingSwitch.implicitHeight)

    Column {
      id: settingText
      anchors.left: parent.left
      anchors.leftMargin: settingRow.indent ? Style.space(12) : 0
      anchors.right: settingSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PlainText {
        width: parent.width
        text: settingRow.label
        font.pixelSize: Style.font.bodySmall
        opacity: settingRow.indent ? 0.8 : 1
        wrapMode: Text.WordWrap
      }

      PlainText {
        visible: settingRow.description !== ""
        width: parent.width
        text: settingRow.description
        color: Qt.darker(root.bar.foreground, 1.4)
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: settingSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: settingRow.checked
      foreground: root.bar.foreground
      onToggled: settingRow.toggled()
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
  }
}
