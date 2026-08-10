#!/usr/bin/env bash
#
# nixos-install.sh — opinionated NixOS installer for a btrfs subvolume layout,
# with optional Windows dual-boot preservation and optional impermanence.
#
# Run it from a NixOS installer live USB:
#     bash /mnt/runbook/nixos-install.sh --help
#
# (The USB partition is usually FAT32, which cannot store the executable bit,
# so invoke it via `bash` rather than `./nixos-install.sh`.)
#
# DESIGN NOTE — the preflight checks are the point of this script.
# Wiping a disk and running nixos-install is five commands. What actually goes
# wrong is everything around it: a stale hardware.nix, a flake that does not
# evaluate, a missing age key, a password secret stored as plaintext instead of
# a hash, a full build that will not fit in the live session's RAM-backed store,
# an ESP that gets reformatted and takes the Windows Boot Manager with it.
# Every check below exists because it is a failure that has actually happened.
#
# This script is DESTRUCTIVE. It has not been run end-to-end on your hardware.
# Read it before you trust it. Use --check-only first.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────

FLAKE=""                 # path or URL to the flake (e.g. /mnt/home/x/.dotfiles/nixos)
FLAKE_URL=""             # git URL to clone if FLAKE is not a local path
HOST=""                  # flake output / nixosConfigurations attribute
USERNAME=""              # normal user; auto-detected from the config if empty
DISK=""                  # whole disk, e.g. /dev/nvme0n1 (wholedisk mode)
ROOT_PART=""             # partition to format as btrfs, e.g. /dev/nvme0n1p2
ESP_PART=""              # EFI system partition, e.g. /dev/nvme0n1p1
SWAP_PART=""             # existing swap partition, e.g. /dev/nvme0n1p3
AGE_KEY=""               # path to sops age keys.txt to seed into the target
MODE="partition"         # partition | wholedisk
KEEP_WINDOWS="auto"      # auto | yes | no
IMPERMANENCE="no"        # yes | no  (controls the persistence.nix toggle)
SWAP_SIZE="8G"           # wholedisk mode only
ESP_SIZE="1G"            # wholedisk mode only
BACKUP_DIR=""            # where to write the ESP backup
ASSUME_YES="no"
CHECK_ONLY="no"
MNT="/mnt/target"

SUBVOLS=(root home nix persist)
BTRFS_OPTS="compress=zstd,noatime"

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

