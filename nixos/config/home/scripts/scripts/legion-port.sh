#!/usr/bin/env bash
# legion-port — reach a port on the Legion as if it were local.
#
# WHAT THIS IS
#   A dev server running on the Legion at 127.0.0.1:5173 becomes
#   http://127.0.0.1:5173 on the MSI. Open the browser, curl it, attach a
#   debugger — nothing on this machine is running, it is all a tunnel. WebSockets
#   and HMR work, so a Vite hot-reload loop behaves normally.
#
# WHY SSH AND NOT `tailscale serve`
#   `tailscale serve` was the obvious candidate and it is the wrong tool here,
#   for two reasons that are both about other people's decisions:
#
#     1. On this node Serve is SINGLE-WRITER by policy. Collie owns HTTPS/443 and
#        Jellyfin owns 8443; systemd.services.tailscale-serve-collie is "the only
#        writer", and config/system/tailscale/reconcile.sh repairs only its own
#        mapping and explicitly refuses `tailscale serve reset` because that
#        erases every mapping on the node. Adding dev ports there means either
#        fighting that owner or writing a second one, and the reconciler cannot
#        tell the difference between drift and intent.
#
#     2. A Serve mapping is reachable by EVERY device on the tailnet, including
#        the phone. An SSH forward binds to THIS machine's loopback only, so a
#        half-finished dev server with a debug endpoint on it is never published
#        by accident. `ssh -L` is also already authorised: the 2222 listener sets
#        AllowTcpForwarding yes explicitly (config/system/mobile-agents.nix), for
#        exactly this kind of use.
#
# LOOPBACK, NOT 0.0.0.0
#   `-L 5173:127.0.0.1:5173` binds to every interface and would publish the dev
#   server on the hotel wifi. The bind address is therefore always stated
#   explicitly. `--lan` is the opt-out, and it says so before doing it.
#
# THE DASHBOARD IS ALREADY THERE
#   Nothing to integrate: config/home/sys-daemon's dev-ports dashboard reads
#   listening sockets from /proc/net/tcp, and a forward IS a listening socket on
#   127.0.0.1, so forwarded ports appear in it automatically. ports.json already
#   names 5173 "Vite" and 9229 "Node inspector", so the common ones read
#   correctly with no configuration. Run `toggle-dev-ports` and look under
#   "Other Running Ports".
#
# USAGE
#   legion-port                  forward 5173 (the default) and open a browser
#   legion-port 5173             same, stated
#   legion-port 5173:3000        local 5173 -> remote 3000 (the "map it" case)
#   legion-port --list           every forward, and whether it is really alive
#   legion-port --open 5173      just open the browser, forwarding nothing
#   legion-port --stop 5173      stop one
#   legion-port --stop-all       stop every forward
#   legion-port --help
#
# Overridable: LEGION_HOST, LEGION_PORT_DEFAULT, LEGION_BROWSER, LEGION_STATE_DIR.
set -uo pipefail

host="${LEGION_HOST:-legion}"
default_port="${LEGION_PORT_DEFAULT:-5173}"
browser="${LEGION_BROWSER:-xdg-open}"
state_dir="${LEGION_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/legion-port}"

die() {
  printf 'legion-port: %s\n' "$1" >&2
  exit "${2:-1}"
}

note() { printf '  %s\n' "$*"; }

