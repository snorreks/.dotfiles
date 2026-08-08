# Setting Up a New Machine

This setup uses **sops-nix** with **Age** encryption for all secrets (SSH keys,
AWS credentials, API tokens, user password). Your master Age key lives in
**Bitwarden** so you can decrypt everything on a fresh install. The repo is
**public**, so cloning needs no credentials — the only secret you must restore
is the sops Age key; everything else (SSH key, API tokens, …) lives inside the
encrypted `nixos/secrets.yaml` and is decrypted automatically on first build.

## Prerequisites (one-time)

Store these in your Bitwarden vault:

| Bitwarden Item Name | Type        | Contents                                                             |
| ------------------- | ----------- | -------------------------------------------------------------------- |
| `sops-age-key`      | Secure Note | Contents of `~/.config/sops/age/keys.txt`                            |
| `github-ssh-key`    | Secure Note | _(optional backup)_ Private SSH key — no longer needed for bootstrap |

## Fresh Machine Bootstrap

On a brand-new NixOS system (TTY or minimal terminal) — one shot:

```bash
# Restore the sops Age key from Bitwarden, clone the public repo — done.
nix-shell -p bitwarden-cli git --run '
  bw login                       # first time only — skip if "already logged in"
  export BW_SESSION="$(bw unlock --raw)"
  mkdir -p ~/.config/sops/age
  bw get notes "sops-age-key" > ~/.config/sops/age/keys.txt
  chmod 700 ~/.config/sops/age
  chmod 600 ~/.config/sops/age/keys.txt
  git clone https://github.com/snorreks/.dotfiles.git ~/.dotfiles
'

# Rebuild — sops-nix decrypts secrets.yaml on first activation, deploying the
# SSH key to ~/.ssh/github_snorreks, AWS creds, API tokens, and the password.
# `nh os switch` with no #attr auto-targets whatever networking.hostName the
# machine currently has — which on a brand-new install is NOT set yet, so
# you must name the flake output explicitly this one time:
#   - Legion:  nh os switch ~/.dotfiles/nixos#legion
#   - GS65:    nh os switch ~/.dotfiles/nixos#gs65
nh os switch ~/.dotfiles/nixos#legion   # or #gs65
```

> **Why no SSH key step?** The repo is public, so `git clone` works over HTTPS
> with no credentials. The SSH key (`~/.ssh/github_snorreks`) is stored inside
> the encrypted `nixos/secrets.yaml` and sops-nix writes it out during the
> first build — so `git push` works automatically after, no Bitwarden needed.

After this first build, `networking.hostName` matches the flake output you
chose, so every later rebuild (`nswitchu`, `nswitch-fast`, etc.) auto-detects
the right host with no `#attr` needed.

If the GS65's `nixos/hosts/gs65/hardware.nix` and `options.nix` still have
their `TODO` placeholders, fill them in **on the GS65 itself** before the
first build there — see the comments in those files.

## GS65 first-time setup

The committed `gs65/hardware.nix` is a placeholder — it defines no
`fileSystems`, so the first `nixos-rebuild` fails with _"The 'fileSystems'
option does not specify your root file system."_ Fix it on the GS65:

```bash
# 1. Generate the real hardware config (fileSystems, initrd modules, swap)
sudo nixos-generate-config --show-hardware-config \
  > ~/.dotfiles/nixos/hosts/gs65/hardware.nix

# 2. The generator drops the repo-specific microcode line — re-add it if missing:
#    hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

# 3. The GPU bus IDs in hosts/gs65/options.nix are the Legion's — the GS65's
#    differ. Get the real ones and update intelBusId / nvidiaBusId:
lspci | grep -E "VGA|3D"

# 4. Rebuild
sudo nixos-rebuild boot --flake ~/.dotfiles/nixos#gs65
```

After this first build, `bitwarden-cli` is installed system-wide and you can
use the `fetch_sops_key` fish function to restore your Age key on future
rebuilds.

Instead of the manual steps above, GS65 can also do its real first install
with **disko** (see below) — it doesn't carry any data to preserve today, so
it's a good candidate for a from-scratch, disko-managed install rather than
the manual partitioning `nixos-generate-config` does.

## Restoring the Age Key Later

```fish
fetch_sops_key   # pulls sops-age-key from your Bitwarden vault
```

