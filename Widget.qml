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

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { popup.open = !popup.open }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
  }

  // ss shows the owning process only for sockets the current user owns;
  // system services (DNS, CUPS, ...) show as "unknown" without root. That
  // matches how similar menu-bar port monitors behave rather than prompting
  // for a password just to list sockets.
  function updatePorts(text) {
    var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
    var list = []
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 3) continue
      var port = parseInt(parts[1], 10)
      if (!isFinite(port)) continue
      list.push({ proto: parts[0], port: port, process: parts[2] || "unknown", pid: parts[3] || "" })
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
    text: "🔌 " + root.portCount
    tooltipText: "OmaPorts — " + root.portCount + " open port" + (root.portCount === 1 ? "" : "s") + ", click for details"
    onPressed: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: popup.fittedContentWidth(Style.space(320))
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
        spacing: Style.space(14)

        PanelHero {
          title: "OmaPorts"
          meta: root.portCount + " open port" + (root.portCount === 1 ? "" : "s")
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "🔌"
              font.pixelSize: Style.font.display
              color: root.foreground
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.ports.length > 0

          PanelSectionHeader {
            text: "PROTO   PORT   PROCESS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.ports

            PortRow {
              required property var modelData
              proto: modelData.proto
              port: modelData.port
              process: modelData.process
              pid: modelData.pid
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

  component PortRow: Row {
    id: portRow
    property string proto: ""
    property int port: 0
    property string process: ""
    property string pid: ""

    readonly property real protoWidth: Style.space(36)
    readonly property real portWidth: Style.space(48)

    width: parent.width
    spacing: Style.space(10)

    Text {
      text: portRow.proto.toUpperCase()
      width: portRow.protoWidth
      opacity: 0.6
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      text: String(portRow.port)
      width: portRow.portWidth
      font.bold: true
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      text: portRow.process + (portRow.pid ? " (" + portRow.pid + ")" : "")
      elide: Text.ElideRight
      width: Math.max(Style.space(20), portRow.width - portRow.protoWidth - portRow.portWidth - portRow.spacing * 2)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
