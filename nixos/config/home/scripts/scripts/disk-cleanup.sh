#!/usr/bin/env bash
# disk-cleanup.sh — reclaim disk space from caches, temp files, and stale
# container / nix artifacts.
#
#   (default)   Safe, re-downloadable cleanup only:
#                 - package-manager + app caches (bun, npm, go, uv, pip, …)
#                 - /tmp entries older than 3 days
#                 - trash
#                 - dangling container images, stopped containers, build cache
#                 - journald vacuum to 200M
#                 - nix store garbage collection
#   --deep      Everything above PLUS the big-ticket, still-safe items:
#                 - ALL unused container images (not just dangling) + volumes
#                 - editor/agent caches (zed node, herdr worktrees >7d)
#                 - files under ~/Downloads/tmp older than 30 days
#   --dry-run   Print what would be removed; change nothing.
#   --yes       Skip the confirmation prompt (for cron / systemd timers).
#   --help      Show this help.
#
# Rootless podman needs no sudo. The journald vacuum and nix GC use sudo when
# available and are skipped (with a note) otherwise.
#
# NOTE: /tmp is NOT a tmpfs on this host — it lives on the root filesystem, so
# nothing clears it on reboot. That is why stale /tmp entries are a real win.

set -euo pipefail
export LC_ALL=C

DRY=0
DEEP=0
ASSUME_YES=0

usage() {
  sed -n '2,25p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --dry-run | --dry) DRY=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --help | -h) usage && exit 0 ;;
    *)
      echo "disk-cleanup: unknown option '$arg'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# run CMD... — execute, or print in dry-run. Failures never abort the sweep.
run() {
  if [[ $DRY -eq 1 ]]; then
    note "[dry-run] $*"
    return 0
  fi
  "$@" || note "warning: '$*' failed (continuing)"
}

# run_quiet CMD... — like run, but discards stdout (for tools that emit one line
# per reclaimed object, e.g. `podman prune`).
run_quiet() {
  if [[ $DRY -eq 1 ]]; then
    note "[dry-run] $*"
    return 0
  fi
  "$@" >/dev/null 2>&1 || note "warning: '$*' failed (continuing)"
}

size_of() {
  local p=$1
  [[ -e "$p" ]] || {
    echo "-"
    return 0
  }
  # `|| true`: du returns nonzero on unreadable subdirs; under pipefail that
  # would abort the whole script from a mere permission hiccup.
  du -sh "$p" 2>/dev/null | cut -f1 || echo "-"
}

free_h() { df -Ph / 2>/dev/null | awk 'NR==2 {print $4}'; }

# clear_dir DIR — remove the *contents* of DIR, keeping DIR itself.
clear_dir() {
  local d=$1
  [[ -d "$d" ]] || return 0
  local before
  before=$(size_of "$d")
  if [[ $DRY -eq 1 ]]; then
    note "[dry-run] clear $d (${before})"
    return 0
  fi
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  note "cleared $d (was ${before})"
}

# Names under /tmp that belong to the session/system and must never be removed,
# no matter how old they look. X11/ICE sockets and lock files are live IPC
# endpoints; the rest are long-lived per-user runtime dirs.
TMP_PROTECTED=(
  ".X11-unix" ".ICE-unix" ".XIM-unix" ".font-unix"
  ".X0-lock" ".wine-1000" ".minecraft" ".local"
)

# prune_old DIR DAYS [--tmp] — delete entries in DIR older than DAYS days.
# With --tmp: only touch entries owned by the current user, skip protected
# names, sockets, and anything root owns.
prune_old() {
  local d=$1 days=$2 mode=${3:-}
  [[ -d "$d" ]] || return 0

  local -a expr=("$d" -mindepth 1 -maxdepth 1 -mtime "+${days}")
  if [[ $mode == --tmp ]]; then
    expr+=(-user "$(id -un)" ! -type s)
    for p in "${TMP_PROTECTED[@]}"; do
      expr+=(! -name "$p")
    done
  fi

  local n
  n=$(find "${expr[@]}" 2>/dev/null | wc -l || echo 0)
  if [[ $DRY -eq 1 ]]; then
    note "[dry-run] remove ${n} entries older than ${days}d from $d"
    return 0
  fi
  find "${expr[@]}" -exec rm -rf -- {} + 2>/dev/null || true
  note "removed ${n} entries older than ${days}d from $d"
}

# ---------------------------------------------------------------------------
# confirmation
# ---------------------------------------------------------------------------

if [[ $DEEP -eq 1 && $DRY -eq 0 && $ASSUME_YES -eq 0 ]]; then
  printf '\033[1;33mDeep cleanup\033[0m removes ALL container images not used by a\n'
  printf 'running container, plus unused volumes. Images are re-pullable, but\n'
  printf 'this can be a large, slow re-download later.\n\n'
  read -r -p "Continue? [y/N] " ans
  [[ $ans == [yY] || $ans == [yY][eE][sS] ]] || {
    echo "aborted."
    exit 1
  }
fi