## Restoring Thunderbird Accounts on a New Machine

`backup_thunderbird_profile` snapshots your Thunderbird account names, server
settings, polling intervals, saved logins/OAuth tokens, OpenPGP keys, and
address book into sops (`thunderbird_profile_bundle` in `secrets.yaml`) —
deliberately **not** the mail store itself, which stays out of git.

On the old machine, whenever you add/change an account:

```fish
backup_thunderbird_profile   # re-snapshot, then commit + push secrets.yaml
```

On a new machine, after the first `nh os switch` (so sops-nix has decrypted
the bundle):

```fish
# Launch Thunderbird once to create a fresh default profile, then quit it.
restore_thunderbird_profile
```

Account names/settings and saved logins are restored immediately. Whether
Gmail/Outlook accounts need a fresh interactive login depends on the
provider — personal Gmail often just works with the restored OAuth token,
but Microsoft 365 work/school accounts with Conditional Access policies can
still force a one-time re-login on a "new device" regardless.

## Shared NTFS Steam Library Setup

If using a dual-boot shared NTFS drive for Steam games (`/mnt/shared`), Proton prefixes (`compatdata`) **must** live on your native Linux filesystem (`ext4`) to support POSIX symlinks.

1. Mount the partition via `ntfs3` or `ntfs-3g` in NixOS.
2. Link the `compatdata` directory to your home folder:

```bash
mkdir -p ~/.local/share/Steam/steamapps/compatdata
rm -rf /mnt/shared/SteamLibrary/steamapps/compatdata
ln -s ~/.local/share/Steam/steamapps/compatdata /mnt/shared/SteamLibrary/steamapps/compatdata
```

## Using disko for a from-scratch install

[disko](https://github.com/nix-community/disko) turns `nixos/disko.nix` into
your actual partition table: instead of clicking through a partitioner or
typing `parted`/`mkfs` commands by hand, you declare the disk layout once in
Nix and disko partitions, formats, and mounts everything to match. It only
works on a disk you're OK wiping completely — it's not a migration tool (see
[`impermanence-migration.md`](./impermanence-migration.md) for converting an
existing install instead).

This is unfamiliar territory if you haven't installed NixOS from scratch
before, so here's the full path, including the parts disko doesn't cover:

1. **Create a NixOS installer USB.** Download the ISO from
   [nixos.org/download](https://nixos.org/download/) and follow the official
   [installation guide](https://nixos.org/manual/nixos/stable/#sec-installation)
   for writing it to a USB stick (`dd`, Rufus, balenaEtcher, Ventoy — any of
   them work) and booting the target machine from it.
2. **Boot the target machine from the USB** and confirm you have networking
   (`ping nixos.org`) — you'll need it to pull flake inputs and clone the repo.
3. **Identify the disk** you're about to wipe: `lsblk`. Triple-check this —
   disko will destroy everything on whatever device you point it at.
4. **Get the repo and your secrets onto the live environment**, same as the
   [Fresh Machine Bootstrap](#fresh-machine-bootstrap) steps above (Bitwarden
   → age key → `git clone`).
5. **Point the host at `disko.nix`.** Add this to the target host's
   `hosts/<name>/default.nix` (not committed by default, since neither
   current host uses disko live today):
   ```nix
   {opts, ...}: {
     imports = [./hardware.nix];
     disko.devices = (import ../../disko.nix {device = "/dev/${opts.deviceName}";}).disko.devices;
   }
   ```
6. **Restore the sops age key into the target root before installing.**
   The login password is itself a sops secret decrypted during activation, so
   `nixos-install` will fail without the key already present at
   `/mnt/home/<user>/.config/sops/age/keys.txt` (mount point paths, since
   nothing's booted into the new system yet).
7. **Run disko**, which partitions/formats/mounts everything under `/mnt`:
   ```bash
   sudo nix run github:nix-community/disko -- --mode disko --flake ~/.dotfiles/nixos#<hostname>
   ```
8. **Install and reboot:**
   ```bash
   sudo nixos-install --flake ~/.dotfiles/nixos#<hostname>
   reboot
   ```

See disko's own [quickstart docs](https://github.com/nix-community/disko/blob/master/docs/quickstart.md)
for more detail, and [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
if you'd rather do this remotely over SSH (kexec into a bare machine) instead
of booting a USB stick by hand.
