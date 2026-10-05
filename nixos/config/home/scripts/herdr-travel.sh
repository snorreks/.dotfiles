# shellcheck shell=bash
# Fragment packaged by travel.nix. Native herdr transports negotiate the
# REMOTE protocol; endpoint generation and private protocol are not comparable.
set -euo pipefail

resolve_machine() {
  local label="$1" field="$2" value
  value="$(herdr machine list --json | python3 -c '
import json,sys
label,field=sys.argv[1:]
data=json.load(sys.stdin)
rows=data if isinstance(data,list) else data.get("machines",[])
rows=[m for m in rows if m.get("label")==label or m.get("id")==label]
if len(rows)!=1 or rows[0].get("enabled",True) is not True:
    sys.exit(1)
value=rows[0].get(field)
if not isinstance(value,str) or not value or any(ord(c)<32 for c in value):
    sys.exit(1)
print(value)
' "$label" "$field")" || {
    printf 'herdr-travel: no saved machine (or ambiguous/disabled entry) labelled %s.\n' "$label" >&2
    printf '  Inspect: herdr machine list. Offline fallback: herdr-travel local <cmd>\n' >&2
    return 1
  }
  printf '%s' "$value"
}

check_capabilities() {
  # This is a read-only check of the SELECTED remote transport, not a local
  # protocol comparison. It does not bootstrap or update the remote server.
  if ! timeout 30 herdr machine status "$1" --json | python3 -c '
import json,sys
rows=json.load(sys.stdin)
sys.exit(0 if isinstance(rows,list) and len(rows)==1 and rows[0].get("status")=="reachable" else 1)
'; then
    printf 'herdr-travel: REFUSING unreachable/incompatible remote.\n' >&2
    printf '  Inspect its status; update the CLIENT if needed. Use herdr-travel local <cmd>.\n' >&2
    return 1
  fi
}

cmd_attach() {
  local id target session
  id="$(resolve_machine "$1" id)" || return 1
  check_capabilities "$id" || return 1
  target="$(resolve_machine "$1" target)" || return 1
  session="${2:-$(resolve_machine "$1" session)}"
  # --machine is API-only; it cannot attach a TUI. --remote performs the
  # actual remote handshake and never needs the local daemon to be running.
  herdr --remote "$target" --session "$session"
}

cmd_run() {
  local id
  id="$(resolve_machine "$1" id)" || return 1
  check_capabilities "$id" || return 1
  shift
  [[ $# -gt 0 ]] || return 2
  # Never "repair" incompatibility by touching the server holding live panes.
  case "$1" in server|update) printf 'herdr-travel: server lifecycle commands are refused.\n' >&2; return 2 ;; esac
  herdr --machine "$id" "$@"
}

usage() {
  cat >&2 <<'USAGE'
usage: herdr-travel <command>
  status                    local status + saved machines
  attach <label> [session]   native remote TUI attachment
  run <label> <cmd...>       API command with explicit --machine <id>
  local <cmd...>             run here; never contacts any server

Attachment uses explicit --remote and the saved SSH target/session. API
commands use explicit --machine. Native remote negotiation rejects incompatible
servers; use the local fallback instead of restarting/upgrading a live server.
USAGE
}

case "${1:-}" in
  status) herdr status; herdr machine list ;;
  attach) shift; [[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }; cmd_attach "$@" ;;
  run) shift; [[ $# -ge 2 ]] || { usage; exit 2; }; cmd_run "$@" ;;
  local) shift; [[ $# -gt 0 ]] || { usage; exit 2; }; exec "$@" ;;
  *) usage; exit 2 ;;
esac
