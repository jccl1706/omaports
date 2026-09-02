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
  // Recomputed automatically whenever rawPorts, hideUnknown, trafficRates,
  // or dockerContainers changes — all four are read synchronously in here,
  // so QML's binding dependency tracker picks up all of them. Traffic rates
  // and the docker container lookup are merged in here rather than baked
  // into rawPorts at scan time since they come from separate,
  // independently-timed Processes that can finish before or after the main
  // port scan on any given refresh.
  readonly property var ports: {
    var filtered = hideUnknown
      ? rawPorts.filter(function(p) { return p.process !== "unknown" || root.dockerContainers[String(p.port)] })
      : rawPorts
    return filtered.map(function(p) {
      var rate = p.proto === "tcp" ? root.trafficRates[String(p.port)] : undefined
      var merged = {}
      for (var key in p) merged[key] = p[key]
      merged.display = root.describeProcess(p.process, p.port) + (p.pid ? " (" + p.pid + ")" : "")
      merged.inRate = rate ? rate.inRate : null
      merged.outRate = rate ? rate.outRate : null
      merged.unexpected = root.isUnexpected(p.port)
      return merged
    })
  }
  readonly property int portCount: ports.length

  readonly property real protoColWidth: Style.space(40)
  readonly property real portColWidth: Style.space(50)
  readonly property real scopeColWidth: Style.space(14)
  // Collapses to 0 (rather than sitting empty) when nothing currently
  // visible has a rate to show — a TCP port with no established connection
  // and every UDP port both always land here, which is the common case, so
  // reserving 90 units of dead space by default left the PROCESS column
  // more cramped than it needed to be.
  readonly property bool hasAnyTraffic: root.ports.some(function(p) { return p.inRate !== null })
  readonly property real trafficColWidth: hasAnyTraffic ? Style.space(90) : 0

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

  // A user-maintained allowlist, off by default (empty string). Persisted
  // the same way as hideUnknown. Deliberately port-number-only, not
  // proto-aware (an entry matches a port on any protocol) — the same
  // "close enough, and much easier to type" tradeoff trafficRates already
  // makes by keying on port alone.
  readonly property string expectedPortsRaw: setting("expectedPorts", "")

  function setExpectedPorts(raw) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.expectedPorts = raw
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // null (not an empty object) means "no allowlist configured" — the
  // feature is off and nothing gets flagged, rather than an empty list
  // making every single port look unexpected the moment someone installs
  // the plugin without touching this setting.
  readonly property var expectedPortSet: {
    var raw = String(root.expectedPortsRaw || "").trim()
    if (raw.length === 0) return null
    var set = {}
    var parts = raw.split(",")
    for (var i = 0; i < parts.length; i++) {
      var n = parseInt(parts[i].trim(), 10)
      if (isFinite(n) && n > 0) set[String(n)] = true
    }
    return set
  }

  function isUnexpected(port) {
    return root.expectedPortSet !== null && root.expectedPortSet[String(port)] !== true
  }

  // Persistent, not a one-time badge like hasNewPort: as long as an
  // unexpected port stays open, this stays true — there's no separate
  // "seen" state to track, since adding the port to the allowlist below is
  // itself the acknowledgment.
  readonly property bool hasUnexpectedPort: root.ports.some(function(p) { return p.unexpected })

  // Badge on the bar icon (reusing BarIconButton's built-in active/urgent
  // color, the same mechanism first-party widgets use) for a port that
  // wasn't there on the previous scan — lets a new dev server or container
  // catch your eye without needing the popup open. null (not an empty
  // object) means "no scan yet", so the very first scan never notifies.
  property var seenPortKeys: null
  property bool hasNewPort: false

  // entry.display is derived from the owning process's name, which any
  // unprivileged local process can set to arbitrary text via
  // prctl(PR_SET_NAME) — confirmed directly, both that ss reports it
  // verbatim and that this system's notification daemon actually
  // interprets a markup subset in the body text (a literal "<b>" made text
  // bold; an "<img>" tag was silently consumed). Escaping the three
  // markup-special characters before it ever reaches notify-send means a
  // crafted process name is displayed as the literal text it is instead of
  // being interpreted.
  function escapeNotifyMarkup(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function notifyNewPort(entry) {
    if (!bar) return
    var title = entry.unexpected ? "OmaPorts — unexpected port" : "OmaPorts"
    var lead = entry.unexpected ? "Not on your expected list: " : "New port: "
    bar.run("notify-send " + Util.shellQuote(title)
      + " " + Util.shellQuote(lead + entry.proto.toUpperCase() + " " + entry.port + " — " + escapeNotifyMarkup(entry.display)))
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
    // Checked first, ahead of the raw process name: a port docker-proxy
    // (root-owned) is forwarding is invisible to ss's process attribution
    // for an unprivileged caller either way, so it always lands here as
    // "unknown" from ss's own perspective — the docker lookup is strictly
    // more informative than either the raw name or the well-known-port
    // guess below when it has an answer.
    var container = root.dockerContainers[String(port)]
    if (container) return container + " (docker)"
    if (procName !== "unknown") return procName
    // "unknown — Printing (IPP)?" rather than the nested "unknown (Printing
    // (IPP)?)" — a guess like Printing/DHCP/DNS already has its own
    // parenthetical, and nesting a second pair around it both reads oddly
    // and truncates badly (elided mid-open-paren) in the row's fixed width.
    var guess = wellKnownPortName(port)
    return guess ? "unknown — " + guess + "?" : "unknown"
  }

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { popup.open = !popup.open }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
    if (!trafficProc.running) trafficProc.running = true
    if (!dockerProc.running) dockerProc.running = true
  }

  // TCP-only, current-user-owned ports only: the kernel exposes per-socket
  // cumulative byte counters (bytes_sent/bytes_received) through ss without
  // root for sockets this process can already see, but UDP sockets carry no
  // equivalent counter, and a listening port owned by another user (system
  // services — same "unknown" cases everywhere else in this plugin) simply
  // won't appear in this scan either, so it silently gets no rate rather
  // than a password prompt. previousTraffic holds the last sample's
  // cumulative totals per port so updateTraffic can turn "totals since the
  // connection opened" into "bytes per second since the last poll".
  property var previousTraffic: ({})
  property var trafficRates: ({})

  function updateTraffic(text) {
    var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
    var now = Date.now()
    var current = {}
    var rates = {}
    var prev = root.previousTraffic
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 3) continue
      var port = parts[0]
      var sent = parseInt(parts[1], 10)
      var recv = parseInt(parts[2], 10)
      if (!isFinite(sent) || !isFinite(recv)) continue
      current[port] = { sent: sent, recv: recv, t: now }
      var p = prev[port]
      // Only a port whose previous sample is still its own baseline (not a
      // brand-new connection since then) yields a rate — otherwise a port
      // that just started a connection would appear to have transferred its
      // entire history in the last few seconds. A byte count going
      // backwards (the old connection closed and a new one reused the same
      // local port between samples) is treated the same way: no rate this
      // round, rather than a nonsensical negative one.
      if (p && now > p.t && sent >= p.sent && recv >= p.recv) {
        var dt = (now - p.t) / 1000
        rates[port] = { outRate: (sent - p.sent) / dt, inRate: (recv - p.recv) / dt }
      }
    }
    root.previousTraffic = current
    root.trafficRates = rates
  }

  function formatRate(bytesPerSecond) {
    if (bytesPerSecond === null || bytesPerSecond === undefined) return ""
    if (bytesPerSecond < 1) return "0"
    if (bytesPerSecond < 1024) return Math.round(bytesPerSecond) + "B"
    if (bytesPerSecond < 1024 * 1024) return (bytesPerSecond / 1024).toFixed(bytesPerSecond < 10240 ? 1 : 0) + "K"
    return (bytesPerSecond / 1024 / 1024).toFixed(1) + "M"
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
        scope: parts[4] === "exposed" ? "exposed" : "local"
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

  // `ss -tie state established` prints one summary line per TCP connection
  // followed by one tab-indented details line carrying its cumulative
  // bytes_sent/bytes_received — this pairs each details line with the local
  // port from the summary line immediately before it, and sums both across
  // every connection sharing a local port (a busy server can have several
  // established connections on the one listening port at once).
  readonly property string trafficScript:
    "declare -A sent recv\n" +
    "port=\"\"\n" +
    "while IFS= read -r line; do\n" +
    "  if [[ $line == $'\\t'* ]]; then\n" +
    "    if [[ -n \"$port\" ]]; then\n" +
    "      s=0; r=0\n" +
    "      [[ $line =~ bytes_sent:([0-9]+) ]] && s=\"${BASH_REMATCH[1]}\"\n" +
    "      [[ $line =~ bytes_received:([0-9]+) ]] && r=\"${BASH_REMATCH[1]}\"\n" +
    "      sent[$port]=$(( ${sent[$port]:-0} + s ))\n" +
    "      recv[$port]=$(( ${recv[$port]:-0} + r ))\n" +
    "    fi\n" +
    "  else\n" +
    "    localfield=$(awk '{print $3}' <<<\"$line\")\n" +
    "    port=\"${localfield##*:}\"\n" +
    "  fi\n" +
    "done < <(ss -Htie state established 2>/dev/null)\n" +
    "for key in \"${!sent[@]}\"; do\n" +
    "  printf '%s\\t%s\\t%s\\n' \"$key\" \"${sent[$key]}\" \"${recv[$key]:-0}\"\n" +
    "done\n"

  Process {
    id: trafficProc
    command: ["bash", "-c", root.trafficScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateTraffic(text) }
  }

  // Maps a host port to the docker container publishing it. Docker's own
  // port-forwarding process (docker-proxy) normally runs as root, so ss
  // reports these ports to an unprivileged caller with no process
  // attribution at all — confirmed live: `ss -Htulpn` lists the port but
  // omits the users:(()) field entirely, landing in describeProcess's
  // "unknown" bucket the same way any other root-owned service does.
  // Cross-referencing `docker ps` fills that in with the container name,
  // which is more useful than either "unknown" or a well-known-port guess.
  // Requires the current user to reach the docker socket without a
  // password (in the `docker` group, or a rootless Docker setup) — if
  // `docker ps` can't connect, it fails in milliseconds and this plugin
  // silently gets nothing back, the same "never prompts for a password"
  // fallback as every other unattributable port. Docker itself restricts
  // container names to [a-zA-Z0-9_.-], so unlike a process name (settable
  // to anything via prctl(PR_SET_NAME)), a container name can't smuggle a
  // tab or newline into this script's own TSV parsing.
  property var dockerContainers: ({})

  function updateDockerContainers(text) {
    var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
    var map = {}
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 2) continue
      map[parts[0]] = parts[1]
    }
    root.dockerContainers = map
  }

  // `docker ps --format` gives one line per container; its Ports field can
  // list several comma-separated mappings (dual-stack IPv4/IPv6 publish the
  // same host port twice, e.g. "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp")
  // and can include ports that aren't published to the host at all (just
  // "5432/tcp", no "->" — deliberately skipped, since that's not a host
  // listening port ss would ever see). `>` must be backslash-escaped inside
  // `[[ =~ ]]` here — confirmed directly: without it bash parses the bare
  // `>` as redirection syntax and throws a syntax error rather than treating
  // it as a literal regex character.
  readonly property string dockerScript:
    "command -v docker >/dev/null 2>&1 || exit 0\n" +
    "timeout 2 docker ps --format '{{.Names}}\\t{{.Ports}}' 2>/dev/null | while IFS=$'\\t' read -r name ports; do\n" +
    "  IFS=',' read -ra mappings <<< \"$ports\"\n" +
    "  for m in \"${mappings[@]}\"; do\n" +
    "    m=\"${m# }\"\n" +
    "    if [[ $m =~ ^.*:([0-9]+)-\\>[0-9]+/(tcp|udp)$ ]]; then\n" +
    "      printf '%s\\t%s\\n' \"${BASH_REMATCH[1]}\" \"$name\"\n" +
    "    fi\n" +
    "  done\n" +
    "done\n"

  Process {
    id: dockerProc
    command: ["bash", "-c", root.dockerScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateDockerContainers(text) }
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
    // hasUnexpectedPort is included too so a port outside the allowlist
    // keeps the icon flagged for as long as it's open, not just until the
    // popup is next opened.
    active: root.hasNewPort || root.hasUnexpectedPort
    onPressed: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: popup.fittedContentWidth(Style.space(400))
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

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Expected ports"
            opacity: 0.8
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: expectedPortsField
            width: parent.width
            text: root.expectedPortsRaw
            placeholderText: "e.g. 22, 80, 443, 3000 — blank turns this off"
            foreground: root.foreground
            // Committed on blur/Enter (editingFinished), not per keystroke —
            // this writes to shell.json, and re-parsing/re-flagging every
            // row on every keypress would be both wasteful and would fight
            // the user mid-edit if a scan lands while they're still typing.
            onEditingFinished: root.setExpectedPorts(text)
          }

          Text {
            visible: root.expectedPortSet !== null
            width: parent.width
            text: "Port numbers in the flagged color below aren't on this list"
            opacity: 0.6
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
                inRate: modelData.inRate
                outRate: modelData.outRate
                unexpected: modelData.unexpected
              }
            }
          }

          Row {
            id: exposedLegend
            width: parent.width
            visible: root.ports.some(function(p) { return p.scope === "exposed" })
            spacing: Style.space(10)

            // Same Item width and Rectangle styling as the scope dot in
            // PortRow below, so this legend dot lines up in the same
            // column as the real ones instead of just being a "●"
            // character glued to the front of the caption text.
            Item {
              width: root.scopeColWidth
              height: legendText.implicitHeight

              Rectangle {
                width: Style.space(8)
                height: Style.space(8)
                radius: width / 2
                anchors.centerIn: parent
                color: root.bar ? root.bar.urgent : Color.urgent
              }
            }

            Text {
              id: legendText
              width: exposedLegend.width - root.scopeColWidth - exposedLegend.spacing
              text: "reachable from your network, not just this PC"
              opacity: 0.6
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: root.hasAnyTraffic
            text: "NET shows live throughput only while a TCP connection is actively transferring — blank means nothing is moving right now, not that it's broken"
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
      // headerRow.spacing is only added between visible children, so the
      // gap count drops from 4 to 3 when the NET column is collapsed —
      // matching that here is what lets this column actually reclaim the
      // freed width instead of leaving it as a trailing empty margin.
      width: Math.max(Style.space(20), headerRow.width - root.portColWidth - root.protoColWidth - root.scopeColWidth - root.trafficColWidth - headerRow.spacing * (root.hasAnyTraffic ? 4 : 3))
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
    Text {
      visible: root.hasAnyTraffic
      text: "NET"
      width: root.trafficColWidth
      horizontalAlignment: Text.AlignRight
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
    property var inRate: null
    property var outRate: null
    property bool unexpected: false

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
        // opacity, not visible: an invisible item is skipped by layout
        // calculations, which was shifting every following column left on
        // "local" rows where this dot has nothing to show.
        opacity: portRow.scope === "exposed" ? 1 : 0
        color: root.bar ? root.bar.urgent : Color.urgent
      }
    }
    Text {
      // portRow.display is derived from the owning process's name, which
      // ss reports verbatim from the kernel — and any unprivileged local
      // process can set that name to arbitrary text via prctl(PR_SET_NAME),
      // confirmed directly (a process named "<img src=x>evil" shows up in
      // ss's output exactly like that). PlainText so a markup-shaped
      // process name is never parsed as rich text by Qt's default AutoText
      // detection, only ever displayed as the literal string it is.
      textFormat: Text.PlainText
      text: portRow.display
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(20), portRow.width - root.portColWidth - root.protoColWidth - root.scopeColWidth - root.trafficColWidth - portRow.spacing * (root.hasAnyTraffic ? 4 : 3))
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
      // Flags a port outside the configured allowlist (root.expectedPortSet
      // === null means the feature is off, in which case unexpected is
      // always false — see isUnexpected). Same urgent color the exposed-
      // network dot already uses, so "needs attention" reads consistently.
      color: portRow.unexpected ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground
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
    Text {
      // Blank for UDP (no per-socket byte counters available at all) and
      // for a TCP port with no rate yet — either it just appeared and has
      // no prior sample to diff against, or it currently has no established
      // connections to measure. Not "0B/s": that would claim a
      // known-zero rate rather than "nothing measurable right now".
      visible: root.hasAnyTraffic
      text: portRow.inRate !== null ? ("↓" + root.formatRate(portRow.inRate) + " ↑" + root.formatRate(portRow.outRate)) : ""
      width: root.trafficColWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      opacity: 0.7
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