FAILED=0
step()  { printf '\n%s══ %s%s\n' "$C_BLU" "$*" "$C_OFF"; }
ok()    { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
bad()   { printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*"; FAILED=$((FAILED+1)); }
die()   { printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
note()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

usage() {
  cat <<'USAGE'
nixos-install.sh — btrfs + optional impermanence NixOS installer

REQUIRED
  --flake PATH|URL      Flake directory, or a git URL to clone
  --host NAME           nixosConfigurations attribute for this machine
                        (e.g. the hostname the flake defines for it)

DISK SELECTION (pick one mode)
  --root-part DEV       Reformat only this partition. Everything else on the
                        disk — including the ESP and any Windows partitions —
                        is left alone. This is the dual-boot-safe mode.
  --disk DEV            Whole-disk mode. Repartitions DEV from scratch:
                        ESP + swap + btrfs root. Destroys Windows.

OPTIONAL
  --esp DEV             EFI system partition. Auto-detected if omitted.
  --swap DEV            Existing swap partition to reuse and enable.
  --user NAME           Normal user. Auto-detected from the config if omitted.
  --age-key PATH        sops age key to seed into the target home before
                        install. Required if the login password is a sops
                        secret with neededForUsers.
  --impermanence        Enable persistence.nix (root wiped every boot).
                        Default: disabled for the first install.
  --keep-windows yes|no|auto   Default auto: detect EFI/Microsoft on the ESP.
  --swap-size SIZE      Whole-disk mode only. Default 8G.
  --esp-size SIZE       Whole-disk mode only. Default 1G.
  --backup-dir PATH     Where to copy the ESP before touching anything.
  --check-only          Run every preflight check, then stop. Nothing written.
  --yes                 Skip the interactive confirmation. Use with care.
  --help

EXAMPLES
  # dry run: dual-boot machine, only the root partition gets wiped.
  # The flake is cloned from git (no auth needed for a public repo), and the
  # clone (with .git) is seeded into the target home, so the installed system
  # owns a real git checkout of ~/.dotfiles.
  bash nixos-install.sh --check-only \
    --flake https://github.com/<you>/<dotfiles> --host <host> \
    --root-part /dev/nvme0n1p2 --swap /dev/nvme0n1p3 \
    --age-key /mnt/runbook/age-keys.txt

  # the real thing (confirm the devices with lsblk first!)
  bash nixos-install.sh \
    --flake https://github.com/<you>/<dotfiles> --host <host> \
    --root-part /dev/nvme0n1p2 --swap /dev/nvme0n1p3 \
    --age-key /mnt/runbook/age-keys.txt \
    --backup-dir /mnt/runbook/backups
USAGE
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --flake)        FLAKE="$2"; shift 2 ;;
    --host)         HOST="$2"; shift 2 ;;
    --user)         USERNAME="$2"; shift 2 ;;
    --disk)         DISK="$2"; MODE="wholedisk"; shift 2 ;;
    --root-part)    ROOT_PART="$2"; MODE="partition"; shift 2 ;;
    --esp)          ESP_PART="$2"; shift 2 ;;
    --swap)         SWAP_PART="$2"; shift 2 ;;
    --age-key)      AGE_KEY="$2"; shift 2 ;;
    --impermanence) IMPERMANENCE="yes"; shift ;;
    --keep-windows) KEEP_WINDOWS="$2"; shift 2 ;;
    --swap-size)    SWAP_SIZE="$2"; shift 2 ;;
    --esp-size)     ESP_SIZE="$2"; shift 2 ;;
    --backup-dir)   BACKUP_DIR="$2"; shift 2 ;;
    --check-only)   CHECK_ONLY="yes"; shift ;;
    --yes)          ASSUME_YES="yes"; shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$FLAKE" ] || die "--flake is required"
[ -n "$HOST" ]  || die "--host is required"
[ -n "$ROOT_PART" ] || [ -n "$DISK" ] || die "one of --root-part or --disk is required"

export NIX_CONFIG="experimental-features = nix-command flakes"

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────

step "Preflight: environment"

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0 ..."
ok "running as root"

for t in btrfs mkfs.btrfs nixos-install nix findmnt lsblk blkid wipefs; do
  command -v "$t" >/dev/null 2>&1 || bad "missing tool: $t"
done
[ "$FAILED" -eq 0 ] && ok "required tools present"

if [ "$MODE" = "wholedisk" ]; then
  command -v sgdisk >/dev/null 2>&1 || bad "whole-disk mode needs sgdisk (nix-shell -p gptfdisk)"
fi

# Network. nixos-install will need the binary cache.
if curl -fsS --max-time 10 -o /dev/null https://cache.nixos.org/nix-cache-info 2>/dev/null; then
  ok "binary cache reachable"
else
  bad "cannot reach cache.nixos.org — bring up networking first"
fi

# The live ISO's writable store is a tmpfs in RAM. Enabling existing swap gives
# the evaluator and any source builds somewhere to spill.
if [ -n "$SWAP_PART" ] && [ -b "$SWAP_PART" ]; then
  if swapon --show=NAME --noheadings | grep -qx "$SWAP_PART"; then
    ok "swap already active: $SWAP_PART"
  elif swapon "$SWAP_PART" 2>/dev/null; then
    ok "enabled swap: $SWAP_PART"
  else
    warn "could not enable swap on $SWAP_PART (not fatal)"
  fi
fi

RAM_GB=$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)
note "RAM ${RAM_GB} GiB, swap active: $(swapon --show=SIZE --noheadings | tr '\n' ' ')"
note "nixos-install writes to the target disk, not this RAM store — that is fine."

