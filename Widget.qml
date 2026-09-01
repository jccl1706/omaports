import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaPorts: a bar widget showing how many local ports are currently in use,
// with a popup listing each one (protocol, port, and the owning process).
// Built from the same qs.Commons/qs.Ui components first-party widgets use.
BarWidget {
  id: root
  moduleName: "io.github.jccl1706.omaports"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool opened: popup.open
  property var rawPorts: []
  // Recomputed automatically whenever rawPorts or hideUnknown changes —
  // both are read synchronously inside the filter callback, so QML's
  // binding dependency tracker picks up both.
  readonly property var ports: hideUnknown ? rawPorts.filter(function(p) { return p.process !== "unknown" }) : rawPorts
  readonly property int portCount: ports.length

  readonly property real protoColWidth: Style.space(40)
  readonly property real portColWidth: Style.space(50)
  readonly property real scopeColWidth: Style.space(14)

  readonly property bool hideUnknown: setting("hideUnknown", false) === true

  function setHideUnknown(enabled) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.hideUnknown = enabled
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleHideUnknown() { setHideUnknown(!hideUnknown) }

  // Badge on the bar icon (reusing BarIconButton's built-in active/urgent
  // color, the same mechanism first-party widgets use) for a port that
  // wasn't there on the previous scan — lets a new dev server or container
  // catch your eye without needing the popup open. null (not an empty
  // object) means "no scan yet", so the very first scan never notifies.
  property var seenPortKeys: null
  property bool hasNewPort: false

  function notifyNewPort(entry) {
    if (!bar) return
    bar.run("notify-send " + Util.shellQuote("OmaPorts")
      + " " + Util.shellQuote("New port: " + entry.proto.toUpperCase() + " " + entry.port + " — " + entry.display))
  }

  function checkForNewPorts() {
    var visible = root.ports
    var currentKeys = {}
    var isFirstScan = root.seenPortKeys === null
    for (var i = 0; i < visible.length; i++) {
      var key = visible[i].proto + ":" + visible[i].port
      currentKeys[key] = true
      if (!isFirstScan && !(key in root.seenPortKeys)) {
        if (!root.opened) root.hasNewPort = true
        root.notifyNewPort(visible[i])
      }
    }
    root.seenPortKeys = currentKeys
  }

  // ss can only name the owning process for sockets the current user owns;
  // system services (DNS, printing, mDNS, ...) run as their own system user
  // and show up as "unknown" without root. Rather than prompt for a
  // password just to list sockets, guess from the well-known port instead —
  // clearly marked as a guess, since we're inferring by convention, not
  // reading it from the kernel the way the real process name would be.
  function wellKnownPortName(port) {
    switch (port) {
      case 22: return "SSH"
      case 25: return "SMTP"
      case 53: return "DNS"
      case 67: case 68: return "DHCP"
      case 80: return "HTTP"
      case 110: return "POP3"
      case 123: return "NTP"
      case 143: return "IMAP"
      case 443: return "HTTPS"
      case 445: return "SMB"
      case 465: return "SMTPS"
      case 587: return "SMTP"
      case 631: return "Printing (IPP)"
      case 993: return "IMAPS"
      case 995: return "POP3S"
      case 3306: return "MySQL"
      case 5353: return "mDNS"
      case 5432: return "PostgreSQL"
      case 6379: return "Redis"
      case 8080: return "HTTP"
      case 8443: return "HTTPS"
      case 27017: return "MongoDB"
      default: return ""
    }
  }

  function describeProcess(procName, port) {
    if (procName !== "unknown") return procName
    var guess = wellKnownPortName(port)
    return guess ? "unknown (" + guess + "?)" : "unknown"
  }

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { popup.open = !popup.open }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
  }

  function updatePorts(text) {
    var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
    var list = []
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 5) continue
      var port = parseInt(parts[1], 10)
      if (!isFinite(port)) continue
      var process = parts[2] || "unknown"
      var pid = parts[3] || ""
      list.push({
        proto: parts[0],
        port: port,
        process: process,
        pid: pid,
        scope: parts[4] === "exposed" ? "exposed" : "local",
        display: describeProcess(process, port) + (pid ? " (" + pid + ")" : "")
      })
    }
    root.rawPorts = list
    root.checkForNewPorts()
  }

  onOpenedChanged: if (opened) { hasNewPort = false; refresh() }

  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Built as a script string (not a one-liner) because it needs an
  // associative array: the same proto+port commonly appears more than once
  // in ss's output (bound to both a loopback and a real address, e.g. a
  // stub resolver on 127.0.0.54 and the Docker bridge), and a plain dedup
  // that just kept the first line seen could report "local" for a port
  // that's actually reachable from the network too. Using process
  // substitution (`< <(...)`) rather than a pipe into the while loop is
  // required for that: a piped `while read` runs in a subshell, so the
  // associative-array writes inside it would vanish once the loop ends.
  readonly property string scanScript:
    "declare -A best_scope best_name best_pid\n" +
    "while read -r line; do\n" +
    "  proto=$(awk '{print $1}' <<<\"$line\")\n" +
    "  localfield=$(awk '{print $5}' <<<\"$line\")\n" +
    "  port=\"${localfield##*:}\"\n" +
    "  addr=\"${localfield%:*}\"\n" +
    "  if [[ \"$addr\" == 127.* || \"$addr\" == \"::1\" || \"$addr\" == \"[::1]\" || \"$addr\" == *%lo ]]; then scope=\"local\"; else scope=\"exposed\"; fi\n" +
    "  if [[ $line =~ users:\\(\\(\\\"([^\\\"]+)\\\",pid=([0-9]+) ]]; then\n" +
    "    name=\"${BASH_REMATCH[1]}\"; pid=\"${BASH_REMATCH[2]}\"\n" +
    "  else\n" +
    "    name=\"unknown\"; pid=\"\"\n" +
    "  fi\n" +
    "  key=\"${proto}:${port}\"\n" +
    "  if [[ -z \"${best_scope[$key]:-}\" ]]; then\n" +
    "    best_scope[$key]=\"$scope\"; best_name[$key]=\"$name\"; best_pid[$key]=\"$pid\"\n" +
    "  else\n" +
    // A port that's exposed on any bind is exposed, even if it's also
    // bound to loopback — and prefer whichever bind ss could actually
    // attribute a process to, over one it could only call "unknown".
    "    if [[ \"$scope\" == \"exposed\" ]]; then best_scope[$key]=\"exposed\"; fi\n" +
    "    if [[ \"${best_name[$key]}\" == \"unknown\" && \"$name\" != \"unknown\" ]]; then best_name[$key]=\"$name\"; best_pid[$key]=\"$pid\"; fi\n" +
    "  fi\n" +
    "done < <(ss -Htulpn 2>/dev/null)\n" +
    "for key in \"${!best_scope[@]}\"; do\n" +
    "  proto=\"${key%%:*}\"; port=\"${key##*:}\"\n" +
    "  printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$proto\" \"$port\" \"${best_name[$key]}\" \"${best_pid[$key]}\" \"${best_scope[$key]}\"\n" +
    "done | sort -t$'\\t' -k2,2n -k1,1\n"

  Process {
    id: scanProc
    command: ["bash", "-c", root.scanScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updatePorts(text) }
  }

  // Fast refresh while the popup is visible, a much slower background tick
  // otherwise so the bar count stays roughly current without polling for no
  // reason nobody is looking at.
  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function toggleHideUnknown(): void { root.toggleHideUnknown() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot * 1.7
    // \uf233 is Font Awesome's "server" glyph, part of the standard Nerd
    // Fonts symbol range (f000-f385) — confirmed present by rendering it
    // with the actual configured bar font before using it here, since an
    // out-of-range codepoint silently renders as a blank/tofu box.
    text: "\uf233 " + root.portCount
    tooltipText: "OmaPorts — " + root.portCount + " open port" + (root.portCount === 1 ? "" : "s") + ", click for details"
    // Reuses WidgetButton's built-in active/urgent-color mechanism (the
    // same one first-party widgets use) to flag a newly opened port —
    // simpler than compositing a badge dot onto this text-based icon.
    active: root.hasNewPort
    onPressed: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(Math.min(content.implicitHeight, Style.space(420)))

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: content
        width: parent.width
        spacing: Style.space(16)

        PanelHero {
          title: "OmaPorts"
          meta: root.portCount + " open port" + (root.portCount === 1 ? "" : "s")
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "\uf233"
              font.pixelSize: Style.font.display
              color: root.foreground
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(hideLabel.implicitHeight, hideToggle.implicitHeight)

          Text {
            id: hideLabel
            anchors.left: parent.left
            anchors.right: hideToggle.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "Hide unknown services"
            opacity: 0.8
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: hideToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.hideUnknown
            foreground: root.foreground
            onToggled: root.toggleHideUnknown()
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.ports.length > 0

          PortHeaderRow {}

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.ports

              PortRow {
                required property var modelData
                proto: modelData.proto
                port: modelData.port
                display: modelData.display
                scope: modelData.scope
              }
            }
          }

          Text {
            width: parent.width
            visible: root.ports.some(function(p) { return p.scope === "exposed" })
            text: "●  reachable from your network, not just this PC"
            opacity: 0.6
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: root.ports.length === 0
          width: parent.width
          text: root.rawPorts.length > 0 ? "All ports hidden — turn off \"Hide unknown services\" to see them." : "No listening ports found."
          wrapMode: Text.WordWrap
          color: Qt.darker(root.foreground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component PortHeaderRow: Row {
    id: headerRow
    width: parent.width
    spacing: Style.space(10)

    Item { width: root.scopeColWidth; height: 1 }
    Text {
      text: "PROCESS"
      width: Math.max(Style.space(20), headerRow.width - root.portColWidth - root.protoColWidth - root.scopeColWidth - headerRow.spacing * 3)
      color: Qt.darker(root.foreground, 1.4)
      font.bold: true
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: "PORT"
      width: root.portColWidth
      horizontalAlignment: Text.AlignRight
      color: Qt.darker(root.foreground, 1.4)
      font.bold: true
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: "PROTO"
      width: root.protoColWidth
      color: Qt.darker(root.foreground, 1.4)
      font.bold: true
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  component PortRow: Row {
    id: portRow
    property string proto: ""
    property int port: 0
    property string display: ""
    property string scope: "local"

    width: parent.width
    spacing: Style.space(10)
    height: Style.space(20)

    Item {
      width: root.scopeColWidth
      height: parent.height

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        anchors.centerIn: parent
        visible: portRow.scope === "exposed"
        color: root.bar ? root.bar.urgent : Color.urgent
      }
    }
    Text {
      text: portRow.display
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(20), portRow.width - root.portColWidth - root.protoColWidth - root.scopeColWidth - portRow.spacing * 3)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      text: String(portRow.port)
      width: root.portColWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      font.bold: true
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      text: portRow.proto.toUpperCase()
      width: root.protoColWidth
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0.6
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
