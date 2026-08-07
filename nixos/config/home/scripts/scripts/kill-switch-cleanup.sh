#!/usr/bin/env bash
# kill-switch-cleanup.sh — Privileged kernel memory cleanup helper.
# Called via sudo from kill-switch.sh; do NOT run directly.
# Outputs key=value lines for the caller to consume.
set -euo pipefail

dropped_mb=0
swap_cleared=0

# 1. Sync filesystem buffers to disk
sync

# 2. Drop pagecache, dentries, and inodes
_before=$(free -m | awk '/^Mem:/{print $6}' 2>/dev/null || echo "0")
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
_after=$(free -m | awk '/^Mem:/{print $6}' 2>/dev/null || echo "0")
dropped_mb=$((_before - _after))
[[ "$dropped_mb" -lt 0 ]] && dropped_mb=0

# 3. Compact memory (defragment for large allocations)
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

# 4. Clear swap (restart swap units via systemd for NixOS compatibility)
_swap_used_kb=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t - f}' /proc/meminfo 2>/dev/null || echo "0")
_swap_used_kb=${_swap_used_kb:-0}
_total_ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
_total_ram_kb=${_total_ram_kb:-0}
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
