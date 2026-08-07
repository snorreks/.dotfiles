# clear-ram — Free up RAM, drop caches, clear swap, kill hung processes.
# Safe to run anytime. Requires sudo for cache drop.
#
# Usage:  clear-ram            → interactive (asks before killing)
#         clear-ram --force    → skip prompts, kill all found junk
#         clear-ram --safe     → only drop caches, no process killing

function clear-ram
  set -l RED '\033[0;31m'
  set -l GREEN '\033[0;32m'
  set -l YELLOW '\033[1;33m'
  set -l CYAN '\033[0;36m'
  set -l NC '\033[0m'
  set -l BOLD '\033[1m'
  set -l INFO "$CYAN[i]$NC"
  set -l OK "$GREEN[✓]$NC"
  set -l WARN "$YELLOW[!]$NC"
  set -l ERR "$RED[✗]$NC"

  function _divider
    echo -e "\n$BOLD━━━ $argv[1] ━━━$NC\n"
  end

  set -l MODE $argv[1]
  test -z "$MODE"; and set MODE "interactive"

  # ── 1. SHOW BEFORE ────────────────────────────────────────────────
  _divider "📊  BEFORE"
  free -h
  echo
  uptime
  echo

  # ── 2. FIND CULPRIT PROCESSES ─────────────────────────────────────
  _divider "🔍  TOP RAM / CPU HOGS"

  echo -e "$BOLD""Top 5 by RAM:$NC"
  ps aux --sort=-%mem | awk 'NR>1 && NR<=6 {
      printf "  PID %-8s  CPU %5s%%  MEM %5s%%  %s\n", $2, $3, $4, $NF
  }'

  set -l cpu_hogs (ps aux --sort=-%cpu | awk 'NR>1 && NR<=6 && $3>50 {
      printf "  PID %-8s  CPU %5s%%  MEM %5s%%  %s\n", $2, $3, $4, $NF
  }')
  if test (count $cpu_hogs) -gt 0
    echo
    echo -e "$BOLD""High CPU (>50%):$NC"
    printf '%s\n' $cpu_hogs
  end

  # Find zombie/defunct/stuck processes
  echo
  echo -e "$BOLD""Zombie processes:$NC"
  set -l zombies (ps aux | awk '$8 ~ /Z|D/ {printf "  PID %-8s  STAT %-3s  %s\n", $2, $8, $NF}')
  if test -z "$zombies"
    echo "  $GREEN""none$NC"
  else
    echo "$zombies"
  end

  # ── 3. FIND HUNG WINE / PROTON / STEAM GAME PROCESSES ─────────────
  set -l KILL_LIST
  echo
  echo -e "$BOLD""Wine/Proton/Game processes:$NC"

  set -l game_procs (ps aux | awk 'NR>1 && (
      /\.exe/ || /wine/ || /proton/i || /battle\.net/i || /steamwebhelper/ ||
      /cef/i || /C:\\\\Program Files/ || /Z:\\\\mnt/ || /Games/i
  ) {
      printf "  PID %-8s  CPU %5s%%  MEM %5s%%  %s\n", $2, $3, $4, $NF
  }')

  if test -z "$game_procs"
    echo "  $GREEN""none found$NC"
  else
    echo "$game_procs"
    set KILL_LIST $game_procs
  end

  # ── 4. KILL (if applicable) ───────────────────────────────────────
  if test "$MODE" = "--safe"
    echo -e "\n$INFO --safe mode: skipping process kills"
  else if test (count $KILL_LIST) -gt 0
    # Extract just the PIDs
    set -l PIDS (ps aux | awk 'NR>1 && (
        /\.exe/ || /wine/ || /proton/i || /battle\.net/i || /steamwebhelper/ ||
        /cef/i || /C:\\\\Program Files/ || /Z:\\\\mnt/ || /Games/i
    ) { print $2 }' | sort -u)

    if test -n "$PIDS"
      echo
      if test "$MODE" = "--force"
        echo "$WARN Force-killing game/Proton processes..."
        for pid in $PIDS
          kill -9 "$pid" 2>/dev/null; or true
        end
        sleep 1
        echo "$OK Killed."
      else
        echo -n "$WARN Kill these processes? [y/N] "
        read -l answer
        if string match -rq '^[Yy]' "$answer"
          for pid in $PIDS
            kill -9 "$pid" 2>/dev/null; or true
          end
          sleep 1
          echo "$OK Killed."
        else
          echo "$INFO Skipping."
        end
      end
    end
  end

  # ── 5. DROP SYSTEM CACHES ─────────────────────────────────────────
  _divider "🧹  DROPPING CACHES"

  set -l CACHED_BEFORE (awk '/^Cached:/ {print $2}' /proc/meminfo)
  set -l CACHED_GB (math "$CACHED_BEFORE / 1024 / 1024")
  echo "$INFO Cached before: "$CACHED_GB"G"

  set -l is_root (test (id -u) -eq 0; and echo true; or echo false)
  set -l has_sudo (sudo -n true 2>/dev/null; and echo true; or echo false)

  if test "$is_root" = "true" -o "$has_sudo" = "true"
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    sleep 1
    set -l CACHED_AFTER (awk '/^Cached:/ {print $2}' /proc/meminfo)
    set -l CACHED_AFTER_GB (math "$CACHED_AFTER / 1024 / 1024")
    set -l FREED (math "($CACHED_BEFORE - $CACHED_AFTER) / 1024 / 1024")
    echo "$OK Cache dropped. Freed ~"$FREED"G  ("$CACHED_AFTER_GB"G remaining)"
  else
    echo "$WARN No sudo access — cannot drop page cache."
    echo "      Run with sudo:  sudo clear-ram"
  end

  # ── 6. RECLAIM SLAB CACHE ─────────────────────────────────────────
  set -l SLAB_BEFORE (awk '/^SReclaimable:/ {print $2}' /proc/meminfo)
  if test "$is_root" = "true" -o "$has_sudo" = "true"
    sudo sh -c 'echo 2 > /proc/sys/vm/drop_caches' 2>/dev/null; or true
    sleep 0.5
    set -l SLAB_AFTER (awk '/^SReclaimable:/ {print $2}' /proc/meminfo)
    set -l SLAB_FREED (math "($SLAB_BEFORE - $SLAB_AFTER) / 1024")
    if test "$SLAB_FREED" -gt 0
      echo "$OK Slab reclaimed: "$SLAB_FREED"MB freed"
    end
  end

  # ── 7. CLEAR SWAP (if safe) ───────────────────────────────────────
  _divider "💾  SWAP"
  set -l SWAP_USED (awk '/SwapTotal:/ {total=$2} /SwapFree:/ {free=$2} END {print total-free}' /proc/meminfo 2>/dev/null; or echo 0)
  set -l SWAP_USED_MB (math "$SWAP_USED / 1024")
  echo "$INFO Swap used: "$SWAP_USED_MB"MB"

  if test "$SWAP_USED" -gt 1048576; and begin; test "$is_root" = "true"; or test "$has_sudo" = "true"; end
    echo "$INFO Turning swap off and on to clear..."
    sudo swapoff -a 2>/dev/null && sudo swapon -a 2>/dev/null; or true
    echo "$OK Swap cleared."
  else if test "$SWAP_USED" -le 1048576
    echo "$OK Swap usage is low, skipping."
  else
    echo "$WARN Cannot clear swap (needs sudo). Run: sudo swapoff -a && sudo swapon -a"
  end

  # ── 8. FINAL REPORT ───────────────────────────────────────────────
  _divider "📊  AFTER"
  free -h
  echo
  echo -e "$BOLD""Cache before:$NC  "$CACHED_GB"G"
  set -l CACHED_NOW (awk '/^Cached:/ {print $2}' /proc/meminfo)
  echo -e "$BOLD""Cache now:$NC     $(math "$CACHED_NOW / 1024 / 1024")G"
  echo
  echo -e "$GREEN$BOLD""Done!$NC Your system should feel snappier now."
end
