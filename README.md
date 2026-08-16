# Better Displays

A [Omarchy](https://omarchy.org/) shell plugin that puts **granular display and
terminal control** in a bar widget you open directly from the status bar.

![preview](preview.png)

## Features

- **Per-monitor** resolution (real modes reported by the monitor), scale,
  position (left/right/above/below another display), and orientation
  (0°/90°/180°/270°).
- **Per-terminal font size** for alacritty, kitty, ghostty, and foot, with
  live − / + steppers.
- All changes apply **live** via Hyprland and **persist** to
  `~/.config/omarchy/displays.json` and `~/.config/hypr/monitors.lua` (so they
  survive a reboot).
- A matching `omarchy display ...` CLI group and an interactive Display menu
  submenu (the scripts are installed onto `PATH` automatically).

## Requirements

- Omarchy (Hyprland-based) with the Quickshell shell.
- `bash` and `jq` (both standard on Omarchy).
- `hyprctl` (provided by Hyprland).

## Install

### Via `omarchy plugin add` (recommended)

```bash
omarchy plugin add git@github.com:nightdevil00/better.displays.git --enable
```

This clones the plugin, validates it, and enables the bar widget. When the
shell loads the plugin it **auto-installs the backend scripts** onto `PATH`
(`~/.local/bin`, falling back to `/usr/local/bin`), so the `omarchy display`
CLI group and the Display menu submenu work immediately. No manual step needed.

### Manual

```bash
git clone git@github.com:nightdevil00/better.displays.git \
  ~/.config/omarchy/plugins/better.displays
cd ~/.config/omarchy/plugins/better.displays
./install                 # symlink the backend scripts into ~/.local/bin
omarchy plugin enable better.displays
omarchy restart shell
```

## Use it

- Click the **Better Displays** icon in the bar (next to the monitor icon), or
  summon it: `omarchy-shell shell summon better.displays`.
- Pick a monitor, then adjust Resolution / Scale / Position / Orientation, and
  tune each terminal's font size.

CLI equivalents (interactive shell):

```bash
omarchy display monitor list
omarchy display monitor set DP-1 --mode 2560x1440@144 --scale 1.6 --pos 0x0 --transform 0
omarchy display terminal list
omarchy display terminal set ghostty 14
omarchy display terminal set-all 13
```

## Uninstall

```bash
~/.config/omarchy/plugins/better.displays/uninstall   # drop the PATH symlinks
omarchy plugin remove better.displays
```

(`uninstall` removes the `omarchy-display-*` symlinks; `omarchy plugin remove`
deletes the plugin folder. Order does not matter, but run both for a clean
removal.)

## How it works

The plugin folder bundles everything it needs:

```
better.displays/
├── manifest.json        # plugin metadata (bar-widget)
├── Panel.qml            # the bar widget + popup (reuses Omarchy's qs.Ui kit)
├── bin/                 # backend scripts (self-contained, travel with the plugin)
│   ├── omarchy-display-monitor
│   ├── omarchy-display-terminal
│   └── omarchy-display-pick
├── install              # symlink bin/* into ~/.local/bin (idempotent)
├── uninstall            # remove those symlinks
├── preview.png
└── README.md
```

`Panel.qml` invokes the scripts by their absolute path inside `bin/`, so the
widget works the moment the folder is present — the `install` step only exists
to expose the `omarchy display` CLI / menu.

## License

MIT — do what you like, attribute if you're feeling generous.
