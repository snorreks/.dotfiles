#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-stats.sh
#
# One-shot JSON snapshot for the QML dashboard's SystemView (qml/Sys.qml polls
# this on a Timer — same "spawn a tiny script" pattern waybar's custom exec
# modules use, not a long-lived stream). The timer only runs while SystemView
# is the visible tab, so this costs nothing with the panel closed or on Home.
#
# `load`/`cores` reuse the exact 1-min-loadavg-over-core-count signal
# sys-daemon's idle.rs already uses for "is the CPU busy" — one metric, not two
# different ideas of "CPU usage" living side by side.

set -eu

load=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)

# One pass over /proc/meminfo for both memory and swap.
eval "$(awk '
    /^MemTotal:/     { mt = $2 }
    /^MemAvailable:/ { ma = $2 }
    /^SwapTotal:/    { st = $2 }
    /^SwapFree:/     { sf = $2 }
    END {
        printf "mem_total=%d\nmem_used=%d\nswap_total=%d\nswap_used=%d\n",
               mt, mt - ma, st, st - sf
    }
' /proc/meminfo)"

mem_pct=$((mem_total > 0 ? mem_used * 100 / mem_total : 0))
swap_pct=$((swap_total > 0 ? swap_used * 100 / swap_total : 0))

# -P: POSIX output, so the filesystem/mount columns never wrap onto a second
# line and shift the fields this reads.
disk=$(df -Pk / | awk 'NR == 2 { printf "%d %d", $2, $3 }')
disk_total=${disk% *}
disk_used=${disk#* }
disk_pct=$((disk_total > 0 ? disk_used * 100 / disk_total : 0))

uptime_s=$(awk '{print int($1)}' /proc/uptime)

# Highest thermal zone reading wins — on a laptop that's reliably the CPU
# package under load; missing thermal_zone entries (VMs, some hardware) degrade
# to 0 rather than failing the whole snapshot.
temp_milli=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
temp_c=$(((${temp_milli:-0}) / 1000))

# Top processes by CPU. 12 is enough to fill SystemView's list card on a tall
# panel; the card scrolls if it doesn't fit. Still one `ps` spawn either way.
#
# `comm` not `args`, so the JSON stays short and never has to escape a command
# line full of quotes and paths. `ps` always ranks near the top of its own
# output, so it is dropped.
top=$(ps -eo comm=,pcpu=,pmem= --sort=-pcpu 2>/dev/null | awk '
    BEGIN { sep = ""; n = 0 }
    $1 == "ps" { next }
    n < 12 {
        gsub(/["\\]/, "", $1)
        printf "%s{\"name\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f}", sep, $1, $2, $3
        sep = ","
        n++
    }
')

printf '{"load":%s,"cores":%s,"mem_pct":%s,"mem_used_kb":%s,"mem_total_kb":%s,"swap_pct":%s,"disk_pct":%s,"disk_used_kb":%s,"disk_total_kb":%s,"uptime_s":%s,"temp_c":%s,"top":[%s]}\n' \
    "$load" "$cores" "$mem_pct" "$mem_used" "$mem_total" "$swap_pct" \
    "$disk_pct" "$disk_used" "$disk_total" "$uptime_s" "$temp_c" "$top"
