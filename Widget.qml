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
  property var ports: []
  readonly property int portCount: ports.length

  readonly property real protoColWidth: Style.space(40)
  readonly property real portColWidth: Style.space(50)

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
      if (parts.length < 3) continue
      var port = parseInt(parts[1], 10)
      if (!isFinite(port)) continue
      var process = parts[2] || "unknown"
      var pid = parts[3] || ""
      list.push({
        proto: parts[0],
        port: port,
        process: process,
        pid: pid,
        display: describeProcess(process, port) + (pid ? " (" + pid + ")" : "")
      })
    }
    root.ports = list
  }

  onOpenedChanged: if (opened) refresh()

  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: scanProc
    command: ["bash", "-c",
      "ss -Htulpn 2>/dev/null | while read -r line; do "
      + "proto=$(awk '{print $1}' <<<\"$line\"); "
      + "port=$(grep -oP ':\\K[0-9]+(?=\\s)' <<<\"$line\" | head -1); "
      + "if [[ $line =~ users:\\(\\(\\\"([^\\\"]+)\\\",pid=([0-9]+) ]]; then "
      + "name=\"${BASH_REMATCH[1]}\"; pid=\"${BASH_REMATCH[2]}\"; else name=\"unknown\"; pid=\"\"; fi; "
      + "printf '%s\\t%s\\t%s\\t%s\\n' \"$proto\" \"$port\" \"$name\" \"$pid\"; "
      + "done | sort -t$'\\t' -k2,2n -k1,1 -u"]
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
              }
            }
          }
        }

        Text {
          visible: root.ports.length === 0
          width: parent.width
          text: "No listening ports found."
          color: Qt.darker(root.foreground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component PortHeaderRow: Row {
    width: parent.width
    spacing: Style.space(10)

    Text {
      text: "PROTO"
      width: root.protoColWidth
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
      text: "PROCESS"
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

    width: parent.width
    spacing: Style.space(10)
    height: Style.space(20)

    Text {
      text: portRow.proto.toUpperCase()
      width: root.protoColWidth
      anchors.verticalCenter: parent.verticalCenter
      opacity: 0.6
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
      text: portRow.display
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(20), portRow.width - root.protoColWidth - root.portColWidth - portRow.spacing * 2)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
