# Dotfiles — Sonny's NixOS Configuration

NixOS + MangoWM desktop environment.
Tiling window manager with first-class Wayland support, curated tools, and
extensive keybindings.

## At a Glance

| Thing        | What                                                              |
| ------------ | ----------------------------------------------------------------- |
| **OS**       | NixOS (unstable)                                                  |
| **WM**       | [MangoWM](https://github.com/mangowm/mangowm) — tiling compositor |
| **Bar**      | Waybar (bottom dock)                                              |
| **Terminal** | Foot + tmux                                                       |
| **Editor**   | Zed / Neovim                                                      |
| **Shell**    | Fish + Starship prompt                                            |
| **Launcher** | Fuzzel (Catppuccin Mocha)                                         |
| **Theme**    | Catppuccin Mocha (Stylix)                                         |

## Keybinding Cheat Sheet

> **SUPER** = Windows key | **Return** = Enter | **Print** = PrtScrn

### Window Management

| Keys                         | Action                              |
| ---------------------------- | ----------------------------------- |
| `SUPER` + `Return`           | Open terminal (foot)                |
| `SUPER` + `Shift` + `Return` | Open large terminal                 |
| `ALT` + `Return`             | Open floating terminal              |
| `ALT` + `z`                  | Toggle dropdown scratchpad terminal |
| `SUPER` + `q`                | Kill focused window                 |
| `SUPER` + `Shift` + `q`      | Force kill window                   |
| `SUPER` + `Space`            | Toggle floating                     |
| `ALT` + `\`                  | Toggle floating                     |
| `SUPER` + `f`                | Toggle maximize (keep bar visible)  |
| `SUPER` + `Shift` + `f`      | Toggle fullscreen                   |
| `ALT` + `f`                  | Toggle fake fullscreen              |

### Focus Navigation

| Keys                         | Action                     |
| ---------------------------- | -------------------------- |
| `ALT` + `←↑↓→`               | Move focus between windows |
| `SUPER` + `Shift` + `←↑↓→`   | Swap windows               |
| `SUPER` + `btn_left` (drag)  | Move floating window       |
| `SUPER` + `btn_right` (drag) | Resize floating window     |

### Resize & Move (Keyboard)

| Keys                      | Action                       |
| ------------------------- | ---------------------------- |
| `CTRL` + `ALT` + `←↑↓→`   | Resize window by 50px        |
| `CTRL` + `Shift` + `←↑↓→` | Move floating window by 50px |

### Tags (Workspaces)

Mango uses **tags** (1–9) instead of workspaces. Windows can be on multiple tags.

| Keys                         | Action                                |
| ---------------------------- | ------------------------------------- |
| `SUPER` + `1`–`9`            | Switch to tag                         |
| `SUPER` + `←` / `→`          | Previous / next tag                   |
| `SUPER` + `ALT` + `1`–`9`    | Move window to tag (and follow)       |
| `CTRL` + `SUPER` + `←` / `→` | Move window to prev/next tag silently |
| `SUPER` + `CTRL` + `←` / `→` | Focus prev/next monitor               |
| `SUPER` + `ALT` + `←` / `→`  | Move window to prev/next monitor      |

**Tag layout:**

| Tag | Monitor             | Purpose             |
| --- | ------------------- | ------------------- |
| 1   | HDMI-A-1 (external) | Work                |
| 2   | eDP-1 (laptop)      | Primary             |
| 3   | DP-1 (external)     | Secondary work      |
| 4–9 | Any                 | Free / special apps |

### Layout

| Keys          | Action                               |
| ------------- | ------------------------------------ |
| `SUPER` + `n` | Switch layout (tile → vertical_tile) |
| `SUPER` + `j` | Switch layout (reverse)              |

Mango supports `tile` (master-stack, horizontal split) and `vertical_tile`.
Master factor: 55% (set via `default_mfact`).

### Launching Apps

| Keys                         | Action                        |
| ---------------------------- | ----------------------------- |
| `SUPER` + `a`                | App launcher (fuzzel)         |
| `SUPER` + `v`                | Clipboard history             |
| `SUPER` + `w`                | Wallpaper picker              |
| `SUPER` + `x`                | Browser (Zen)                 |
| `SUPER` + `c`                | Editor (Zed)                  |
| `SUPER` + `e`                | File manager (PCManFM)        |
| `SUPER` + `Shift` + `e`      | Terminal file manager (yazi)  |
| `SUPER` + `m`                | Spotify                       |
| `SUPER` + `b`                | Bluetooth manager (bluetuith) |
| `SUPER` + `F1`               | Show keybinding cheatsheet    |
| `SUPER` + `Escape`           | Lock screen                   |
| `SUPER` + `Shift` + `Escape` | Shutdown menu                 |

### Screenshots

| Keys                               | Mode                        | Output             |
| ---------------------------------- | --------------------------- | ------------------ |
| `Print`                            | Select area                 | Clipboard only     |
| `SUPER` + `Print`                  | Select area                 | File + clipboard   |
| `SUPER` + `Shift` + `Print`        | Select area → edit          | File (opens satty) |
| `CTRL` + `Print`                   | Full screen                 | File               |
| `SUPER` + `CTRL` + `Print`         | **Freeze** → select area    | File + clipboard   |
| `SUPER` + `ALT` + `Print`          | **Record GIF** (start/stop) | File + clipboard   |
| `SUPER` + `CTRL` + `ALT` + `Print` | **Stop GIF** recording      | File + clipboard   |

All screenshots save to `~/Pictures/Screenshots/`.

#### Freeze Mode

`SUPER` + `CTRL` + `Print` freezes the entire screen first, then lets you select
an area. Use this for capturing:

- Right-click context menus
- Tooltips / hover states
- Frame-perfect game moments
- Anything that would disappear on key press

#### GIF Recording

`SUPER` + `ALT` + `Print` starts recording a GIF of a selected area.
`SUPER` + `CTRL` + `ALT` + `Print` stops recording and converts to GIF.
The GIF is saved and copied to clipboard.

### Media & Hardware

| Keys                     | Action                                  |
| ------------------------ | --------------------------------------- |
| Media keys (`🔊🔉🔇⏯⏭⏮`) | Volume / playback (handled by hardware) |
| `SUPER` + `k`            | Toggle keyboard layout (US ↔ NO)        |
| Brightness keys          | Screen brightness                       |
| `ALT` + scroll wheel     | Screen brightness                       |
| `SUPER` + `Shift` + `h`  | Switch GPU mode (hybrid)                |

## Tools & Workflow

### Fuzzel — App Launcher

Catppuccin Mocha themed launcher. Fuzzy matching, shows desktop entries + PATH
executables. Toggle with `SUPER` + `a` or click the 󰣇 icon on the bar.

- **Left-click bar icon**: Toggle app launcher
- **Middle-click bar icon**: Clipboard history
- **Right-click bar icon**: Wallpaper picker

### Yazi — Terminal File Manager

`SUPER` + `Shift` + `e` launches yazi. Fast, keyboard-driven file manager with:

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
- Dropdown scratchpad with `ALT` + `z`

### tmux — Terminal Multiplexer

Persistent sessions, split panes, pi integration. Prefix: `Ctrl` + `a`.

- `Ctrl+a \|` — vertical split
- `Ctrl+a -` — horizontal split
- `Ctrl+a c` — new window
- `Ctrl+a 1-9` — switch window

### Waybar — Status Bar

Bottom bar showing:

- **Left**: Power menu, workspaces, launcher, taskbar
- **Center**: Clock, pomodoro timer
- **Right**: System tray, battery, VPN, network, Bluetooth, audio

### Wallpaper

`SUPER` + `w` opens the wallpaper picker. Wallpapers live in
`~/.dotfiles/wallpapers/`. Selecting one applies it and saves it as
your default — restored on every login. The saved path lives in
`~/.dotfiles/wallpapers/.default` (gitignored).

## Custom Scripts

| Script                 | What it does                                   |
| ---------------------- | ---------------------------------------------- |
| `wallpaper-picker`     | Browse and set wallpapers                      |
| `wall-change [file]`   | Set wallpaper (no arg = restore saved default) |
| `screenshot-*`         | Various screenshot modes                       |
| `fuzzel-drun`          | Toggle app launcher                            |
| `fuzzel-clipboard`     | Clipboard history picker                       |
| `fuzzel-wallpaper`     | Toggle wallpaper picker                        |
| `show-keybinds`        | Display keybinding cheatsheet                  |
| `toggle_keyboard`      | Switch US ↔ Norwegian layout                   |
| `toggle_vpn`           | Toggle WireGuard VPN                           |
| `set-gpu-hybrid`       | Switch to hybrid GPU mode                      |
| `shutdown-script`      | Shutdown/reboot/logout menu                    |
| `extract` / `compress` | Archive extraction and compression             |
| `lofi`                 | Play lofi music stream                         |

## NixOS Management

```fish
# Rebuild and switch
nswitchu           # nixos-rebuild switch --flake ~/.dotfiles/nixos#sonny-laptop

# Update flake inputs
update_dotfiles    # commit + push dotfiles
update_dotfiles "message"  # with custom commit message

# Garbage collect
nix-collect-garbage -d
```

## Known Issues

### NVIDIA driver/library version mismatch after kernel bump

When `nixos-unstable` bumps both the Linux kernel and NVIDIA driver,
`nswitchu` may fail to install new bootloader entries. Symptoms:

- `nvidia-smi` fails with `Driver/library version mismatch`
- `nswitchu` activation fails on `nvidia-container-toolkit-cdi-generator.service`
- `uname -r` shows old kernel despite having activated the new config

**Fix:**

```fish
sudo nixos-rebuild boot --flake ~/.dotfiles/nixos#sonny-laptop
systemctl reboot
```

See `.pi/skills/nixos-kernel-bump/SKILL.md` for full diagnosis steps.

## Bootstrapping a New Machine

This setup uses **sops-nix** with **Age** encryption for all secrets (SSH keys,
AWS credentials, API tokens, user password). Your master Age key lives in
**Bitwarden** so you can decrypt everything on a fresh install.

### Prerequisites (one-time)

Store these in your Bitwarden vault:

| Bitwarden Item Name | Type        | Contents                                   |
| ------------------- | ----------- | ------------------------------------------ |
| `github-ssh-key`    | Secure Note | Your private SSH key (`~/.ssh/id_ed25519`) |
| `sops-age-key`      | Secure Note | Contents of `~/.config/sops/age/keys.txt`  |

### Fresh Machine Bootstrap

On a brand-new NixOS system (TTY or minimal terminal):

```bash
# 1. Start a temp shell with Bitwarden CLI
nix-shell -p bitwarden-cli

# 2. Log in to Bitwarden and unlock
bw login
export BW_SESSION="$(bw unlock --raw)"

# 3. Restore your SSH key (the repo is private, so you need this to clone)
mkdir -p ~/.ssh
bw get notes "github-ssh-key" > ~/.ssh/id_ed25519
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519

# 4. Clone the dotfiles repo over SSH
git clone git@github.com:snorreks/.dotfiles.git ~/.dotfiles

# 5. Restore your sops Age key (so NixOS can decrypt secrets)
mkdir -p ~/.config/sops/age
bw get notes "sops-age-key" > ~/.config/sops/age/keys.txt
chmod 700 ~/.config/sops/age
chmod 600 ~/.config/sops/age/keys.txt

# 6. Exit the temp shell
exit

# 7. Rebuild — sops-nix decrypts SSH keys, AWS, passwords automatically.
# `nh os switch` with no #attr auto-targets whatever networking.hostName the
# machine currently has — which on a brand-new install is NOT set yet, so
# you must name the flake output explicitly this one time:
#   - Legion:  nh os switch ~/.dotfiles/nixos#sonny-laptop
#   - GS65:    nh os switch ~/.dotfiles/nixos#gs65
nh os switch ~/.dotfiles/nixos#sonny-laptop   # or #gs65
```

After this first build, `networking.hostName` matches the flake output you
chose, so every later rebuild (`nswitchu`, `nswitch-fast`, etc.) auto-detects
the right host with no `#attr` needed.

If the GS65's `nixos/hosts/gs65/hardware.nix` and `options.nix` still have
their `TODO` placeholders (bus IDs, disk UUIDs), fill those in before running
step 7 there — see the comments in those files.

After this first build, `bitwarden-cli` is installed system-wide and you can
use the `fetch_sops_key` fish function to restore your Age key on future
rebuilds.

### Restoring the Age Key Later

```fish
fetch_sops_key   # pulls sops-age-key from your Bitwarden vault
```

### Shared NTFS Steam Library Setup

If using a dual-boot shared NTFS drive for Steam games (`/mnt/shared`), Proton prefixes (`compatdata`) **must** live on your native Linux filesystem (`ext4`) to support POSIX symlinks.

1. Mount the partition via `ntfs3` or `ntfs-3g` in NixOS.
2. Link the `compatdata` directory to your home folder:

```bash
mkdir -p ~/.local/share/Steam/steamapps/compatdata
rm -rf /mnt/shared/SteamLibrary/steamapps/compatdata
ln -s ~/.local/share/Steam/steamapps/compatdata /mnt/shared/SteamLibrary/steamapps/compatdata
```

## File Structure

```

~/.dotfiles/
├── .sops.yaml # sops encryption rules
├── nixos/
│ ├── flake.nix
│ ├── flake.lock
│ ├── secrets.yaml # Encrypted secrets (sops + Age)
│ ├── options.nix
│ ├── system.nix
│ ├── hosts/
│ │ └── sonny-laptop/ # Hardware configs
│ └── config/
│ ├── home/
│ │ ├── mango/ # Window manager
│ │ ├── waybar/ # Status bar
│ │ ├── foot.nix # Terminal
│ │ ├── fuzzel.nix # Launcher
│ │ ├── fish/ # Shell + functions
│ │ ├── theme/ # GTK + Stylix
│ │ ├── scripts/ # Custom scripts
│ │ ├── packages.nix # User packages
│ │ └── ... # Other app configs
│ └── system/ # System-level configs
└── wallpapers/ # Wallpaper collection (WebP)


```
