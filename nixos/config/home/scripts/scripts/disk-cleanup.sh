#!/usr/bin/env bash
# disk-cleanup.sh — reclaim disk space from caches and report the rest.
#
#   (default)   Re-downloadable caches only, and only the ones no running
#               process is currently using:
#                 - package-manager + app caches (bun, npm, go, uv, pip, …)
#                 - trash
#                 - dangling container images, stopped containers, build cache
#                 - journald vacuum to 200M
#               Everything that is NOT purely re-downloadable is reported, not
#               deleted: old /tmp entries, herdr worktrees, unused container
#               volumes, and the Nix store.
#   --deep      The default, plus unused (non-dangling) container images and
#               editor/agent caches. Still no volume pruning, still no worktree
#               deletion, still no age-based /tmp deletion.
#   --gc        Opt in to running a Nix store collection. NEVER deletes
#               generations; GC roots (including the recovery closures ns-maint
#               pins) are honoured by the collector.
#   --prune-worktrees
#               Opt in to removing herdr worktrees. Only ever removes one that
#               is clean, has no untracked files, is not the current worktree
#               and is not registered with a running herdr. See
#               prune_worktrees() for the full list of reasons something is kept.
#   --tmp       Opt in to removing stale /tmp entries. Only entries owned by
#               you, no sockets, no protected names, and nothing any live
#               process has open.
#   --dry-run   Print what would be removed; change nothing. THIS IS THE
#               DEFAULT-COMPATIBLE MODE, and it is also what the safety tests
#               run, because a cleanup script that can delete is not testable on
#               the machine it runs on.
#   --yes       Skip the confirmation prompt (for cron / systemd timers).
#   --help      Show this help.
#
# Rootless podman needs no sudo. The journald vacuum and store collection use
# sudo when available and are skipped (with a note) otherwise.
#
# ── What changed, and why ────────────────────────────────────────────────────
# The previous version of this script did four things that had no business
# running unattended on a machine reached only over a tailnet:
#
#   1. `nix-collect-garbage -d` in the DEFAULT sweep. `-d` deletes generations,
#      and a deleted generation is a deleted way back. Collection is now opt-in
#      (--gc) and never passes -d.
#   2. `podman volume prune` under --deep. Volumes are stopped services' data —
#      a database, a Jellyfin library index, a qBittorrent resume file. They are
#      now reported and never pruned.
#   3. `find ~/.herdr/worktrees -mtime +7 -exec rm -rf`. Directory mtime is not a
#      liveness test: a three-week-old worktree with uncommitted work in it looks
#      exactly like an abandoned one, and `rm -rf` does not care. Worktrees are
#      now opt-in (--prune-worktrees) and only removed when provably
#      clean, provably untracked-free, not current, and not owned by a running
#      herdr server.
#   4. Age-based /tmp deletion at 3 days as part of the DEFAULT sweep. /tmp
#      holds live agent sockets and IPC endpoints. It is now opt-in (--tmp),
#      threshold is 14 days, and anything with an open file descriptor or a
#      listening socket is skipped.
#
# Every deletion is additionally gated on `in_use`: a cache directory a running
# service has open is reported and left alone. Clearing the bun cache under a
# running agent is not a cache cleanup, it is a bug report waiting to happen.

set -euo pipefail
export LC_ALL=C

DRY=0
DEEP=0
unused_vols=""
scratch=""

ASSUME_YES=0
DO_GC=0
DO_PRUNE_WORKTREES=0
DO_TMP=0
TMP_AGE_DAYS=14
WORKTREE_AGE_DAYS=7

usage() {
  sed -n '2,40p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --gc) DO_GC=1 ;;
    --prune-worktrees) DO_PRUNE_WORKTREES=1 ;;
    --tmp) DO_TMP=1 ;;
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

# in_use DIR — is any live process holding something open under DIR?
#
# This is the "service-aware" part. A cache directory that an agent, a build or
# a service has mapped is not reclaimable no matter how old its contents are.
# Prefer lsof's recursive directory check. With only fuser, inspect the
# directory and every entry beneath it. No checker means in use: skip deletion.
in_use() {
  local d=$1
  if have lsof; then
    if [[ -d "$d" ]]; then
      lsof +D "$d" >/dev/null 2>&1 && return 0
    else
      lsof -- "$d" >/dev/null 2>&1 && return 0
    fi
    return 1
  fi
  if have fuser; then
    local entry
    while IFS= read -r -d '' entry; do
      fuser -s -- "$entry" >/dev/null 2>&1 && return 0
    done < <(find "$d" -print0 2>/dev/null)
    return 1
  fi
  note "cannot check whether $d is in use (no fuser/lsof) — skipping it"
  return 0
}