# ─────────────────────────────────────────────────────────────────────────────

step "Preflight: disk layout"

if [ "$MODE" = "partition" ]; then
  [ -b "$ROOT_PART" ] || die "$ROOT_PART is not a block device"
  ok "root partition: $ROOT_PART ($(lsblk -ndo SIZE "$ROOT_PART" | tr -d ' '))"
  PARENT_DISK="/dev/$(lsblk -ndo PKNAME "$ROOT_PART")"
else
  [ -b "$DISK" ] || die "$DISK is not a block device"
  PARENT_DISK="$DISK"
  warn "WHOLE-DISK MODE — every partition on $DISK will be destroyed"
fi

# Auto-detect the ESP if not given: a vfat partition on the same disk flagged
# as an EFI System Partition.
if [ -z "$ESP_PART" ] && [ "$MODE" = "partition" ]; then
  while read -r dev fstype parttype; do
    [ "$fstype" = "vfat" ] || continue
    case "$parttype" in
      c12a7328-f81f-11d2-ba4b-00a0c93ec93b|"") ESP_PART="$dev"; break ;;
    esac
  done < <(lsblk -rno PATH,FSTYPE,PARTTYPE "$PARENT_DISK" 2>/dev/null)
fi

if [ "$MODE" = "partition" ]; then
  [ -n "$ESP_PART" ] && [ -b "$ESP_PART" ] || die "could not determine the ESP; pass --esp"
  ok "ESP: $ESP_PART ($(lsblk -ndo SIZE "$ESP_PART" | tr -d ' '))"

  ESP_TMP=$(mktemp -d)
  mount -o ro "$ESP_PART" "$ESP_TMP" || die "cannot mount ESP $ESP_PART"
  if [ -e "$ESP_TMP/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    WINDOWS_FOUND="yes"
    ok "Windows Boot Manager found on the ESP"
  else
    WINDOWS_FOUND="no"
    note "no Windows Boot Manager on this ESP"
  fi
  ESP_USED=$(df -h --output=used "$ESP_TMP" | tail -1 | tr -d ' ')
  ESP_SIZE_ACTUAL=$(df -h --output=size "$ESP_TMP" | tail -1 | tr -d ' ')
  note "ESP usage: $ESP_USED of $ESP_SIZE_ACTUAL"
  umount "$ESP_TMP"; rmdir "$ESP_TMP"

  if [ "$KEEP_WINDOWS" = "auto" ]; then
    KEEP_WINDOWS="$WINDOWS_FOUND"
  fi
  if [ "$KEEP_WINDOWS" = "yes" ] && [ "$WINDOWS_FOUND" = "no" ]; then
    bad "--keep-windows yes but no Windows bootloader found on $ESP_PART"
  fi
  [ "$KEEP_WINDOWS" = "yes" ] && ok "dual-boot mode: ESP will NOT be reformatted"
else
  WINDOWS_FOUND="no"; KEEP_WINDOWS="no"
fi

# The ESP sizes NixOS generations poorly if configurationLimit is high. Warn.
step "Preflight: flake evaluation"

# Clone if the flake looks like a URL.
case "$FLAKE" in
  http*://*|git@*|github:*)
    FLAKE_URL="$FLAKE"
    FLAKE="/tmp/flake-clone"
    rm -rf "$FLAKE"
    git clone --depth 1 "$FLAKE_URL" "$FLAKE" || die "clone failed: $FLAKE_URL"
    # assume the nixos subdirectory convention; adjust if yours differs
    [ -f "$FLAKE/flake.nix" ] || FLAKE="$FLAKE/nixos"
    ;;
esac
[ -f "$FLAKE/flake.nix" ] || die "no flake.nix at $FLAKE"
ok "flake: $FLAKE"

# Uncommitted files are invisible to flake evaluation unless staged.
if git -C "$FLAKE" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$FLAKE" add -A 2>/dev/null || true
  note "staged working tree so flake eval sees local edits"
fi

TOPLEVEL=".config.system.build.toplevel"
eval_attr() {
  nix eval --json "$FLAKE#nixosConfigurations.$HOST.config.$1" 2>/dev/null || echo "null"
}

if nix eval --raw "$FLAKE#nixosConfigurations.$HOST$TOPLEVEL.drvPath" >/dev/null 2>&1; then
  ok "config '$HOST' evaluates"
else
  bad "config '$HOST' does NOT evaluate — fix this before wiping anything"
  nix eval --raw "$FLAKE#nixosConfigurations.$HOST$TOPLEVEL.drvPath" 2>&1 | tail -20 | sed 's/^/      /'
fi

# Detect the normal user if not supplied.
if [ -z "$USERNAME" ]; then
  USERNAME=$(nix eval --json --apply \
    'us: builtins.filter (n: (us.${n}.isNormalUser or false)) (builtins.attrNames us)' \
    "$FLAKE#nixosConfigurations.$HOST.config.users.users" 2>/dev/null \
    | tr -d '[]" ' | cut -d, -f1) || true
fi
[ -n "$USERNAME" ] && ok "normal user: $USERNAME" || bad "could not determine the normal user; pass --user"

# ─── the check that would have caught your lockout ───────────────────────────

step "Preflight: authentication"

MUTABLE=$(eval_attr "users.mutableUsers")
note "users.mutableUsers = $MUTABLE"

USER_HPF=$(nix eval --raw "$FLAKE#nixosConfigurations.$HOST.config.users.users.$USERNAME.hashedPasswordFile" 2>/dev/null || echo "")
USER_HP=$(nix eval --raw "$FLAKE#nixosConfigurations.$HOST.config.users.users.$USERNAME.hashedPassword" 2>/dev/null || echo "")
ROOT_HPF=$(nix eval --raw "$FLAKE#nixosConfigurations.$HOST.config.users.users.root.hashedPasswordFile" 2>/dev/null || echo "")

if [ -n "$USER_HPF" ]; then
  ok "$USERNAME has hashedPasswordFile ($USER_HPF)"
elif [ -n "$USER_HP" ]; then
  ok "$USERNAME has an inline hashedPassword"
else
  bad "$USERNAME has NO password set — you will not be able to sudo after install"
  if [ -n "$ROOT_HPF" ]; then
    note "root DOES have hashedPasswordFile set. sudo authenticates as the"
    note "invoking user, not root, so a root-only password does not help."
    note "Fix: users.users.$USERNAME.hashedPasswordFile = config.sops.secrets.password.path;"
  fi
fi

# hashedPasswordFile must contain a HASH. If the sops value is plaintext, sops
# reports success, the file is written, and every login silently fails.
if [ -n "$AGE_KEY" ] && [ -f "$AGE_KEY" ] && [ -n "$USER_HPF" ]; then
  if command -v sops >/dev/null 2>&1 && [ -f "$FLAKE/secrets.yaml" ]; then
    PW=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d --extract '["password"]' "$FLAKE/secrets.yaml" 2>/dev/null || echo "")
    if [ -z "$PW" ]; then
      warn "could not decrypt the 'password' secret to verify it (key name may differ)"
    elif [ "${PW:0:1}" = '$' ]; then
      ok "sops 'password' looks like a hash (${PW:0:3}...)"
    else
      bad "sops 'password' is PLAINTEXT, not a hash — login will fail"
      note "Fix: mkpasswd -m yescrypt   then store that in secrets.yaml"
    fi
  else
    warn "sops not available here; cannot verify the password is a hash"
    note "run: nix-shell -p sops --run '...' if you want this check"
  fi
