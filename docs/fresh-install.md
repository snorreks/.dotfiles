# Fresh Install Guide

From-scratch NixOS install (dual-boot, Windows preserved) for the MSI GS65 —
or any host in this repo. Written from a real install that hit every trap
below; the "Known issues" section is the hard-won part.

The config is **cloned from git during install**, so the installed system
owns a real `~/.dotfiles` checkout (`.git` included) — no manual `git init`,
no stale USB copies, and the USB only needs two small files.

## Prerequisites

- **Commit and push the repo first.** The install clones from GitHub, so it
  only gets what's committed. Today's fixes must be pushed before installing.
  (`update_dotfiles "message"` does add/commit/push.)
- USB stick with two partitions:
  - the NixOS installer ISO (e.g. `nixos-minimal`), written with `dd`
  - a FAT32 `RUNBOOK` partition holding only:
    - `nixos-install.sh` — the installer script (repo root)
    - `age-keys.txt` — your sops age key (from `~/.config/sops/age/keys.txt`)
- Network — the build pulls from cache.nixos.org, and the clone needs GitHub.

## The install

1. **Boot the USB** (F11 at the MSI logo → USB/UEFI).
2. **Mount the RUNBOOK partition.** A direct mount fails on the live ISO
   ("Can't open blockdev") — always use a loop device:
   ```bash
   sudo mkdir -p /mnt/runbook
   L=$(sudo losetup -f --show /dev/sda3)   # adjust the device!
   sudo mount "$L" /mnt/runbook
   ```
3. **Network:** `sudo nmcli device wifi connect "SSID" password "..."`
4. **Confirm the disk layout** — device names change between machines and
   sessions, always `lsblk -f` first. On the MSI: `nvme1n1` = NixOS disk
   (ESP + btrfs `nixos` + swap), `nvme0n1` = Windows. Windows' bootloader
   lives on the shared ESP — that's why we only reformat the root partition.
5. **Dry run** (writes nothing):
   ```bash
   sudo bash /mnt/runbook/nixos-install.sh --check-only \
     --flake https://github.com/snorreks/.dotfiles --host gs65-fast \
     --root-part /dev/nvme1n1p2 --swap /dev/nvme1n1p3 \
     --age-key /mnt/runbook/age-keys.txt
   ```
6. **Real install** (30–60 min; the confirm prompt wants the exact device):
   ```bash
   sudo bash /mnt/runbook/nixos-install.sh \
     --flake https://github.com/snorreks/.dotfiles --host gs65-fast \
     --root-part /dev/nvme1n1p2 --swap /dev/nvme1n1p3 \
     --age-key /mnt/runbook/age-keys.txt \
     --backup-dir /mnt/runbook/backups
   ```
   If the build dies with out-of-space on `/nix` (small RAM):
   `sudo mount -o remount,size=24G /` — the installer's store is a RAM tmpfs.
7. **Reboot** (remove USB), log in as `sonny`, then `nswitch` for the full
   config (ollama-cuda).

The clone's origin is HTTPS (public repo, no auth needed to clone). To push
later, switch the origin to SSH once the machine has its key:
```bash
git remote set-url origin git@github.com:snorreks/.dotfiles
```

## Known issues

### 1. sops password + separate `/home` subvolume = locked accounts every boot
**The one that bit us.** NixOS runs the full activation *inside the initrd at
every boot*. The sops `neededForUsers` secret (your login password) is
decrypted during that step, but the age key lives in `/home` — a separate
btrfs subvolume that **isn't mounted in the initrd unless declared**.
Decryption fails → the users-groups step writes `!` (locked) to `/etc/shadow`
**on every boot** → no password works (login, sudo, ssh), even though the
shadow hash is correct on disk.

Fix (already in `nixos/hosts/gs65/hardware.nix`): any host with `/home` on
its own subvolume must mount it in the initrd:
```nix
fileSystems."/home" = {
  device = "/dev/disk/by-label/nixos";
  fsType = "btrfs";
  options = ["subvol=home" "compress=zstd" "noatime"];
  neededForBoot = true;   # required for sops password secrets
};
```
The Legion's current layout is ext4 with home on the root fs — unaffected.
If the Legion ever gets a btrfs-subvol install, add the same line.

### 2. Cloning needs the repo to be pushed (and reachable)
The install clones `https://github.com/snorreks/.dotfiles` — a public repo,
so no credentials on the live USB. Two consequences:
- uncommitted local work is NOT installed — commit+push before installing;
- offline installs (no GitHub access) fall back to the old way: copy the
  repo to the runbook and use `--flake /mnt/runbook/dotfiles/nixos` (then
  seed `.git` manually or re-clone after first boot).

### 3. The RUNBOOK partition won't direct-mount on the live ISO
See step 2 — always `losetup` first. Re-plugging the stick doesn't fix it;
a fresh boot does, and then you need the loop trick again.

### 4. `openspec` npm fetch can fail transiently
`openspec` fetches npm deps at build time and registry.npmjs.org sometimes
kills the connection ("unrecoverable HTTP protocol violation"). It's
transient — retry the build (store paths are atomic, progress survives).

### 5. Never use `--disk` mode on a dual-boot machine
`--disk` repartitions the whole disk and doesn't preserve the ESP. Windows
boots from the shared ESP on the MSI — use `--root-part` only.

### 6. The sops password must be a hash
`secrets.yaml`'s `password` must be a crypt hash (`$6$…`, `$y$…`), not
plaintext — otherwise login silently fails for every user. Generate with
`openssl passwd -6` (or `mkpasswd`). `--check-only` verifies this when `sops`
is available — it isn't on the minimal ISO, so check from a working machine.

### 7. Big builds on small-RAM laptops
`/tmp` is disk-backed on the MSI (`useTmpfs = false`) so ollama-cuda-style
builds have room on 15 GiB. Keep it that way.

### 8. GPU bus IDs are host-specific
`nixos/hosts/gs65/options.nix` carries TODO notes — confirm with
`lspci | grep -E "VGA|3D"` if the display doesn't come up.

## First boot

- Log in as `sonny`. If the password fails, check Known issue #1 — don't
  reinstall; fix the mount and rebuild, don't hand-edit the shadow.
- Boot Windows once (top menu entry). A BitLocker recovery prompt on the
  first chainload is expected (key: account.microsoft.com/devices/recoverykey).
- `nswitch` for the full config.
- Point git at SSH for pushing: `git remote set-url origin git@github.com:snorreks/.dotfiles`
- Impermanence is OFF by default (`enablePersistence = false` in
  `nixos/hosts/<host>/options.nix`). To enable later: seed `/persist`
  (see the installer's final output), set `enablePersistence = true` in the
  host options, `nswitch` — the `/persist` mount and the `persistence.nix`
  import are both gated on that boolean. Full walkthrough:
  `impermanence-migration.md`.