# clear_dir DIR — remove the *contents* of DIR, keeping DIR itself.
clear_dir() {
  local d=$1
  [[ -d "$d" ]] || return 0

  if in_use "$d"; then
    note "SKIPPED (in use by a running process): $d"
    return 0
  fi

  local before
  before="$(size_of "$d")"
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

# prune_tmp — opt-in (/tmp flag), 14 days, yours only, sockets and protected
# names excluded, and nothing with an open descriptor removed.
prune_tmp() {
  local d=/tmp
  if [[ $DO_TMP -eq 0 ]]; then
    local n
    n=$(find "$d" -mindepth 1 -maxdepth 1 -mtime "+${TMP_AGE_DAYS}" 2>/dev/null | wc -l || echo 0)
    note "stale /tmp entries (>${TMP_AGE_DAYS}d): $n (not removed — pass --tmp to act,"
    note "  after checking nothing you care about is in there)"
    return 0
  fi

  step "Stale /tmp entries (>${TMP_AGE_DAYS}d, yours only, no sockets, nothing in use)"

  local -a expr=("$d" -mindepth 1 -maxdepth 1 -mtime "+${TMP_AGE_DAYS}")
  expr+=(-user "$(id -un)" ! -type s)
  local p
  for p in "${TMP_PROTECTED[@]}"; do
    expr+=(! -name "$p")
  done

  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ -n "$(find "$candidate" ! -type d -a \( -type s -o -type p \) 2>/dev/null | head -1)" ]]; then
      note "SKIPPED (contains a socket or fifo): $candidate"
      continue
    fi
    if in_use "$candidate"; then
      note "SKIPPED (open by a running process): $candidate"
      continue
    fi
    if [[ $DRY -eq 1 ]]; then
      note "[dry-run] rm -rf $candidate"
    else
      rm -rf -- "$candidate" 2>/dev/null || note "warning: could not remove $candidate"
      note "removed $candidate"
    fi
  done < <(find "${expr[@]}" 2>/dev/null || true)
}

# prune_worktrees — opt-in, and deliberately timid.
#
# A git worktree is removed only when ALL of these hold. Anything else and it is
# reported and left exactly where it is:
#
#   * it is not the worktree you are standing in
#   * `git status --porcelain` is empty          (no modified, no staged)
#   * `git status --porcelain --ignored=no` finds no untracked files either
#   * `herdr worktree list` does not have it registered to an open workspace
#   * it is older than WORKTREE_AGE_DAYS
#
# Age is the LAST check, not the first. That ordering is the whole fix: an old
# directory is not evidence of an abandoned one, so it can never on its own
# authorise a deletion.
prune_worktrees() {
  local root="$HOME/.herdr/worktrees"
  if [[ $DO_PRUNE_WORKTREES -eq 0 ]]; then
    report_worktrees
    return 0
  fi

  step "herdr worktrees [opt-in, clean+untracked-free+unowned only]"

  local current
  current="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  local wt status_line wtrepo
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    if [[ -z "$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)" ]]; then
      note "SKIPPED (not a git worktree): $wt"
      continue
    fi
    if [[ "$wt" == "$current" ]]; then
      note "SKIPPED (this is your current worktree): $wt"
      continue
    fi
    status_line="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
    if [[ -n "$status_line" ]]; then
      note "SKIPPED (uncommitted or untracked work present): $wt"
      continue
    fi
    if grep -qF "\"path\":\"$wt\"" <<<"$herdr_worktrees_json"; then
      note "SKIPPED (registered with a running herdr server): $wt"
      continue
    fi
    if ! find "$wt" -maxdepth 0 -mtime "+${WORKTREE_AGE_DAYS}" | grep -q .; then
      note "SKIPPED (younger than ${WORKTREE_AGE_DAYS}d): $wt"
      continue
    fi
    # `git worktree remove` only works from inside the repository that OWNS the
    # worktree. disk-cleanup.sh is a shell script an operator runs from wherever
    # they happen to be, and $HOME is not a git repository, so resolve the owning
    # repository first and run it from there. Without this the removal is
    # refused and — worse — silently looks like a successful candidate.
    local common
    common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [[ -n "$common" && -d "$common" ]] || common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" && -d "$common" ]]; then
      wtrepo="$common"
    else
      wtrepo="$wt"
    fi

    if [[ $DRY -eq 1 ]]; then
      note "[dry-run] git -C $wtrepo worktree remove $wt"
    elif git -C "$wtrepo" worktree remove "$wt" 2>/dev/null; then
      note "removed worktree $wt"
    else
      # Say what actually happened. Reporting "removed" after a refused removal
      # is how an operator ends up believing a directory is gone that is not.
      note "warning: git worktree remove refused for $wt — it is still there"
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name .git -printf '%h\n' 2>/dev/null || true)
}

