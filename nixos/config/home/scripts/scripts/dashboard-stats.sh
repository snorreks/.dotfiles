#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-stats.sh
#
# One-shot JSON snapshot for the QML dashboard's CPU/mem/temp tile
# (dashboard/shell.qml polls this on a Timer — same "spawn a tiny script"
# pattern waybar's custom exec modules use, not a long-lived stream, since
# this is only read while the dashboard panel is open).
#
# `load`/`cores` reuse the exact 1-min-loadavg-over-core-count signal
# sys-daemon's idle.rs already uses for "is the CPU busy" — one metric,
# not two different ideas of "CPU usage" living side by side.

set -eu

load=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)

mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
mem_pct=$(((mem_total - mem_avail) * 100 / mem_total))

# Highest thermal zone reading wins — on a laptop that's reliably the CPU
# package under load; missing thermal_zone entries (VMs, some hardware)
# degrade to 0 rather than failing the whole snapshot.
temp_milli=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
temp_c=$(((${temp_milli:-0}) / 1000))

printf '{"load":%s,"cores":%s,"mem_pct":%s,"temp_c":%s}\n' \
    "$load" "$cores" "$mem_pct" "$temp_c"
