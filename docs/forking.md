# Forking This Repo

This flake is built around one specific person's identity, hardware, and
accounts. None of that is hidden behind a template system — it's just plain
values in a handful of files. Forking means finding and replacing those
values, then following [`bootstrap.md`](./bootstrap.md) to actually install.

Work through this roughly in order — later steps (secrets, disk layout)
assume the earlier ones (identity, hosts) are already sorted.

## 1. Identity — `nixos/options.nix`

This is the single file most values flow from:

| Field                                                                         | What it's for                                                                                                       |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `username`                                                                    | Linux user, home directory, sops age key path                                                                       |
| `hostname`                                                                    | Default flake output name (see [step 2](#2-hosts))                                                                  |
| `gitUsername` / `gitEmail`                                                    | `programs.git` identity                                                                                             |
| `flakeDir`                                                                    | Path used by `nh os switch` / autoUpgrade — usually leave as-is if you keep `~/.dotfiles`                           |
| `defaultBrowser` / `defaultEditor` / `defaultFileManager` / `defaultTerminal` | Which package backs the generic keybinds in `mango.nix`                                                             |
| `latitude` / `longitude`                                                      | Used by `eye-protection.nix` for sunset-based blue-light scheduling                                                 |
| `enableExternalMonitors`, `mainMonitor`, `hdmiMonitor`, `usbcMonitor`         | Your monitor layout — output names/resolutions are hardware-specific, get them from `wlr-randr` on your own machine |
| `intelBusId` / `nvidiaBusId`                                                  | Only relevant if you have hybrid Intel+NVIDIA graphics — see [step 4](#4-gpu--hybrid-graphics)                      |
| `enableOllama`                                                                | Toggles the heavy `ollama-cuda` build; the `-fast` flake output always skips it                                     |

The actual theme color scheme (Stylix `base16Scheme`) is set directly in
`config/home/theme.nix`, not via `options.nix` — pick your own from
[base16 schemes](https://github.com/tinted-theming/base16-schemes).

## 2. Hosts

Each machine gets its own directory under `nixos/hosts/<name>/`:

- `default.nix` — imports `./hardware.nix` and any host-only extras (e.g. `gs65/fan-control.nix` is MSI-specific `nbfc-linux` fan control — delete it, it'll break on other hardware).
- `hardware.nix` — filesystem/initrd/kernel-module config. **Don't hand-write this** — boot the target machine's installer and run `nixos-generate-config --show-hardware-config > hardware.nix`, then re-add the microcode line the generator drops (see `docs/bootstrap.md`'s GS65 section for the exact diff).
- `options.nix` (optional) — per-host overrides merged on top of the base `options.nix` (hostname, GPU bus IDs, `deviceName`, monitor defaults). Follow the pattern in `hosts/gs65/options.nix`.

Then register the host in `nixos/flake.nix`'s `hosts` attrset:

```nix
hosts = {
  your-host-key.optsOverrides = import ./hosts/your-host-key/options.nix;
};
```

This repo builds two outputs per host key (`<hostname>` and `<hostname>-fast`,
the latter skipping `ollama-cuda`) — you get that for free once the host is
registered.

If you only have one machine, delete the second host entry entirely rather
than leaving a broken placeholder.

## 3. Secrets — sops + Age

Every secret (login password, API keys, SSH key, VPN key, ...) is decrypted
from `nixos/secrets.yaml` via [sops-nix](https://github.com/Mic92/sops-nix),
encrypted to your own Age key — you cannot reuse this repo's `secrets.yaml`,
it's encrypted to a key only the original owner holds.

1. Generate your own Age key: `nix-shell -p age --run age-keygen`.
2. Replace the recipient in `.sops.yaml` (repo root) with your new public key.
3. Create a fresh `nixos/secrets.yaml` containing only what you actually
   reference. At minimum, `config/system/user.nix` requires a `password`
   secret (`hashedPasswordFile`) — generate a hash with
   `mkpasswd -m sha-512`. Everything else in `config/home/sops.nix`'s
   `secrets = { ... }` block is optional: **delete the declarations for API
   keys/services you don't use** (Proton VPN, the various LLM provider keys,
   AWS, etc.) rather than leaving them pointing at secrets that don't exist —
   sops-nix fails activation if a declared secret key is missing from the
   file.
4. Store the Age key somewhere you can restore it from on a fresh install
   (this repo uses Bitwarden — see `bootstrap.md` — but any password manager
   with a "secure note" works, or just a USB drive if you're less paranoid).

## 4. GPU / Hybrid Graphics

`config/system/intel-nvidia.nix` assumes hybrid Intel+NVIDIA graphics with
PRIME render offload. If your hardware doesn't match:

- **Single GPU (any vendor)**: delete the import of `intel-nvidia.nix` from
  `config/system/default.nix` and configure `hardware.graphics`/your vendor's
  driver normally.
- **Hybrid Intel+NVIDIA, different laptop**: keep the file, but get your own
  bus IDs with `lspci | grep -E "VGA|3D"` and set them via `intelBusId`/
  `nvidiaBusId` in your host's `options.nix`.

## 5. Disk Layout

`nixos/disko.nix` is a fresh-install reference (ESP + swap + one btrfs
partition with `root`/`home`/`nix`/`persist` subvolumes) paired with
`config/system/persistence.nix`'s boot-time root wipe. This is entirely
optional — if you don't want impermanence, don't import `persistence.nix` or
use `disko.nix`, and just let `nixos-generate-config` produce a normal
`hardware.nix` on a normal filesystem.

If you do want it, see [`bootstrap.md`](./bootstrap.md#using-disko-for-a-from-scratch-install)
for a fresh install, or [`impermanence-migration.md`](./impermanence-migration.md)
for converting an already-installed disk in place.

## 6. Personal Files to Replace or Remove

These are checked into the repo as this person's actual files, not templates:

| Path                                                                                  | What to do                                                                                                                                                         |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `nixos/config/home/files/.ssh/config`, `.ssh/known_hosts`, `.ssh/github_snorreks.pub` | Replace with your own, or delete the `home.file` entries in `config/home/files/default.nix`                                                                        |
| `nixos/config/home/files/.aws/config`                                                 | Your own AWS profile config, or delete if you don't use AWS                                                                                                        |
| `nixos/config/home/sops.nix`'s `github_ssh_key` secret                                | Rename the target path (`~/.ssh/github_snorreks`) away from someone else's key name                                                                                |
| `nixos/config/home/vpn/proton-servers.nix`                                            | Proton's own public server metadata — harmless to keep, but only useful if you have a Proton VPN account. Swap for your own provider's config generator otherwise. |
| `wallpapers/`                                                                         | Your own images                                                                                                                                                    |
| `nixos/config/home/packages.nix`'s `llm-agents` category                              | Trim to whatever AI coding tools you actually use — the whole category (and its `llm-agents` flake input) is removable if you don't want it                        |

## 7. Gaming / Misc (optional trims)

`config/system/gaming.nix` and the `gaming` package category assume Steam +
Proton on a dual-boot laptop sharing an NTFS drive with Windows — see
`docs/bootstrap.md`'s ["Shared NTFS Steam Library Setup"](./bootstrap.md#shared-ntfs-steam-library-setup)
if that applies to you, or delete the gaming pieces entirely if it doesn't.

## 8. Install

Once the above is adapted to your identity and hardware, follow
[`bootstrap.md`](./bootstrap.md) for the actual install — the Bitwarden step
there is specific to this repo's original owner, so swap in whatever secret
manager you used in [step 3](#3-secrets--sops--age).
