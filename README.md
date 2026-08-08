# Dotfiles — Sonny's NixOS Configuration

A fully declarative, flake-based NixOS setup: MangoWM tiling on Wayland, hybrid Intel+NVIDIA graphics,
sops-managed secrets, an impermanence-ready disk layout, and a genuinely
AI-agent-heavy dev workflow.

## The Stack

### Core

| Thing        | What                                                                                           |
| ------------ | ---------------------------------------------------------------------------------------------- |
| **OS**       | NixOS (unstable), flake-based, 2 hosts                                                         |
| **Disk**     | btrfs, disko-ready, [impermanence](https://github.com/nix-community/impermanence)-capable root |
| **Secrets**  | [sops-nix](https://github.com/Mic92/sops-nix) + Age, Bitwarden bootstrap                       |
| **Rebuilds** | [`nh`](https://github.com/nix-community/nh)                                                    |

### Desktop

| Thing             | What                                                                                |
| ----------------- | ----------------------------------------------------------------------------------- |
| **WM**            | [MangoWM](https://github.com/mangowm/mangowm) — tiling compositor, Wayland          |
| **Bar**           | Waybar                                                                              |
| **Launcher**      | Fuzzel                                                                              |
| **Notifications** | Mako                                                                                |
| **Lock / Logout** | swaylock / wlogout                                                                  |
| **Theme**         | Stylix (base16) + adw-gtk3 + Papirus-Dark + Nordzy cursor + JetBrainsMono Nerd Font |

### Terminal & Shell

| Thing           | What                   |
| --------------- | ---------------------- |
| **Terminal**    | foot                   |
| **Multiplexer** | herdr                  |
| **Shell**       | fish + Starship prompt |

### Editor & Files

| Thing                | What           |
| -------------------- | -------------- |
| **Editor**           | Zed (+ Neovim) |
| **GUI file manager** | PCManFM        |
| **TUI file manager** | yazi           |

### Browsers & Communication

| Thing        | What                                                 |
| ------------ | ---------------------------------------------------- |
| **Browsers** | Zen (default), Brave, Chrome                         |
| **Email**    | Thunderbird                                          |
| **Chat**     | Discord (Vesktop, themed), Slack, Telegram, WhatsApp |

### Media & Gaming

| Thing         | What                                                 |
| ------------- | ---------------------------------------------------- |
| **Music**     | Spotify                                              |
| **Gaming**    | Steam, Proton-GE, Gamescope, MangoHud, PrismLauncher |
| **Emulation** | PS4 emulation (Bloodborne) + BBLauncher mods         |

### Dev & AI Tools

| Thing                 | What                                                                                                                                      |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Runtime & tooling** | bun, `gh`, `gcloud`, direnv, nixd, alejandra                                                                                              |
| **AI coding agents**  | `pi`, Claude Code, Gemini CLI, `opencode`, jules, vibe-kanban, workmux, coderabbit-cli, agent-browser, openspec, backlog-md, ccusage, rtk |

### Networking

| Thing   | What                                      |
| ------- | ----------------------------------------- |
| **VPN** | Proton VPN over WireGuard, one-key toggle |

## Docs

| Doc                                                                  | What it covers                                                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [`docs/keybindings.md`](./docs/keybindings.md)                       | Full keybinding cheat sheet + per-tool usage notes                                                            |
| [`docs/bootstrap.md`](./docs/bootstrap.md)                           | Fresh machine setup, Bitwarden/sops bootstrap, GS65 first install, using **disko** for a from-scratch install |
| [`docs/impermanence-migration.md`](./docs/impermanence-migration.md) | Converting an existing (already-installed, dual-boot) disk to the impermanence layout in place                |
| [`docs/forking.md`](./docs/forking.md)                               | Adapting this repo to your own identity, hardware, and accounts                                               |

## NixOS Management

```fish
# Rebuild and switch
nswitchu           # nixos-rebuild switch --flake ~/.dotfiles/nixos#legion

# Update flake inputs
update_dotfiles    # commit + push dotfiles
update_dotfiles "message"  # with custom commit message

# Garbage collect
nix-collect-garbage -d
```

## Hybrid Graphics

Both laptops run Intel iGPU + NVIDIA dGPU via PRIME render offload
(`config/system/intel-nvidia.nix`) — the iGPU handles the desktop by default,
and the dGPU stays powered down until something needs it. To run a specific
app on the NVIDIA GPU:

```fish
prime-run steam
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
sudo nixos-rebuild boot --flake ~/.dotfiles/nixos#legion
systemctl reboot
```

See `.pi/skills/nixos-kernel-bump/SKILL.md` for full diagnosis steps.

## File Structure

```

~/.dotfiles/
├── .sops.yaml # sops encryption rules
├── docs/
│ ├── keybindings.md # Keybinding cheat sheet + usage notes
│ ├── bootstrap.md # New machine setup + disko usage
│ ├── impermanence-migration.md # Migrating an existing install
│ └── forking.md # Adapting this repo to your own setup
├── nixos/
│ ├── flake.nix
│ ├── flake.lock
│ ├── secrets.yaml # Encrypted secrets (sops + Age)
│ ├── options.nix
│ ├── system.nix
│ ├── hosts/
│ │ └── legion/ # Hardware configs
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