# report_worktrees — list, never delete.
report_worktrees() {
  local root="$HOME/.herdr/worktrees"
  [[ -d "$root" ]] || return 0
  local total dirty n=0
  total="$(find "$root" -mindepth 2 -maxdepth 2 -name .git 2>/dev/null | wc -l || echo 0)"
  [[ "$total" -gt 0 ]] || return 0

  dirty=0
  local wt
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ]]; then
      dirty=$((dirty + 1))
    fi
    n=$((n + 1))
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name .git -printf '%h\n' 2>/dev/null || true)

  note "herdr worktrees: $n present, $dirty with uncommitted or untracked work"
  note "  not deleted. Cleaning one means you already decided it was junk:"
  note "    git -C <worktree> status   # then, if it is genuinely empty:"
  note "    git worktree remove <path>"
  note "  or run this script with --prune-worktrees, which still requires clean +"
  note "  untracked-free + not current + not registered with a running herdr."
}

# ---------------------------------------------------------------------------
# confirmation
# ---------------------------------------------------------------------------

DESTRUCTIVE=""
[[ $DEEP -eq 1 ]] && DESTRUCTIVE="deep mode"
[[ $DO_GC -eq 1 ]] && DESTRUCTIVE="$DESTRUCTIVE${DESTRUCTIVE:+, }store collection"
[[ $DO_PRUNE_WORKTREES -eq 1 ]] && DESTRUCTIVE="$DESTRUCTIVE${DESTRUCTIVE:+, }worktree pruning"
[[ $DO_TMP -eq 1 ]] && DESTRUCTIVE="$DESTRUCTIVE${DESTRUCTIVE:+, }/tmp pruning"

if [[ -n "$DESTRUCTIVE" && $DRY -eq 0 && $ASSUME_YES -eq 0 ]]; then
  printf '\033[1;33mThis run will also:\033[0m %s\n\n' "$DESTRUCTIVE"
  printf 'Dry-run first if you have not:  disk-cleanup --dry-run\n\n'
  # `|| true`: a non-interactive invocation (cron, a timer, a closed stdin) must
  # reach the abort message below rather than dying on `read` under `set -e`,
  # which is the same outcome but with no explanation.
  read -r -p "Continue? [y/N] " ans || true
  [[ $ans == [yY] || $ans == [yY][eE][sS] ]] || {
    echo "aborted."
    exit 1
  }
fi

# Which worktrees a running herdr server knows about. Read-only; used only to
# decide what NOT to touch.
herdr_worktrees_json=""
if have herdr; then
  herdr_worktrees_json="$(herdr worktree list --cwd "$HOME/.dotfiles" 2>/dev/null || true)"
fi

FREE_BEFORE=$(free_h)
printf '\033[1mdisk-cleanup\033[0m  (free before: %s)%s%s%s%s%s\n' \
  "$FREE_BEFORE" \
  "$([[ $DEEP -eq 1 ]] && echo '  [deep]' || true)" \
  "$([[ $DO_GC -eq 1 ]] && echo '  [gc]' || true)" \
  "$([[ $DO_PRUNE_WORKTREES -eq 1 ]] && echo '  [worktrees]' || true)" \
  "$([[ $DO_TMP -eq 1 ]] && echo '  [tmp]' || true)" \
  "$([[ $DRY -eq 1 ]] && echo '  [dry-run]' || true)"