FREE_BEFORE=$(free_h)
printf '\033[1mdisk-cleanup\033[0m  (free before: %s)%s%s\n' \
  "$FREE_BEFORE" \
  "$([[ $DEEP -eq 1 ]] && echo '  [deep]' || true)" \
  "$([[ $DRY -eq 1 ]] && echo '  [dry-run]' || true)"

# ---------------------------------------------------------------------------
# 1. user caches (all re-downloadable)
# ---------------------------------------------------------------------------

step "User caches"

CACHE_DIRS=(
  "$HOME/.cache/.bun/install/cache" # bun package cache (~21G)
  "$HOME/.npm/_cacache"             # npm content-addressable cache (~6G)
  "$HOME/.cache/node-compile-cache"
  "$HOME/.cache/typescript"
  "$HOME/.cache/jiti"
  "$HOME/.cache/firebase"
  "$HOME/.cache/go-build"
  "$HOME/.cache/node-gyp"
  "$HOME/.cache/uv"
  "$HOME/.cache/pip"
  "$HOME/.cache/yarn"
  "$HOME/.cache/electron"
  "$HOME/.cache/tauri"
  "$HOME/.cache/wasmtime"
  "$HOME/.cache/nix"
  "$HOME/.cache/appimage-run"
  "$HOME/.cache/chromium-headless"
  "$HOME/.cache/spotify"
  "$HOME/.cache/google-chrome"
  "$HOME/.cache/zen"
  "$HOME/.cache/BraveSoftware"
  "$HOME/.cache/thunderbird"
  "/tmp/node-compile-cache"
  "/tmp/jiti"
)

for d in "${CACHE_DIRS[@]}"; do
  clear_dir "$d"
done

# pnpm keeps a content-addressable store. `pnpm store prune` is the correct way
# to trim it, but pnpm is not always on PATH here (it is run via bun/corepack).
# Fall back to clearing the store directly — it is a pure cache and pnpm
# re-fetches on demand.
if have pnpm; then
  run pnpm store prune
else
  clear_dir "$HOME/.local/share/pnpm/store"
fi

# ---------------------------------------------------------------------------
# 2. stale /tmp entries (root fs — never cleared on reboot here)
# ---------------------------------------------------------------------------

step "Stale /tmp entries (>3 days, user-owned only)"
prune_old /tmp 3 --tmp

# ---------------------------------------------------------------------------
# 3. trash
# ---------------------------------------------------------------------------

step "Trash"
if have gio; then
  run gio trash --empty
else
  clear_dir "$HOME/.local/share/Trash/files"
  clear_dir "$HOME/.local/share/Trash/info"
fi

# ---------------------------------------------------------------------------
# 4. containers (rootless podman — no sudo)
# ---------------------------------------------------------------------------

if have podman; then
  step "Container images / containers / build cache"
  # podman prints one hash per reclaimed object; swallow it so the sweep stays
  # readable.
  run_quiet podman container prune -f
  run_quiet podman image prune -f # dangling (<none>) only
  run_quiet podman builder prune -f

  if [[ $DEEP -eq 1 ]]; then
    step "Container images (all unused) + volumes  [deep]"
    run_quiet podman image prune -a -f
    run_quiet podman volume prune -f
  else
    note "unused images: $(podman system df 2>/dev/null | awk '/^Images/{print $5" reclaimable of "$4}') — use --deep to remove"
  fi
fi

# ---------------------------------------------------------------------------
# 5. journald (needs sudo)
# ---------------------------------------------------------------------------

step "Journald vacuum (200M cap)"
if sudo -n true 2>/dev/null; then
  run sudo journalctl --vacuum-size=200M
elif [[ $DRY -eq 1 ]]; then
  note "[dry-run] sudo journalctl --vacuum-size=200M"
elif [[ -t 0 ]]; then
  run sudo journalctl --vacuum-size=200M
else
  note "sudo needs a password — run 'sudo journalctl --vacuum-size=200M' yourself"
fi

# ---------------------------------------------------------------------------
# 6. nix store garbage collection (needs sudo)
# ---------------------------------------------------------------------------

step "Nix store GC (drops old generations)"
if sudo -n true 2>/dev/null; then
  run sudo nix-collect-garbage -d
elif [[ $DRY -eq 1 ]]; then
  note "[dry-run] sudo nix-collect-garbage -d"
elif [[ -t 0 ]]; then
  run sudo nix-collect-garbage -d
else
  note "sudo needs a password — run 'sudo nix-collect-garbage -d' yourself"
fi

# ---------------------------------------------------------------------------
# 7. deep-only extras
# ---------------------------------------------------------------------------

if [[ $DEEP -eq 1 ]]; then
  step "Editor / agent caches  [deep]"
  clear_dir "$HOME/.local/share/zed/node" # re-fetched by zed
  prune_old "$HOME/.herdr/worktrees" 7    # stale agent git worktrees
  prune_old "$HOME/Downloads/tmp" 30      # old scratch downloads
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

FREE_AFTER=$(free_h)
printf '\n\033[1;32m==>\033[0m done — free: %s → %s\n' "$FREE_BEFORE" "$FREE_AFTER"
df -Ph / 2>/dev/null | awk 'NR==2 {printf "    root filesystem: %s used of %s (%s)\n", $3, $2, $5}' || true
