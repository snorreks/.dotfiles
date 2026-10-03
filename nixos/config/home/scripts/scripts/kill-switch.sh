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
#   --server           Unattended-server targeting rules. Also enabled
#                      automatically by NS_SERVER_MODE=1 in the environment, which
#                      config/home/fish/default.nix sets on headless hosts.
#                      See SERVER MODE below.
#   --include-runtimes Server mode only. Also allow terminating bare shared
#                      runtimes (node, bun, python, java, go, …). Off by default
#                      because on a server those interpreters are how the
#                      management processes themselves are running.
#   --dry-run          Show what would be terminated (without killing anything).
#
# After the sweep the script scans the kernel log (journalctl -k / dmesg) for GPU/system
# hang indicators (i915/NVIDIA/amdgpu hangs, Xid, soft lockups, RCU stalls, hung tasks)
# and reports them — user-space kills cannot unwedge a hung GPU engine.
#
# ── SERVER MODE ──────────────────────────────────────────────────────────────
# On a desktop this script kills your programs. On a box that is only ever
# reached over a tailnet, "your programs" includes the things you get in
# through: the multiplexer, the phone bridge, the local dashboard, the agent
# jobs those are supervising, and the maintenance transaction that would
# otherwise roll a bad activation back for you.
#
# The two rules that follow from that, applied in EVERY mode including --full:
#
#   1. MANAGEMENT PROCESSES ARE NEVER TARGETED. herdr, Collie, moshi-hook,
#      sys-daemon, sshd, tailscaled, aged and the ns-maint helpers are excluded
#      by name.
#   2. NEITHER ARE THEIR DESCENDANTS. A job started by herdr is found by
#      walking the parent chain, so an agent loop running under a multiplexer
#      survives even when its own cmdline looks like a runaway.
#
# Plus one more in server mode:
#
#   3. BARE SHARED RUNTIMES ARE NOT TARGETED. "node", "bun", "python" match
#      almost everything, including the management processes in rule 1 —
#      Collie is a bun process. A bare `node` on a server is a workload whose
#      identity this script cannot establish, so killing it is a guess. Use
#      --include-runtimes when you have established it.
#
# Note what this does NOT do: it does not make --light safe to run blind. It
# makes it impossible for it to take out the way back in.

set -euo pipefail
export LC_ALL=C

MODE=""
DRY=0
# NS_SERVER_MODE is set by config/home/fish/default.nix on headless hosts, so the
# rule follows the host's declared role instead of a flag somebody has to
# remember to type while the machine is already misbehaving.
SERVER="${NS_SERVER_MODE:-0}"
INCLUDE_RUNTIMES=0

usage() {
  sed -n '2,45p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --light | --full | --reboot) MODE="$arg" ;;
    --server) SERVER=1 ;;
    --include-runtimes) INCLUDE_RUNTIMES=1 ;;
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

if [[ "$SERVER" == "1" ]]; then
  echo "kill-switch: SERVER MODE — management processes and their descendants are" >&2
  echo "               never targeted; bare shared runtimes are only targeted with" >&2
  [[ "$INCLUDE_RUNTIMES" -eq 1 ]] &&
    echo "               --include-runtimes." >&2
fi

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

# ── Management processes: never targeted, in ANY mode ────────────────────────
#
# These are how the box is reached and observed. Killing any of them from a
# remote session turns "one process is misbehaving" into "the box is gone and
# I do not know why", which is the worst outcome this script can produce.
#
# herdr and Collie are listed first because they are the ones that were
# actually at risk: an agent job's cmdline frequently contains the project path
# herdr was started from, and `aikami` (in LOOP_PRONE above) is itself how some
# of these jobs are launched.
MANAGEMENT_PATTERNS=(
  "herdr" "collie" "moshi" "sys-daemon" "moshi-hook"
  "sshd" "tailscaled" "tailscale" "aged" "ns-maint" "kill-switch"
  "systemd --user" "systemd --machine"
)

# ── Shared runtimes: interpreters, not workloads ─────────────────────────────
#
# `node`, `bun` and `python` are how Collie, moshi-hook and half the dashboard
# are running. A bare match on one of those names is not evidence of a runaway
# build; it is evidence that this script cannot tell a workload from the thing
# providing access to the machine.
SHARED_RUNTIME_PATTERNS=(
  "node" "bun" "python" "python3" "deno" "java" "go " "dotnet" "ruby" "php" "perl"
)