# ---------------------------------------------------------------------------
# 1. user caches (all re-downloadable, and none of them in use)
# ---------------------------------------------------------------------------

step "User caches (skipped when a running process has them open)"

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

# ~/.cache/nix is NOT in the list, on purpose: it holds a git repository and
# sqlite databases that must be able to be opened by libgit2. Deleting it breaks
# `nh` with a confusing "could not find repository" error. config/system/
# cache-cleanup.nix excludes the same path from tmpfiles aging for the same
# reason.

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
# 2. stale /tmp entries — opt-in only
# ---------------------------------------------------------------------------

step "Stale /tmp entries"
prune_tmp

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
    step "Container images (all unused)  [deep]"
    run_quiet podman image prune -a -f
  else
    note "unused images: $(podman system df 2>/dev/null | awk '/^Images/{print $5" reclaimable of "$4}') — use --deep to remove"
  fi

  # Volumes: REPORTED, NEVER PRUNED.
  #
  # The old --deep ran `podman volume prune -f` here. A volume is a stopped
  # service's data, not a cache: a database, a library index, a resume file, an
  # encryption key. Nothing here can tell whether a volume is abandoned, and
  # "the container that used it was removed two months ago" is not evidence that
  # the data is worthless. If you know a volume is junk:
  #     podman volume ls
  #     podman volume rm <name>
  unused_vols="$(podman volume ls --filter dangling=true --format '{{.Name}}' 2>/dev/null || true)"
  if [[ -n "$unused_vols" ]]; then
    step "Unused container volumes — REPORTED, NOT REMOVED"
    while IFS= read -r v; do
      [[ -n "$v" ]] && note "$v ($(size_of "$HOME/.local/share/containers/storage/volumes/$v/_data"))"
    done <<<"$unused_vols"
    note "removed nothing. A volume holds a stopped service's data; decide per volume:"
    note "  podman volume rm <name>"
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
# 6. Nix store collection — OPT-IN, and never -d
# ---------------------------------------------------------------------------

step "Nix store collection"
if [[ $DO_GC -eq 0 ]]; then
  note "not run. Collection is opt-in (--gc) because it is the one step here that"
  note "can remove something you cannot re-download."
  note "Even with --gc, generations are KEPT: this runs nix-collect-garbage without -d."
  note "GC roots — including the recovery closures ns-maint pins for a pending"
  note "transaction — are honoured by the collector, so pinned closures survive."
  note "To collect now:  disk-cleanup --gc      (add --dry-run to preview)"
else
  if sudo -n true 2>/dev/null; then
    run sudo nix-collect-garbage
  elif [[ $DRY -eq 1 ]]; then
    note "[dry-run] sudo nix-collect-garbage"
  elif [[ -t 0 ]]; then
    run sudo nix-collect-garbage
  else
    note "sudo needs a password — run 'sudo nix-collect-garbage' yourself"
    note "(note: plain nix-collect-garbage; do NOT add -d — -d deletes generations)"
  fi
fi

# ---------------------------------------------------------------------------
# 7. herdr worktrees — opt-in only
# ---------------------------------------------------------------------------

step "herdr worktrees"
prune_worktrees

# ---------------------------------------------------------------------------
# 8. deep-only extras (still no volumes, still no generations)
# ---------------------------------------------------------------------------

if [[ $DEEP -eq 1 ]]; then
  step "Editor / agent caches  [deep]"
  clear_dir "$HOME/.local/share/zed/node" # re-fetched by zed
  # ~/Downloads/tmp is a scratch directory of the user's own files. It is
  # reported, not deleted: "older than 30 days" is not a reason to throw away
  # something a person downloaded and then forgot about.
  scratch="$(find "$HOME/Downloads/tmp" -mindepth 1 -maxdepth 1 -mtime +30 2>/dev/null | wc -l || echo 0)"
  if [[ "$scratch" -gt 0 ]]; then
    note "$scratch entries under ~/Downloads/tmp are older than 30d — not removed."
    note "  Look before deleting: this is a person's files, not a cache."
  fi
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

FREE_AFTER=$(free_h)
printf '\n\033[1;32m==>\033[0m done — free: %s → %s\n' "$FREE_BEFORE" "$FREE_AFTER"
df -Ph / 2>/dev/null | awk 'NR==2 {printf "    root filesystem: %s used of %s (%s)\n", $3, $2, $5}' || true