fi

if [ -n "$AGE_KEY" ]; then
  if [ -f "$AGE_KEY" ] && grep -qE 'AGE-SECRET-KEY|^# created:' "$AGE_KEY"; then
    ok "age key looks valid: $AGE_KEY"
  else
    bad "age key missing or unrecognised: $AGE_KEY"
  fi
else
  warn "no --age-key given; if the password is a sops secret, install will"
  warn "succeed and then you will not be able to log in"
fi

# ─────────────────────────────────────────────────────────────────────────────

step "Preflight: impermanence"

PERSIST_FILE="$FLAKE/config/system/persistence.nix"
DEFAULT_FILE="$FLAKE/config/system/default.nix"

if [ "$IMPERMANENCE" = "yes" ]; then
  warn "impermanence requested for the FIRST install"
  note "Recommended: install without it, confirm the machine boots and you can"
  note "log in, seed /persist from the running system, then enable it. Enabling"
  note "it now means a first-ever root rollback on an unproven system."
  if [ -f "$PERSIST_FILE" ]; then
    grep -q 'initrd-root-device.target' "$PERSIST_FILE" \
      && ok "rollback service orders after initrd-root-device.target" \
      || bad "rollback service is MISSING 'after = [\"initrd-root-device.target\"]' — it can race udev and drop you into an initrd emergency shell"
  fi