is_management() {
  local cmd="$1"
  local pat
  for pat in "${MANAGEMENT_PATTERNS[@]}"; do
    [[ "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

is_shared_runtime() {
  local cmd="$1"
  local pat
  for pat in "${SHARED_RUNTIME_PATTERNS[@]}"; do
    [[ "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

# has_management_ancestor PID — is this process a descendant of a management
# process?
#
# Matching on cmdline alone is not enough: an agent loop started by herdr runs as
# `bun run watch` in a project directory, with no hint of herdr anywhere in its
# own command line. Its parent chain has the answer. Walking the chain costs one
# `ps` per generation and is the only thing here that understands "this process
# belongs to someone else's supervision".
has_management_ancestor() {
  local pid="$1" hops=0 p cur
  p="$pid"
  while ((hops < 24)); do
    cur="$(ps -o args= -p "$p" 2>/dev/null || true)"
    [[ -n "$cur" ]] || return 1
    is_management "$cur" && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p <= 1)) && return 1
    hops=$((hops + 1))
  done
  return 1
}

# should_protect PID CMD — the server-mode veto, in one place.
should_protect() {
  local pid="$1" cmd="$2"
  is_management "$cmd" && return 0
  if [[ "$SERVER" == "1" ]]; then
    has_management_ancestor "$pid" && return 0
    if [[ "$INCLUDE_RUNTIMES" -ne 1 ]] && is_shared_runtime "$cmd"; then
      # A shared runtime that is ALSO matched by a specific workload pattern
      # (vite, next, webpack, pytest, cargo, ...) is a runaway, not a mystery:
      # the pattern is what makes it identifiable, so allow it.
      case "$cmd" in
      *vite* | *webpack* | *rollup* | *next* | *nuxt* | *turbo* | *" nx "* |         *esbuild* | *pytest* | *cargo* | *"go "* | *gradle* | *maven* |         *dotnet* | *npx* | *tsx* | *ts-node* | *typescript* | *rust-analyzer* | *target/debug/* | *target/release/* | *moon*) return 1 ;;
      esac
      return 0
    fi
  fi
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
    # The management veto runs BEFORE mode selection, so it applies to --full as
    # well as --light. --full is exactly the case where "everything except the
    # safelist" would otherwise sweep up the multiplexer and the phone bridge.
    if should_protect "$pid" "$cmdline"; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
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
  if [[ "$SERVER" == "1" ]]; then
    # A full sweep on an unattended box means every agent job, the
    # multiplexer's own children and anything else the operator had running —
    # to rescue a machine that is already unreachable. Not a trade worth making
    # silently. The management veto in should_protect still applies if you run
    # --full by hand, so this is about the WORKLOADS, not the access paths.
    log "server mode: NOT falling back to a full sweep. The reboot was refused;"
    log "server mode: killing every workload instead would destroy unattended work"
    log "server mode: and still would not unwedge a hung kernel."
    echo "kill-switch: server mode — reboot was not authorized, so nothing was killed." >&2
    echo "               A full sweep here would end every running agent job and" >&2
    echo "               would not fix a GPU/kernel hang anyway. Read the log, then" >&2
    echo "               decide: ns-maint status, or a deliberate 'kill-switch --full'." >&2
    exit 1
  fi
  do_sweep "full"
  pkill -9 -u "$CUR_USER" -f "zen|firefox|chrome|chromium" 2>/dev/null || true
  exit 1
fi

do_sweep "$SWEEP_MODE"

# Cleanup sweep for browser crash-handler subprocesses (--full only, desktop
# only). A browser is not a runaway on a headless box, and killing one here
# would take out whichever agent happens to be driving it.
if [[ "$SWEEP_MODE" == "full" && "$SERVER" != "1" ]]; then
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
  [[ "$SERVER" == "1" ]] && _msg="$_msg [server mode: management processes and their descendants were never targets]"
  if [[ -n "$HANG_LINES" && "$HANG_LINES" != "unavailable" ]]; then
    _msg="$_msg. ⚠ GPU hang detected — screen may stay frozen; run kill-switch --reboot."
  fi
  notify "$_msg"
  log "done: $_msg"
fi
