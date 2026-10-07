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
| [`docs/headless-server.md`](./docs/headless-server.md)               | Running a host as an always-on, tailnet-only box: `headless = true`, safe remote rebuilds, remote builds      |
| [`docs/agent-operations.md`](./docs/agent-operations.md)               | Agent continuity: herdr lifetime and resume, credential loading via sops, health reporting with redacted output, and restic backup/restore |
| [`docs/media-travel.md`](./docs/media-travel.md)                       | Taking the server on a trip: namespace-confined Jellyfin/qBittorrent, selective media sync, state capture and restore |
| [`docs/mobile-agents.md`](./docs/mobile-agents.md)                   | Reaching the same herdr workspaces and agents from an Android phone (Collie PWA over Tailscale Serve; SSH/Mosh and Termux as fallbacks) |
| [`docs/forking.md`](./docs/forking.md)                               | Adapting this repo to your own identity, hardware, and accounts                                               |

## NixOS Management

```fish
# Update the current machine (only nixpkgs)
nupdate

# Legion: apply edited dotfiles without changing inputs
nswitch           # offline build; guarded activation or staged kernel update
nswitcho          # same, allowing downloads
nconfirm          # confirm after checking a fresh connection, if activated live

# GS65: update the Legion over Tailscale
nupdate legion
nconfirm legion

# Legion compatibility name: update nixpkgs, or one named input
nswitchu          # same as nupdate
nswitchu herdr     # deliberate Herdr input update; does not restart live agents

# Update flake inputs — SCOPED, and always through a reviewable branch
#
# This is no longer "commit + push to master". The old version ran
# `sudo chown -R`, `git add -A` and `git push origin master` on every call, so
# running it to fix a file permission could publish an unrelated file to a
# public repository. It now stages only the paths you name, refuses to work on
# master, and opens a DRAFT pull request.
#
#   update_dotfiles status              what changed, and where we are
#   update_dotfiles branch topic/x      create/switch to a topic branch
#   update_dotfiles stage <path>...     stage ONLY those paths
#   update_dotfiles review              read the staged diff
#   update_dotfiles commit "message"    commit what is staged
#   update_dotfiles pr "title"          push + open a DRAFT PR
#
# There is no "stage everything". `status` lists untracked files so you can name
# them. See nixos/tests/README.md for the tests that enforce this.

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

## Hardware Controls

The dashboard's **System** tab (`SUPER+D`) reaches hardware the generic laptop
stack does not, gated on the device being present rather than the hostname:

- **CPU profile** — power-profiles-daemon's ActiveProfile: Performance /
  Balanced / Power Saver, applied as `intel_pstate` EPP. This is the CPU-side
  policy only. On the Legion PPD is started with
  `--block-driver=platform_profile` (`hosts/legion/power.nix`) so it cannot
  move the EC fan mode; on the GS65 PPD keeps its platform_profile driver.
- **Cooling** — fan mode (a profile) and Cooler Boost (an override that pins
  both fans to max), from whichever EC backend is present. On the GS65 those
  are `msi-ec`'s silent / auto / advanced and `cooler_boost`
  (`hosts/gs65/fan-control.nix`). On the Legion they are the firmware's
  `powermode` — quiet / balanced / performance — and `fan_fullspeed`, via
  `legion-laptop` (`hosts/legion/fan-control.nix`). The Legion's `custom`
  powermode is deliberately not a mode: it is only where the firmware honours
  `fan_fullspeed`, so Cooler Boost enters it internally and restores your
  cooling mode on the way out. Where neither device binds, the card is absent
  rather than empty.

CPU profile and Cooling are independent controls. On the Legion they used to be
the same EC register — `platform_profile` and `powermode` are two doors onto
the firmware's smart-fan mode — so "CPU Performance + quiet fans" was
impossible. Blocking PPD's platform_profile driver fixes that at the ownership
level: PPD owns EPP, `dashboard-fan` owns `powermode`, and neither writes the
other's register.
- **Keyboard light** — colour and brightness for the GS65's SteelSeries per-key
  RGB controller, via `msi-perkeyrgb` (`hosts/gs65/keyboard-rgb.nix`, packaged
  in `pkgs/`). The controller has no brightness register, so brightness scales
  the chosen colour before it is sent; it therefore applies to a steady colour
  and not to the vendor presets, which carry their own colours. Absent on the
  Legion, which has no such controller.

Both machines need one reboot after the rebuild that introduces them: the EC
module has to load, and the udev rules that grant the user access to the EC
attributes and `/dev/hidraw*` only apply from boot. Until then each card says
so instead of silently ignoring clicks.

From the shell:

```fish
dashboard-fan status
dashboard-fan mode silent
dashboard-fan boost toggle

dashboard-kbd presets      # all nine vendor presets
dashboard-kbd color ff0000
dashboard-kbd brightness 40
dashboard-kbd preset rainbow-split
dashboard-kbd off
```

If the Cooling card never appears, the EC module declined to bind — check
`journalctl -b | grep -E 'msi-ec|legion'` for what the driver reported, then see
the header comment in `hosts/gs65/fan-control.nix` (EC firmware not matched) or
`hosts/legion/fan-control.nix` (DMI not on the module's allowlist).

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
│ ├── headless-server.md # Always-on tailnet-only host mode
│ ├── mobile-agents.md # Phone → herdr (Collie PWA, SSH/Mosh + Termux fallback)
│ └── forking.md # Adapting this repo to your own setup
├── nixos/
│ ├── flake.nix # collie is a PINNED flake input (AltanS/collie), not a local package
│ ├── flake.lock
│ ├── secrets.yaml # Encrypted secrets (sops + Age)
│ ├── options.nix
│ ├── pkgs/ # Packages not in nixpkgs (msi-perkeyrgb, moshi-hook)
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
