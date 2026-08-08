# Migrating an Existing Install to Impermanence

`disko.nix` and `config/system/persistence.nix` describe the target layout —
a single btrfs partition (label `nixos`) with `root` (wiped every boot),
`home`, `nix`, and `persist` subvolumes — but neither is active yet on an
already-installed machine. `disko.nix` is only for a genuine from-scratch
install (see [`bootstrap.md`](./bootstrap.md#using-disko-for-a-from-scratch-install));
converting an existing disk in place needs a different, manual procedure,
because:

- The ESP (`/boot`) also holds the Windows Boot Manager files in a dual-boot
  setup — it must **not** be reformatted, or Windows stops booting.
- The root partition is usually too full to back up in full before wiping it.

`btrfs-convert` does an in-place ext4→btrfs conversion (no data copied), and
`cp --reflink=always` splits the result into subvolumes for free (reflinks
share extents instead of duplicating bytes) — so this works even with almost
no free space.

**This can only be done from a live USB** — you can't reformat the
filesystem you're currently booted from.

1. **Back up what's irreplaceable.** Not everything — Steam games and
   `node_modules`/build output are cheap to regenerate. Just SSH/GPG keys,
   browser profiles, mail, and anything `git status` shows as uncommitted.
   Copy it to `/mnt/shared` or an external drive. (The sops Age key is
   already recoverable from Bitwarden — see [`bootstrap.md`](./bootstrap.md)
   — so it's not a hard blocker.)
2. Boot a live USB with `btrfs-progs` available (the NixOS installer ISO has
   it — see [`bootstrap.md`](./bootstrap.md#using-disko-for-a-from-scratch-install)
   for how to create one).
3. Convert the root partition in place, leaving the ESP and swap partitions
   completely untouched:
   ```bash
   btrfs-convert /dev/nvme0n1p2       # replace p2 with your actual root partition
   btrfs filesystem label /dev/nvme0n1p2 nixos
   mkdir -p /mnt && mount LABEL=nixos /mnt
   ```
4. Create the subvolumes and move existing data into them with reflinks
   (instant, no extra disk space needed):
   ```bash
   btrfs subvolume create /mnt/root
   btrfs subvolume create /mnt/home
   btrfs subvolume create /mnt/nix
   btrfs subvolume create /mnt/persist

   cp -a --reflink=always /mnt/home/. /mnt/home-new/.   # adjust source paths to
   # wherever they actually landed after btrfs-convert, verify contents match,
   # then remove the originals and rename home-new -> home (same for /nix, /etc, /var).
   ```
5. Update `hosts/legion/hardware.nix`: keep the existing `/boot` and swap
   `fileSystems` entries byte-for-byte, replace the `/` entry with the four
   `LABEL=nixos` + `subvol=` mounts (`root` at `/`, `home` at `/home`, `nix`
   at `/nix`, `persist` at `/persist`).
6. Uncomment `./persistence.nix` in `config/system/default.nix` — this is
   the step that actually turns on the boot-time wipe, so do it last.
7. `nixos-install`/chroot and rebuild, reboot, and confirm **both** NixOS and
   the "Windows 11" boot entry still come up.
8. Once you're confident it's stable, delete the `ext2_saved` subvolume
   `btrfs-convert` left behind to reclaim its space.

GS65 doesn't have a real `hardware.nix` yet (see
[GS65 first-time setup](./bootstrap.md#gs65-first-time-setup)), so this
doesn't apply there until its first real install — at that point it can just
use `disko.nix` directly instead of this manual procedure.
