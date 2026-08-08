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
   (instant, no extra disk space needed). `/home` and `/nix` already exist as
   top-level directories, so move them aside first, then create all four
   subvolumes:
   ```bash
   mv /mnt/home /mnt/home.old
   mv /mnt/nix /mnt/nix.old
   btrfs subvolume create /mnt/root
   btrfs subvolume create /mnt/home
   btrfs subvolume create /mnt/nix
   btrfs subvolume create /mnt/persist

   # home + nix data → subvolumes (reflink copy is instant, uses no space)
   cp -a --reflink=always /mnt/home.old/. /mnt/home/
   cp -a --reflink=always /mnt/nix.old/. /mnt/nix/
   diff -rq /mnt/home.old /mnt/home && echo "home OK"
   diff -rq /mnt/nix.old /mnt/nix && echo "nix OK"
   rm -rf /mnt/home.old /mnt/nix.old

   # everything else (etc, var, usr, …) moves into the root subvolume —
   # that's the subvolume that gets rolled back to empty on every boot
   cd /mnt
   for d in *; do
     case "$d" in root|home|nix|persist) ;; *) mv "$d" root/ ;; esac
   done
   ```
   Sanity-check the result: `ls /mnt/root` (etc, var, usr, …), `ls /mnt/home`
   (your user dir), `ls /mnt/nix` (store, var, …).
5. **Seed `/persist` — impermanence does NOT copy existing files for you.**
   Its activation only creates empty directories and bind mounts, so anything
   listed in `config/system/persistence.nix` must be copied into `/persist`
   *now*, or it's gone on the first wiped boot (SSH host keys, `/etc/nixos`,
   NetworkManager connections, machine-id, …). Do it while the old data is
   still at the top level:
   ```bash
   P=/mnt/persist/system
   mkdir -p "$P/etc/NetworkManager" "$P/var/log" "$P/var/lib/systemd"
   for s in /mnt/etc/ssh /mnt/etc/nixos /mnt/etc/machine-id /mnt/var/log \
            /mnt/var/lib/bluetooth /mnt/var/lib/nixos /mnt/var/lib/docker \
            /mnt/var/lib/colord; do
     [ -e "$s" ] && cp -a --reflink=always "$s" "$P${s#/mnt}"
   done
   [ -e /mnt/etc/NetworkManager/system-connections ] && \
     cp -a --reflink=always /mnt/etc/NetworkManager/system-connections "$P/etc/NetworkManager/"
   [ -e /mnt/var/lib/systemd/coredump ] && \
     cp -a --reflink=always /mnt/var/lib/systemd/coredump "$P/var/lib/systemd/"
   ```
   Keep this list in sync with the `directories`/`files` lists in
   `config/system/persistence.nix`.
6. Update `hosts/<host>/hardware.nix` (`legion` or `gs65`): keep the existing
   `/boot`, `/mnt/shared` and swap entries byte-for-byte, replace the `/`
   entry with the four `LABEL=nixos` + `subvol=` mounts (`root` at `/`,
   `home` at `/home`, `nix` at `/nix`, `persist` at `/persist` with
   `neededForBoot = true`). This edit must be committed **before** the
   live-USB rebuild in step 8 (the old ext4 generation can't boot the
   converted partition, so the new one has to be the one that comes up).
7. Uncomment `./persistence.nix` in `config/system/default.nix` — this is
   the step that actually turns on the boot-time wipe, so do it last.
8. Rebuild into the new layout **from the live USB** (the old ext4
   generation can't boot anymore, so the new config must be built + boot
   entry installed now). The repo and the sops age key are already preserved
   in the `home` subvolume (`/mnt/home/<user>/.dotfiles`,
   `/mnt/home/<user>/.config/sops/age/keys.txt`), so no clone/restore needed:
   ```bash
   umount /mnt
   mount -o subvol=/root,compress=zstd,noatime LABEL=nixos /mnt
   mount -o subvol=/home,compress=zstd,noatime LABEL=nixos /mnt/home
   mount -o subvol=/nix,compress=zstd,noatime LABEL=nixos /mnt/nix
   mount -o subvol=/persist,compress=zstd,noatime LABEL=nixos /mnt/persist
   mount /dev/nvme0n1p1 /mnt/boot   # the ESP — never reformatted

   nixos-install --no-root-passwd \
     --flake "/mnt/home/<user>/.dotfiles/nixos#<host>"
   ```
   `nixos-install` handles the chroot + nix-daemon + bootloader install
   itself; networking on the live USB is needed for any store paths that
   aren't cached yet (e.g. btrfs initrd bits). Then reboot and confirm
   **both** NixOS and the "Windows 11" boot entry still come up.
9. Once you're confident it's stable, delete the `ext2_saved` subvolume
   `btrfs-convert` left behind to reclaim its space.

The GS65 now has a real `hardware.nix` and a dual-boot Windows install with
data to keep, so this same manual procedure applies there — use
`hosts/gs65/hardware.nix` and follow the same steps (its root partition is
also `/dev/nvme0n1p2`, ESP `/dev/nvme0n1p1`, shared NTFS on `/dev/nvme1n1p4`).
`disko.nix` remains the path only for a genuinely fresh, wipeable disk.
