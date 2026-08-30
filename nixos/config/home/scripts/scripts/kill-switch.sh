#!/usr/bin/env bash
# Emergency Kill Switch
#
#   --light (default)  Terminate runaway dev/build processes AND webview runaways
#                      (node, bun, vite, cargo, rust debug binaries, WebKit*, Tauri apps).
#                      NEVER touches browsers, Discord, Spotify, or other GUI apps.
#   --full             Terminate ALL non-essential user applications (incl. browsers),
#                      preserving system desktop services (compositor "mango", Waybar,
#                      Pipewire, Xwayland, portals, ...). Browsers die instantly.
#   --reboot           Reboot the machine — the reliable recovery for a GPU/system
#                      hang. Authorized via polkit; falls back to a full sweep if
#                      the reboot is not permitted.
#   --dry-run          Show what would be terminated (without killing anything).
#
# After the sweep the script scans the kernel log (journalctl -k / dmesg) for GPU/system
# hang indicators (i915/NVIDIA/amdgpu hangs, Xid, soft lockups, RCU stalls, hung tasks)
# and reports them — user-space kills cannot unwedge a hung GPU engine.

set -euo pipefail
export LC_ALL=C

MODE=""
DRY=0

usage() {
  sed -n '2,13p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --light | --full | --reboot) MODE="$arg" ;;
    --dry-run | --dry) DRY=1 ;;
    --help | -h) usage && exit 0 ;;
    *)
      echo "kill-switch: unknown option '$arg'" >&2
      usage >&2
      exit 1
      ;;
  esac
done
MODE="${MODE:---light}"

CUR_USER="$(id -un)"
LOG_FILE="/tmp/kill-switch.log"
LOCK_FILE="/tmp/kill-switch.lock"

# Refuse to run as root: a kill switch must only ever touch the calling user's
# own processes. (The privileged cleanup helper is invoked via `sudo -n` separately.)
[[ "$(id -u)" -eq 0 ]] && {
  echo "kill-switch: refusing to run as root." >&2
  exit 1
}

# ── Single-instance lock (prevents concurrent kill-switch races) ────────────
exec 9>"$LOCK_FILE"
flock -n 9 || {
  echo "kill-switch: another instance is already running — aborting." >&2
  exit 1
}