else
  ok "impermanence disabled for this install (opts.enablePersistence stays false)"
fi

if [ "$CHECK_ONLY" = "yes" ]; then
  step "Check-only mode"
  if [ "$FAILED" -eq 0 ]; then
    printf '\n%sAll checks passed.%s Re-run without --check-only to install.\n\n' "$C_GRN" "$C_OFF"
    exit 0
  fi
  printf '\n%s%d check(s) failed.%s Nothing was written.\n\n' "$C_RED" "$FAILED" "$C_OFF"
  exit 1
fi

[ "$FAILED" -eq 0 ] || die "$FAILED preflight check(s) failed — refusing to touch the disk"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────

step "About to destroy data"

if [ "$MODE" = "partition" ]; then
  echo "  Reformat:  $ROOT_PART   (everything on it is lost)"
  echo "  Preserve:  $ESP_PART (ESP)${SWAP_PART:+, $SWAP_PART (swap)}"
  [ "$KEEP_WINDOWS" = "yes" ] && echo "  Windows:   preserved"
else
  echo "  Repartition and destroy ALL of: $DISK"
  [ "$WINDOWS_FOUND" = "yes" ] && echo "  ${C_RED}Windows on this disk will be destroyed${C_OFF}"
fi
echo "  Install:   $HOST from $FLAKE"
echo

if [ "$ASSUME_YES" != "yes" ]; then
  TARGET_NAME="${ROOT_PART:-$DISK}"
  printf 'Type the target device path exactly to continue (%s): ' "$TARGET_NAME"
  read -r CONFIRM
  [ "$CONFIRM" = "$TARGET_NAME" ] || die "aborted"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ESP BACKUP
# ─────────────────────────────────────────────────────────────────────────────

if [ "$MODE" = "partition" ] && [ -n "$BACKUP_DIR" ]; then
  step "Backing up the ESP"
  mkdir -p "$BACKUP_DIR"
  ESP_TMP=$(mktemp -d)
  mount -o ro "$ESP_PART" "$ESP_TMP"
  DEST="$BACKUP_DIR/esp-backup-$(date +%F-%H%M%S)"
  cp -a "$ESP_TMP" "$DEST"
  umount "$ESP_TMP"; rmdir "$ESP_TMP"
  ok "ESP copied to $DEST ($(du -sh "$DEST" | cut -f1))"
elif [ "$MODE" = "partition" ]; then
  warn "no --backup-dir given; skipping ESP backup"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PARTITION (whole-disk mode only)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$MODE" = "wholedisk" ]; then
  step "Partitioning $DISK"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+"$ESP_SIZE"  -t1:ef00 -c1:ESP   "$DISK"
  sgdisk -n2:0:+"$SWAP_SIZE" -t2:8200 -c2:swap  "$DISK"
  sgdisk -n3:0:0             -t3:8300 -c3:nixos "$DISK"
  partprobe "$DISK" 2>/dev/null || true
  sleep 2
  case "$DISK" in
    *nvme*|*mmcblk*) ESP_PART="${DISK}p1"; SWAP_PART="${DISK}p2"; ROOT_PART="${DISK}p3" ;;
    *)               ESP_PART="${DISK}1";  SWAP_PART="${DISK}2";  ROOT_PART="${DISK}3"  ;;
  esac
  mkfs.vfat -F32 -n ESP "$ESP_PART"
  mkswap -L swap "$SWAP_PART"
  swapon "$SWAP_PART"
  ok "created $ESP_PART (ESP), $SWAP_PART (swap), $ROOT_PART (root)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FILESYSTEM
