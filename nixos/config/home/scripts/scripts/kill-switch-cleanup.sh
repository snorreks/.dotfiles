#!/usr/bin/env bash
# kill-switch-cleanup.sh — Privileged kernel memory cleanup helper.
# Called via sudo from kill-switch.sh; do NOT run directly.
# Outputs key=value lines for the caller to consume.
#
# ── Why this is now opt-out on an unattended host ─────────────────────────────
# Both things this does are desktop recovery moves, and on a machine that is
# only reached over the tailnet they make things worse rather than better:
#
#   * dropping the page cache evicts the working set of everything currently
#     running — sshd, tailscaled, the multiplexer, every agent — and those
#     processes then have to fault it all back in from disk. The machine is
#     briefly LESS responsive, not more, which is the opposite of the intent.
#   * cycling swap restarts the swap units under any process that still has
#     pages in them.
#
# On Linux, `echo 3 > drop_caches` has done essentially nothing since 2.6 — the
# pages come straight back — so the cost is paid and the benefit is not. It
# stays for the frozen-desktop case it was written for, and refuses when the
# host says it is an unattended server (NS_SERVER_MODE=1, set by
# config/home/fish/default.nix on headless hosts).
#
# `--force` overrides the server guard for a human who has weighed it. The
# helper reports what it skipped, rather than failing silently: the caller prints
# the key=value output verbatim, so "skipped" is visible.
set -euo pipefail
export LC_ALL=C

FORCE=0

usage() {
  sed -n '2,25p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --force | -f) FORCE=1 ;;
    --help | -h) usage; exit 0 ;;
    *)
      echo "kill-switch-cleanup: unknown option '$arg'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

dropped_mb=0
swap_cleared=0

server_mode="${NS_SERVER_MODE:-0}"
if [[ "$server_mode" == "1" && "$FORCE" -ne 1 ]]; then
  # Not an error: kill-switch turns a nonzero exit into "(cleanup not
  # authorized)". Printing the reason and returning cleanly is more accurate.
  echo "skipped=server-mode"
  echo "skipped_reason=dropping the page cache and cycling swap briefly makes an unattended host less responsive; re-run with --force if you have weighed that"
  echo "dropped_mb=0"
  echo "swap_cleared=0"
  exit 0
fi

# 1. Sync filesystem buffers to disk. This one is unconditional even on a server:
# flushing dirty pages is never harmful, and it is what makes the rest of a
# forced shutdown survivable.
sync

# 2. Drop pagecache, dentries, and inodes
_memfield() { awk -v k="$1" '$1 == k {print $2; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || echo 0; }

_before=$(_memfield MemFree)
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
_after=$(_memfield MemFree)
dropped_mb=$((_after - _before))
[[ "$dropped_mb" -lt 0 ]] && dropped_mb=0

# 3. Compact memory (defragment for large allocations)
echo 1 >/proc/sys/vm/compact_memory 2>/dev/null || true

# 4. Clear swap by restarting the swap units (systemd units on NixOS, so this is
#    not a raw swapon/off on a device).
#
#    The guard is: only when swap is barely in use. A machine that is heavily
#    swapping has pages in swap that belong to processes which are still running
#    — evicting them there is the one case where this helper could turn a slow
#    machine into a crashed one, so that case is excluded rather than treated as
#    the most deserving one.
_swap_used_kb=$(_memfield SwapTotal)
_swap_free_kb=$(_memfield SwapFree)
_swap_used_kb=$((_swap_used_kb - _swap_free_kb))
[[ "$_swap_used_kb" -lt 0 ]] && _swap_used_kb=0
_total_ram_kb=$(_memfield MemTotal)
[[ "$_total_ram_kb" -gt 0 ]] || _total_ram_kb=0
_swap_limit_kb=$((_total_ram_kb / 4))

if [[ "$_swap_used_kb" -gt 0 && "$_swap_used_kb" -lt "$_swap_limit_kb" ]]; then
  _swap_units=$(systemctl list-units --type=swap --no-legend -q 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
  if [[ -n "${_swap_units// }" ]]; then
    # shellcheck disable=SC2086
    systemctl stop $_swap_units 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2086
    systemctl start $_swap_units 2>/dev/null || true
    swap_cleared=1
  fi
fi

echo "dropped_mb=$dropped_mb"
echo "swap_cleared=$swap_cleared"