# ── Helpers (every potentially-blocking command is bounded) ─────────────────
notify() {
  # notify-send can block if D-Bus is wedged — always bound it.
  timeout 3 notify-send "Kill Switch" "$1" -u critical -t 5000 2>/dev/null || true
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

log "=== kill-switch ${MODE}${DRY:+ (dry-run)} started by ${CUR_USER} ==="

# ── Safelist: Essential system/desktop patterns to KEEP (--full mode) ───────
KEEP_PATTERNS=(
  "mango" "wlroots" "Xwayland" "Xorg"
  "waybar" "awww-daemon" "swww-daemon" "swaybg" "hyprpaper"
  "pipewire" "wireplumber" "pulseaudio"
  "bluetoothd" "blueman" "bluetuith"
  "NetworkManager" "wpa_supplicant" "dhcpcd" "dhclient" "iwd"
  "dbus" "systemd" "polkit" "upowerd" "greetd"
  "swaylock" "gtklock" "hyprlock"
  "fuzzel" "rofi" "wofi"
  "mako" "dunst" "swaync" "quickshell"
  "wl-clip" "wl-paste"
  "xdg-desktop-portal" "xdg-document-portal" "xdg-permission-store"
  "kill-switch"
)

# ── Apps that MUST NEVER be killed in --light mode ──────────────────────────
GUI_APPS=(
  "zen" "firefox" "chrome" "chromium" "brave" "vivaldi" "librewolf"
  "discord" "slack" "spotify" "steam" "thunderbird" "element"
  "pcmanfm" "thunar" "nemo" "zed" "code" "vscodium"
)

# ── Target patterns for runaway processes (--light mode) ────────────────────
# Dev/build loops + compiled dev binaries + WebKit/Tauri webview runaways.
LOOP_PRONE=(
  "bun " "bunx" "node " "moon " "pnpm " "yarn " "npm " "tsx " "ts-node" "deno"
  "java" "gradle" "maven" "rust-analyzer" "typescript" "python" "pytest"
  "cargo" "go " "dotnet" "esbuild" "vite" "webpack" "rollup"
  "next " "nuxt" "turbo" "nx " "npx "
  "target/debug/" "target/release/"
  "WebKit" "electron" "tauri" "aikami"
)

is_safe() {
  local cmd="$1"
  local pat
  for pat in "${KEEP_PATTERNS[@]}"; do
    [[ "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

is_gui_app() {
  local cmd="$1"
  local app
  for app in "${GUI_APPS[@]}"; do
    [[ "$cmd" == *"$app"* ]] && return 0
  done
  return 1
}

is_loop_prone() {
  local cmd="$1"
  local pat
  for pat in "${LOOP_PRONE[@]}"; do
    [[ "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

# ── Protected PIDs: self + full ancestor chain ──────────────────────────────
# Never kill our own launcher (terminal / shell / compositor spawn chain).
declare -A PROTECTED=()
PROTECTED["$$"]=1
_p="${PPID:-1}"
while ((_p > 1)); do
  PROTECTED["$_p"]=1
  _np="$(ps -o ppid= -p "$_p" 2>/dev/null || true)"
  _np="${_np//[[:space:]]/}"
  [[ "$_np" =~ ^[0-9]+$ ]] || break
  ((_np <= 1)) && break
  _p="$_np"
done

G_PIDS=()
G_CMDS=()
declare -A KILLED=()
SKIPPED=0

# ── 1. Target Gathering (fresh snapshot per pass) ───────────────────────────
gather_targets() {
  local mode="$1" pid cmdline
  G_PIDS=()
  G_CMDS=()
  SKIPPED=0
  while read -r pid cmdline; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -n "$cmdline" ]] || continue
    [[ -n "${PROTECTED[$pid]:-}" ]] && continue
    [[ "$cmdline" == *"kill-switch"* ]] && continue
    if [[ "$mode" == "light" ]]; then
      is_gui_app "$cmdline" && continue
      is_loop_prone "$cmdline" || continue
    else
      if is_safe "$cmdline"; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
    fi
    G_PIDS+=("$pid")
    G_CMDS+=("$cmdline")
  done < <(ps -u "$CUR_USER" -o pid=,args= --no-headers 2>/dev/null || true)
}

# ── 2. PID-Reuse-Safe Kill ───────────────────────────────────────────────────
# Re-verify the cmdline right before signalling: if the PID was recycled by an
# unrelated process between snapshot and kill, we leave it alone.
kill_verified() {
  local pid="$1" expected="$2" sig="$3" cur
  cur="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  [[ "$cur" == "$expected" ]] || return 1
  kill "-$sig" "$pid" 2>/dev/null || return 1
  return 0
}

# ── 3. Termination Sweep (multi-pass so respawned/orphaned children die too) ─
do_sweep() {
  local mode="$1"
  local sig_first sig_second
  if [[ "$mode" == "light" ]]; then
    sig_first="TERM"
    sig_second="KILL"
  else
    sig_first="KILL"
    sig_second=""
  fi

  local pass=1
  while ((pass <= 3)); do
    gather_targets "$mode"
    local n="${#G_PIDS[@]}"
    ((n == 0)) && break

    if ((pass == 1)); then
      echo "=== KILL SWITCH (${MODE}): Terminating ${n} process(es) — pass ${pass} ===" >&2
      local i
      for i in "${!G_PIDS[@]}"; do
        printf '  ✗ %s | %s\n' "${G_PIDS[$i]}" "${G_CMDS[$i]:0:100}" >&2
      done
      log "sweep pass ${pass}: ${n} target(s)"
      for i in "${!G_PIDS[@]}"; do
        log "  target ${G_PIDS[$i]}: ${G_CMDS[$i]:0:100}"
      done
    else
      echo "=== KILL SWITCH (${MODE}): re-scan pass ${pass} — ${n} remaining ===" >&2
      log "sweep pass ${pass}: ${n} remaining target(s)"
    fi

    local i
    for i in "${!G_PIDS[@]}"; do
      if kill_verified "${G_PIDS[$i]}" "${G_CMDS[$i]}" "$sig_first"; then
        KILLED["${G_PIDS[$i]}"]=1
      fi
    done

    if [[ -n "$sig_second" ]]; then
      sleep 1
      for i in "${!G_PIDS[@]}"; do
        if kill_verified "${G_PIDS[$i]}" "${G_CMDS[$i]}" "$sig_second"; then
          KILLED["${G_PIDS[$i]}"]=1
        fi
      done
    fi

    pass=$((pass + 1))
    ((pass <= 3)) && sleep 1
  done
}

# ── 4. Kernel/GPU Hang Detection ─────────────────────────────────────────────
# A frozen screen with live audio is typically a hung GPU engine; killing user
# processes cannot unwedge it — only a session restart/reboot can. Detect and say so.
detect_kernel_hang() {
  local out=""
  # journalctl -k works without root on most NixOS setups; fall back to dmesg.
  out="$(timeout 8 journalctl -k --no-pager -n 5000 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    out="$(timeout 3 dmesg 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]] && sudo -n true 2>/dev/null; then
    out="$(timeout 3 sudo -n dmesg 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || {
    echo "unavailable"
    return 0
  }
  grep -iE \
    'GPU HANG|NVRM: Xid|nvidia.*Xid|nvidia.*(fell off the bus|timeout|\bhang\b)|i915.*(\bhang\b|\breset|timeout)|amdgpu.*(\bhang\b|\breset)|drm.*\bhang\b|soft lockup|rcu.*stall|hung_task|blocked for more than 120 seconds|watchdog: BUG|Out of memory|oom-kill' \
    <<<"$out" | tail -n 4 | cut -c1-160 || true
}

HANG_LINES="$(detect_kernel_hang)"
if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
  log "Kernel/GPU hang indicators present:"
  while IFS= read -r l; do log "  $l"; done <<<"$HANG_LINES"
fi

# ── 5. Dry-run ───────────────────────────────────────────────────────────────
SWEEP_MODE="light"
[[ "$MODE" != "--light" ]] && SWEEP_MODE="full"

if [[ "$DRY" -eq 1 ]]; then
  gather_targets "$SWEEP_MODE"
  echo "=== KILL SWITCH (${MODE} --dry-run): would terminate ${#G_PIDS[@]} process(es) ===" >&2
  for i in "${!G_PIDS[@]}"; do
    printf '  ✗ %s | %s\n' "${G_PIDS[$i]}" "${G_CMDS[$i]:0:100}" >&2
  done
  if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
    echo "  ⚠ Kernel/GPU hang indicators present:" >&2
    printf '    %s\n' "$HANG_LINES" >&2
  fi
  [[ "$MODE" == "--reboot" ]] && echo "  (--reboot: would request a reboot; full sweep only if not authorized)" >&2
  exit 0
fi

# ── 6. Execution ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "--reboot" ]]; then
  # Issue the reboot FIRST — while the polkit agent (if any) is still alive —
  # because the full sweep would kill it and leave `systemctl reboot` without
  # authorization. systemd's own shutdown kills all user processes anyway.
  if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
    notify "GPU hang confirmed — rebooting in 3s."
    log "GPU hang confirmed — rebooting."
  else
    notify "Kill Switch: rebooting in 3s."
    log "no hang indicators — rebooting."
  fi
  timeout 10 sync || true
  sleep 3
  if timeout 10 systemctl reboot 2>/dev/null || timeout 10 loginctl reboot 2>/dev/null || timeout 10 sudo -n reboot 2>/dev/null; then
    log "reboot issued successfully."
    exit 0
  fi
  log "reboot not authorized — falling back to full sweep."
  notify "Reboot not authorized — killing all user processes. Power off manually if still frozen."
  do_sweep "full"
  pkill -9 -u "$CUR_USER" -f "zen|firefox|chrome|chromium" 2>/dev/null || true
  exit 1
fi

do_sweep "$SWEEP_MODE"

# Cleanup sweep for browser crash-handler subprocesses (--full only).
if [[ "$SWEEP_MODE" == "full" ]]; then
  pkill -9 -u "$CUR_USER" -f "zen|firefox|chrome|chromium" 2>/dev/null || true
fi

# ── 7. Kernel Memory Cleanup (--light only) ──────────────────────────────────
mem_freed=""
if [[ "$SWEEP_MODE" == "light" ]]; then
  # Installed name (matches the sudoers NOPASSWD rule) or source-tree name.
  _cleanup_helper="$(dirname "$0")/kill-switch-cleanup"
  [[ -x "$_cleanup_helper" ]] || _cleanup_helper="$(dirname "$0")/kill-switch-cleanup.sh"
  if [[ -x "$_cleanup_helper" ]]; then
    if _out="$(timeout 10 sudo -n "$_cleanup_helper" 2>/dev/null)"; then
      while IFS='=' read -r key value; do
        case "$key" in
          dropped_mb)
            if [[ "$value" -gt 0 ]]; then
              mem_freed="${mem_freed}Dropped ${value}MB cache, "
            fi
            ;;
          swap_cleared)
            if [[ "$value" == "1" ]]; then
              mem_freed="${mem_freed}swap cleared, "
            fi
            ;;
        esac
      done <<<"$_out"
      mem_freed="${mem_freed%, }"
    else
      mem_freed="(cleanup not authorized)"
    fi
  fi
fi

# ── 8. Report ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--light" ]]; then
  _msg="Light kill: ${#KILLED[@]} process(es)"
  [[ -n "$mem_freed" ]] && _msg="$_msg. Kernel: $mem_freed"
  if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
    _msg="$_msg. ⚠ GPU/kernel hang detected — if frozen, escalate to --full / --reboot."
  fi
  notify "$_msg"
  log "done: $_msg"
else
  _msg="Full kill: ${#KILLED[@]} process(es) (preserved ${SKIPPED} essential)"
  if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
    _msg="$_msg. ⚠ GPU hang detected — screen may stay frozen; run kill-switch --reboot."
  fi
  notify "$_msg"
  log "done: $_msg"
fi
