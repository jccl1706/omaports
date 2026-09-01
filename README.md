# omaports

A bar-widget plugin for the [Omarchy](https://omarchy.org) shell that shows
how many local ports are currently in use, and which process owns each one.

## Requirements

- `ss` (from `iproute2`, installed by default on Arch/Omarchy).

## Install

```bash
omarchy plugin add https://github.com/jccl1706/omaports.git --enable --yes
```

Or by hand:

```bash
cp -r . ~/.config/omarchy/plugins/io.github.jccl1706.omaports
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.jccl1706.omaports
```

For local development, a symlink in place of `cp -r` works too, but
`omarchy-shell`'s file watcher does not follow it — after editing QML, run
`omarchy restart shell` rather than relying on hot-reload. Even with a real
(non-symlinked) directory, hot-reload has been observed to pick up layout
changes but keep running a stale version of a changed JS function body in an
already-running widget instance — if behavior doesn't match what you just
edited, restart the shell before assuming the code is wrong.

## Usage

The bar icon shows the number of open ports, refreshed every 30s in the
background and every 4s while the popup is open. Click it for the full list:
process, port number, and protocol.

Ports owned by other users or root (system services like DNS or CUPS) show
as "unknown" — this plugin never asks for a password just to list sockets.
When the port number is a well-known one (53 for DNS, 631 for printing,
etc.), "unknown" gets a guessed hint like `unknown (DNS?)` — the `?` marks
it as an inference from the port number by convention, not something read
from the kernel the way the real process name would be.

A dot next to a row means that port is bound to a real network address
(`0.0.0.0`, `::`, or a specific LAN address) rather than loopback-only —
reachable from other devices on your network, not just this machine. A port
bound to *both* (common for services that also listen on a Docker bridge
address, for example) still gets the dot, since it's exposed either way.

The bar icon highlights and a desktop notification fires when a port opens
that wasn't there on the previous scan — useful for noticing the moment a
dev server or container starts without watching the popup. The highlight
clears the next time you open the popup.

Toggle "Hide unknown services" in the popup to filter the list down to only
processes `ss` could actually name — also available over IPC:
`omarchy-shell io.github.jccl1706.omaports toggleHideUnknown`.

The NET column shows a live `↓in ↑out` throughput for a TCP port with an
active connection right now, sampled once per refresh. It's blank rather
than `0` for anything not currently measurable: UDP ports (no per-socket
byte counters exist for them), a port with no established connections at
the moment, or a port owned by another user/root — the same "unknown"
limitation as the process name, since reading another user's socket
internals needs root and this plugin never asks for a password.

## Removal

```bash
omarchy plugin remove io.github.jccl1706.omaports --yes
```

Or by hand: `omarchy plugin disable io.github.jccl1706.omaports`, then delete
`~/.config/omarchy/plugins/io.github.jccl1706.omaports/`.

## Files

- `manifest.json` — plugin manifest (`kind: bar-widget`)
- `Widget.qml` — the bar icon and popup
- `LICENSE` — MIT

## License

MIT — see [LICENSE](LICENSE).
