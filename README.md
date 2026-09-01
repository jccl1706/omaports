# omaport

A bar-widget plugin for the [Omarchy](https://omarchy.org) shell that shows
how many local ports are currently in use, and which process owns each one.

## Requirements

- `ss` (from `iproute2`, installed by default on Arch/Omarchy).

## Install

```bash
omarchy plugin add https://github.com/jccl1706/omaport.git --enable --yes
```

Or by hand:

```bash
cp -r . ~/.config/omarchy/plugins/io.github.jccl1706.omaport
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.jccl1706.omaport
```

For local development, a symlink in place of `cp -r` works too, but
`omarchy-shell`'s file watcher does not follow it — after editing QML, run
`omarchy restart shell` rather than relying on hot-reload.

## Usage

The bar icon shows the number of open ports, refreshed every 30s in the
background and every 4s while the popup is open. Click it for the full list:
protocol, port number, and the owning process (with its PID).

Ports owned by other users or root (system services like DNS or CUPS) show
as "unknown" — this plugin never asks for a password just to list sockets.

## Removal

```bash
omarchy plugin remove io.github.jccl1706.omaport --yes
```

Or by hand: `omarchy plugin disable io.github.jccl1706.omaport`, then delete
`~/.config/omarchy/plugins/io.github.jccl1706.omaport/`.

## Files

- `manifest.json` — plugin manifest (`kind: bar-widget`)
- `Widget.qml` — the bar icon and popup
- `LICENSE` — MIT

## License

MIT — see [LICENSE](LICENSE).