# Is anything LISTENing on this port on THIS machine?
#
# Read from /proc rather than `ss`, because a user session's PATH does not
# reliably contain iproute2, and a script that cannot verify its own result is
# not worth having. /proc/net/tcp state 0A is TCP_LISTEN. This is the same source
# sys-daemon's dashboard reads, so "the dashboard shows it" and "this says it is
# up" cannot disagree.
is_listening() {
  local want
  printf -v want '%04X' "$1"
  awk -v want="$want" \
    '$4 == "0A" { n = split($2, a, ":"); if (toupper(a[n]) == want) found = 1 }
     END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

alive() {
  [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null
}

# Local port, and remote [host:]port.
parse_spec() {
  local spec="$1" local remote
  if [[ "$spec" == *:* ]]; then
    local="${spec%%:*}"
    remote="${spec#*:}"
  else
    local="$spec"
    remote="$spec"
  fi
  [[ "$local" =~ ^[0-9]+$ ]] || die "'$spec': port must be a number"
  [[ "$remote" =~ ^[0-9]+$ ]] || die "'$spec': remote port must be a number"
  ((local >= 1 && local <= 65535 && remote >= 1 && remote <= 65535)) ||
    die "'$spec': port out of range"
  printf '%s %s' "$local" "$remote"
}

cmd_list() {
  local found=0 file pid lport rport
  printf 'Active forwards to %s\n\n' "$host"
  shopt -s nullglob
  for file in "$state_dir"/*.port; do
    found=1
    # shellcheck disable=SC1090
    source "$file"
    if alive "$pid" && is_listening "$lport"; then
      printf '  ✔  %-6s -> %s:%-6s  pid %s\n' "$lport" "$host" "$rport" "$pid"
    else
      printf '  ✘  %-6s -> %s:%-6s  DEAD (stale record)\n' "$lport" "$host" "$rport"
    fi
  done
  shopt -u nullglob
  ((found)) || note "none — try: legion-port ${default_port}"
  # Prune records whose process is gone, so the list cannot lie over time.
  if ((found)); then
    for file in "$state_dir"/*.port; do
      pid=""
      # shellcheck disable=SC1090
      source "$file"
      alive "$pid" || rm -f "$file"
    done
  fi
}

cmd_stop() {
  local spec="${1:-$default_port}" file pid lport rport
  read -r lport rport < <(parse_spec "$spec")
  file="$state_dir/$lport.port"
  if [[ ! -f "$file" ]]; then
    note "no forward recorded for $lport"
    return 0
  fi
  pid=""
  # shellcheck disable=SC1090
  source "$file"
  if alive "$pid"; then
    kill "$pid" 2>/dev/null
    sleep 0.3
    alive "$pid" && kill -9 "$pid" 2>/dev/null
    printf 'stopped %s -> %s:%s\n' "$lport" "$host" "$rport"
  else
    printf 'nothing running for %s (cleared stale record)\n' "$lport"
  fi
  rm -f "$file"
}

cmd_stop_all() {
  local file lport any=0
  shopt -s nullglob
  for file in "$state_dir"/*.port; do
    any=1
    lport="${file##*/}"
    cmd_stop "${lport%.port}"
  done
  shopt -u nullglob
  ((any)) || note "no forwards were running"
}

cmd_open() {
  local port="${1:-$default_port}"
  is_listening "$port" ||
    die "nothing is listening on $port — start the forward first: legion-port $port"
  "$browser" "http://127.0.0.1:$port" >/dev/null 2>&1 &
  printf 'opened http://127.0.0.1:%s (%s)\n' "$port" "$host"
}

cmd_forward() {
  local spec="${1:-$default_port}" bind="127.0.0.1" lan=0
  shift || true
  [[ "${1:-}" == "--lan" ]] && {
    lan=1
    bind="0.0.0.0"
  }

  read -r lport rport < <(parse_spec "$spec")
  mkdir -p "$state_dir"

  # "Already forwarded" is answered from our own record, and "something else is
  # on this port" from the kernel. Asking pgrep to pattern-match our own command
  # line would be a second, weaker source that can disagree with both.
  if [[ -f "$state_dir/$lport.port" ]]; then
    pid=""
    # shellcheck disable=SC1090
    source "$state_dir/$lport.port"
    if alive "$pid" && is_listening "$lport"; then
      note "$lport is already forwarded to $host:$rport"
      return 0
    fi
    rm -f "$state_dir/$lport.port"
  fi
  is_listening "$lport" &&
    die "port $lport is already in use by something that is not a legion-port forward"

  if ((lan)); then
    printf '⚠  binding 0.0.0.0 — %s is reachable from every network this machine is on.\n' "$lport" >&2
  fi

  # ExitOnForwardFailure matters more than it looks: without it ssh logs a bind
  # failure and keeps running, so the command would report success while nothing
  # is forwarded. It also detaches cleanly, and nohup means this script can exit
  # without the forward dying with it.
  #
  # The remote target is 127.0.0.1 on the Legion, not its tailnet address: a dev
  # server bound to localhost there is reachable this way and is NOT reachable
  # from the tailnet, which is the point.
  nohup ssh -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -L "$bind:$lport:127.0.0.1:$rport" \
    "$host" >/dev/null 2>&1 &
  local pid=$!

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    alive "$pid" || break
    is_listening "$lport" && break
  done

  if ! alive "$pid" || ! is_listening "$lport"; then
    kill "$pid" 2>/dev/null
    die "could not forward $lport -> $host:$rport (is $host reachable? see: legion-port --list)"
  fi

  printf 'pid=%q lport=%q rport=%q\n' "$pid" "$lport" "$rport" >"$state_dir/$lport.port"
  printf '✔  http://127.0.0.1:%s  ->  %s:%s\n' "$lport" "$host" "$rport"
  note "it now appears in the dev-ports dashboard too (toggle-dev-ports)"
  "$browser" "http://127.0.0.1:$lport" >/dev/null 2>&1 &
}

case "${1:---}" in
--help | -h)
  sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; $d'
  ;;
--list | -l) cmd_list ;;
--stop)
  shift
  cmd_stop "${1:-$default_port}"
  ;;
--stop-all) cmd_stop_all ;;
--open)
  shift
  cmd_open "${1:-$default_port}"
  ;;
*) cmd_forward "${1:-$default_port}" "${2:-}" ;;
esac