# ─────────────────────────────────────────────────────────────────────────────

step "Creating btrfs filesystem and subvolumes"

umount -R "$MNT" 2>/dev/null || true
wipefs -a "$ROOT_PART"
mkfs.btrfs -f -L nixos "$ROOT_PART"

mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
for sv in "${SUBVOLS[@]}"; do
  btrfs subvolume create "$MNT/$sv" >/dev/null
done
btrfs subvolume list "$MNT" | sed 's/^/  /'
umount "$MNT"
ok "subvolumes created: ${SUBVOLS[*]}"

step "Mounting target"

mount -o "subvol=root,$BTRFS_OPTS" LABEL=nixos "$MNT"
mkdir -p "$MNT"/{home,nix,persist,boot}
mount -o "subvol=home,$BTRFS_OPTS"    LABEL=nixos "$MNT/home"
mount -o "subvol=nix,$BTRFS_OPTS"     LABEL=nixos "$MNT/nix"
mount -o "subvol=persist,$BTRFS_OPTS" LABEL=nixos "$MNT/persist"
mount -o umask=0077 "$ESP_PART" "$MNT/boot"
findmnt -R "$MNT" | sed 's/^/  /'

if [ "$KEEP_WINDOWS" = "yes" ]; then
  [ -e "$MNT/boot/EFI/Microsoft/Boot/bootmgfw.efi" ] \
    || die "Windows Boot Manager vanished from the ESP — STOP and restore the backup"
  ok "Windows Boot Manager still present"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SEED
# ─────────────────────────────────────────────────────────────────────────────

step "Seeding the target home"

USER_HOME="$MNT/home/$USERNAME"
mkdir -p "$USER_HOME"

if [ -n "$AGE_KEY" ]; then
  mkdir -p "$USER_HOME/.config/sops/age"
  cp "$AGE_KEY" "$USER_HOME/.config/sops/age/keys.txt"
  chmod 700 "$USER_HOME/.config/sops/age"
  chmod 600 "$USER_HOME/.config/sops/age/keys.txt"
  ok "age key seeded"
fi

# Copy the flake in so the installed system owns its own config.
DOTFILES_SRC=$(cd "$FLAKE/.." && pwd)
if [ -d "$DOTFILES_SRC/.git" ] && [ ! -e "$USER_HOME/.dotfiles" ]; then
  cp -a "$DOTFILES_SRC" "$USER_HOME/.dotfiles"
  ok "flake repo copied to /home/$USERNAME/.dotfiles"
  TARGET_FLAKE="$USER_HOME/.dotfiles/$(basename "$FLAKE")"
else
  TARGET_FLAKE="$FLAKE"
fi

chown -R 1000:100 "$USER_HOME"
if [ -n "$AGE_KEY" ]; then
  runuser -u "#1000" -- head -c 1 "$USER_HOME/.config/sops/age/keys.txt" >/dev/null 2>&1 \
    && ok "age key readable as uid 1000" \
    || warn "age key NOT readable as uid 1000 — activation may fail to decrypt"
fi

# ─────────────────────────────────────────────────────────────────────────────
# IMPERMANENCE TOGGLE
# ─────────────────────────────────────────────────────────────────────────────

