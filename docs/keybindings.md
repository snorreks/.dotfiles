# Keybindings & Usage Guide

Full keybinding reference and per-tool usage notes for the MangoWM desktop.
Generated from `nixos/config/home/mango.nix` — if you add/change a binding
there, update this doc to match.
For what the tools actually are, see the [main README](../README.md#the-stack).

> **SUPER** = Windows key | **Return** = Enter | **Print** = PrtScrn

## Window Management

| Keys                         | Action                              |
| ----------------------------- | ------------------------------------ |
| `SUPER` + `r`                 | Reload MangoWM config               |
| `SUPER` + `Return`            | Open terminal (foot)                |
| `CTRL` + `Return`             | Open a new floating terminal        |
| `SUPER` + `Shift` + `Return`  | Open large terminal                 |
| `ALT` + `z`                   | Toggle dropdown scratchpad terminal |
| `SUPER` + `q`                 | Kill focused window                 |
| `SUPER` + `Shift` + `q`       | Force kill window                   |
| `SUPER` + `Space`             | Toggle floating                     |
| `ALT` + `\`                   | Toggle floating                     |
| `SUPER` + `f`                 | Toggle maximize (keep bar visible)  |
| `SUPER` + `Shift` + `f`       | Toggle fullscreen                   |
| `ALT` + `f`                   | Toggle fake fullscreen              |
| `SUPER` + `s`                 | Restore minimized window            |
| `SUPER` + `Shift` + `s`       | Minimize focused window             |

## Focus Navigation

| Keys                         | Action                     |
| ----------------------------- | --------------------------- |
| `ALT` + `←↑↓→`                | Move focus between windows |
| `SUPER` + `Shift` + `←↑↓→`    | Swap windows               |
| `SUPER` + `btn_left` (drag)   | Move floating window       |
| `SUPER` + `btn_right` (drag)  | Resize floating window     |

## Resize & Move (Keyboard)

| Keys                       | Action                       |
| --------------------------- | ----------------------------- |
| `CTRL` + `ALT` + `←↑↓→`     | Resize window by 50px        |
| `CTRL` + `Shift` + `←↑↓→`   | Move floating window by 50px |

## Tags (Workspaces)

Mango uses **tags** (1–9) instead of workspaces. Windows can be on multiple tags.

| Keys                          | Action                                       |
| ------------------------------ | ---------------------------------------------- |
| `SUPER` + `1`–`9`             | Switch to tag                                |
| `SUPER` + `←` / `→`           | Previous / next tag                          |
| `SUPER` + scroll wheel        | Previous / next tag (only if it has a client) |
| `SUPER` + `ALT` + `1`–`9`     | Move window to tag (and follow)              |
| `CTRL` + `SUPER` + `←` / `→`  | Move window to prev/next tag silently        |
| `SUPER` + `CTRL` + `←` / `→`  | Focus prev/next monitor                      |
| `SUPER` + `CTRL` + scroll wheel | Focus prev/next monitor                    |
| `SUPER` + `ALT` + `←` / `→`   | Move window to prev/next monitor             |

**Tag layout:**

| Tag | Monitor             | Purpose             |
| --- | -------------------- | -------------------- |
| 1   | HDMI-A-1 (external) | Work                |
| 2   | eDP-1 (laptop)      | Primary             |
| 3   | DP-1 (external)     | Secondary work      |
| 4–9 | Any                 | Free / special apps |

## Layout

| Keys          | Action                                          |
| ------------- | -------------------------------------------------- |
| `SUPER` + `j` | Switch layout (tile ↔ vertical_tile)             |
| `SUPER` + `n` | Cycle focused window through the stack            |

Mango supports `tile` (master-stack, horizontal split) and `vertical_tile`.
Master factor: 55% (set via `default_mfact`).

## Launching Apps

| Keys                         | Action                        |
| ----------------------------- | ------------------------------ |
| `SUPER` + `a`                 | App launcher (fuzzel)         |
| `SUPER` + `v`                 | Clipboard history             |
| `SUPER` + `w`                 | Wallpaper picker              |
| `SUPER` + `x`                 | Browser (Zen)                 |
| `SUPER` + `c`                 | Editor (Zed)                  |
| `SUPER` + `e`                 | File manager (PCManFM)        |
| `SUPER` + `y`                 | Terminal file manager (yazi)  |
| `SUPER` + `m`                 | Spotify                       |
| `SUPER` + `b`                 | Bluetooth manager (bluetuith) |
| `SUPER` + `Shift` + `d`       | Discord                       |
| `SUPER` + `Shift` + `F2`      | SoundWireServer                |
| `SUPER` + `F1`                | Show keybinding cheatsheet    |
| `SUPER` + `Escape`            | Lock screen                   |
| `SUPER` + `Shift` + `Escape`  | Shutdown menu                 |
| `SUPER` + `Shift` + `b`       | Restart Waybar                |
| `CTRL` + `Shift` + `Delete`   | Clear terminal scrollback     |
| `SUPER` + `k`                 | Toggle keyboard layout (US ↔ NO) |
| `SUPER` + `h`                 | Hearthstone combat-skip (drops network 6s — niche gaming trick, see `hs-skip.sh`) |

## Emergency / Kill Switch

Bound to a dedicated "process gone wrong" panic key, backed by `kill-switch.sh`:

| Keys                                | Mode      | What it does                                                                                   |
| -------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------- |
| `SUPER` + `Shift` + `Delete`         | `--light` | Kills runaway dev/build processes (node, bun, vite, cargo, WebKit/Tauri) — never touches browsers, Discord, Spotify |
| `SUPER` + `CTRL` + `Shift` + `Pause` | `--full`  | Kills all non-essential user apps, including browsers — desktop itself (Mango, Waybar, Pipewire) survives |
| `SUPER` + `CTRL` + `ALT` + `Pause`   | `--reboot`| Reboots the machine — recovery path for a GPU/system hang                                       |

## Screenshots

| Keys                               | Mode                        | Output             |
| ------------------------------------ | ----------------------------- | -------------------- |
| `Print`                            | Select area                 | Clipboard only     |
| `SUPER` + `Print`                  | Select area                 | File + clipboard   |
| `SUPER` + `Shift` + `Print`        | Select area → edit          | File (opens satty) |
| `CTRL` + `Print`                   | Full screen                 | File               |
| `SUPER` + `CTRL` + `Print`         | **Freeze** → select area    | File + clipboard   |
| `SUPER` + `ALT` + `Print`          | **Record GIF** (toggle: press to start, press again to stop) | File + clipboard   |

All screenshots save to `~/Pictures/Screenshots/`.

### Freeze Mode

`SUPER` + `CTRL` + `Print` freezes the entire screen first, then lets you select
an area. Use this for capturing:

- Right-click context menus
- Tooltips / hover states
- Frame-perfect game moments
- Anything that would disappear on key press

### GIF Recording

`SUPER` + `ALT` + `Print` is a single toggle: the first press selects an area
and starts recording, the second press stops it and converts to GIF. The GIF
is saved to `~/Pictures/Screenshots/` and copied to clipboard.

## Monitor Rotation

| Keys                              | Action                          |
| ------------------------------------ | ---------------------------------- |
| `SUPER` + `Shift` + `r`            | Reset DP-1 (ASUS MB16AC) to normal orientation |
| `SUPER` + `Shift` + `ALT` + `r`    | Rotate DP-1 90° (portrait)      |

## Media & Hardware

| Keys                     | Action                                  |
| -------------------------- | ------------------------------------------ |
| Media keys (`🔊🔉🔇⏯⏭⏮`) | Volume / playback (handled by hardware) |
| `Shift` + Mute            | Mute microphone instead of speakers     |
| Brightness keys          | Screen brightness                       |
| `ALT` + scroll wheel     | Screen brightness                       |

## Tools & Workflow

### Fuzzel — App Launcher

Catppuccin Mocha themed launcher. Fuzzy matching, shows desktop entries + PATH
executables. Toggle with `SUPER` + `a` or click the 󰣇 icon on the bar.

- **Left-click bar icon**: Toggle app launcher
- **Middle-click bar icon**: Clipboard history
- **Right-click bar icon**: Wallpaper picker

### Yazi — Terminal File Manager

`SUPER` + `y` launches yazi. Fast, keyboard-driven file manager with:

- `v` — select files (visual mode)
- `y` / `p` — yank/paste
- `Space` — preview
- `r` — rename
- `d` / `u` — delete/undelete

### Zed — Code Editor

`SUPER` + `c` opens or focuses Zed. Fast collaborative editor with Vim mode,
LSP support, and Catppuccin theme.

### Foot — Terminal

Default terminal. Features:

- Sixel image support
- GPU-accelerated rendering
- `foot-big` (SUPER+Shift+Return) for a larger instance
- Dropdown scratchpad with `ALT` + `z` (persistent, toggles hidden/shown)
- `CTRL` + `Return` for a plain new floating instance instead (not the scratchpad)

### Waybar — Status Bar

Bottom bar showing:

- **Left**: Power menu, workspaces, launcher, taskbar
- **Center**: Clock, pomodoro timer
- **Right**: System tray, battery, VPN, network, Bluetooth, audio

`SUPER` + `Shift` + `b` restarts it if it ever gets into a bad state.

### Wallpaper

`SUPER` + `w` opens the wallpaper picker. Wallpapers live in
`~/.dotfiles/wallpapers/`. Selecting one applies it and saves it as
your default — restored on every login. The saved path lives in
`~/.dotfiles/wallpapers/.default` (gitignored).

## Custom Scripts

| Script                 | What it does                                   |
| ------------------------ | ------------------------------------------------- |
| `wallpaper-picker`     | Browse and set wallpapers                      |
| `wall-change [file]`   | Set wallpaper (no arg = restore saved default) |
| `screenshot-*`         | Various screenshot modes                       |
| `fuzzel-drun`          | Toggle app launcher                            |
| `fuzzel-clipboard`     | Clipboard history picker                       |
| `fuzzel-wallpaper`     | Toggle wallpaper picker                        |
| `show-keybinds`        | Display keybinding cheatsheet                  |
| `toggle_keyboard`      | Switch US ↔ Norwegian layout                   |
| `toggle_vpn`           | Toggle WireGuard VPN                            |
| `kill-switch`          | Emergency process killer — see [Emergency / Kill Switch](#emergency--kill-switch) |
| `hs-skip`              | Hearthstone combat-skip network drop           |
| `shutdown-script`      | Shutdown/reboot/logout menu                    |
| `extract` / `compress` | Archive extraction and compression             |
| `lofi`                 | Play lofi music stream                         |