# Flip opts.enablePersistence in the host's options.nix (e.g. hosts/<host>/options.nix).
# default.nix imports ./persistence.nix and hardware.nix mounts /persist only
# when that boolean is true, so this is the single switch.
TARGET_OPTS="$TARGET_FLAKE/hosts/${HOST%-fast}/options.nix"
if [ -f "$TARGET_OPTS" ]; then
  if [ "$IMPERMANENCE" = "yes" ]; then
    sed -i 's|enablePersistence *= *false|enablePersistence = true|' "$TARGET_OPTS"
  else
    sed -i 's|enablePersistence *= *true|enablePersistence = false|' "$TARGET_OPTS"
  fi
  grep -n 'enablePersistence' "$TARGET_OPTS" | sed 's/^/  /'
  git -C "$TARGET_FLAKE" add -A 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL
# ─────────────────────────────────────────────────────────────────────────────

step "Running nixos-install"
note "this takes 30-60 minutes; consider running the whole script under tmux"

nixos-install --root "$MNT" --no-root-passwd --flake "$TARGET_FLAKE#$HOST"

# ─────────────────────────────────────────────────────────────────────────────
# POSTFLIGHT
# ─────────────────────────────────────────────────────────────────────────────

step "Postflight"

[ -d "$MNT/boot/EFI/nixos" ] && ok "NixOS boot files installed" || bad "no EFI/nixos directory"
[ -d "$MNT/boot/loader/entries" ] && ok "loader entries present" || bad "no loader/entries"

if [ "$KEEP_WINDOWS" = "yes" ]; then
  [ -e "$MNT/boot/EFI/Microsoft/Boot/bootmgfw.efi" ] \
    && ok "Windows Boot Manager survived the install" \
    || bad "WINDOWS BOOTLOADER MISSING — restore from the ESP backup"

  if grep -q '^auto-entries no' "$MNT/boot/loader/loader.conf" 2>/dev/null; then
    ok "auto-entries disabled — exactly one Windows menu entry"
  else
    warn "auto-entries not disabled: systemd-boot will add its own duplicate"
    warn "Windows entry at the bottom of the menu, in addition to any manual one"
  fi
  ls "$MNT/boot/loader/entries/" | grep -qi windows \
    && ok "a manual Windows entry exists" \
    || warn "no manual Windows entry; the auto-detected one sorts last and cannot be moved"
fi

ESP_USE=$(df -h --output=pcent "$MNT/boot" | tail -1 | tr -d ' %')
if [ "$ESP_USE" -gt 60 ]; then
  warn "ESP is ${ESP_USE}% full after ONE generation"
  warn "lower boot.loader.systemd-boot.configurationLimit or you will hit ENOSPC"
else
  ok "ESP usage ${ESP_USE}%"
fi

step "Done"
cat <<EOF

  Next:
    umount -R $MNT
    reboot        (remove the USB)

  On first boot:
    1. log in as $USERNAME — this is the real test of secret decryption
    2. boot into Windows once to confirm the entry chainloads
       (a BitLocker recovery prompt is expected on first chainload;
        get the key from account.microsoft.com/devices/recoverykey)

  To enable impermanence LATER, from the running system:
    sudo mkdir -p /persist/system/etc/NetworkManager /persist/system/var/lib
    sudo cp -a /etc/ssh /etc/machine-id /persist/system/etc/
    sudo cp -a /var/lib/nixos /persist/system/var/lib/
    sudo cp -a /etc/NetworkManager/system-connections /persist/system/etc/NetworkManager/
    sed -i 's|enablePersistence *= *false|enablePersistence = true|' \\
      ~/.dotfiles/nixos/hosts/${HOST%-fast}/options.nix
    nixos-rebuild switch --flake ~/.dotfiles/nixos#$HOST && reboot

  impermanence does NOT copy files for you. Seeding /persist first is what
  keeps your SSH host keys, machine-id and uid allocations across the wipe.

EOF

if [ "$FAILED" -gt 0 ]; then
  printf '%s%d postflight check(s) failed — read them before rebooting.%s\n\n' "$C_YEL" "$FAILED" "$C_OFF"
  exit 1
fi
