#!/usr/bin/env bash
# Launch a GUI in the live desktop, never as a child of persistent Herdr.
set -euo pipefail

fail() { printf 'ns-gui: %s\n' "$*" >&2; exit 1; }
wait_args=()
if [[ "${1:-}" == --wait ]]; then
  wait_args=(--wait --pipe)
  shift
fi
[[ $# -gt 0 ]] || fail 'Usage: ns-gui [--wait] <command> [arguments...]'
exe="$(command -v -- "$1")" || fail "Command not found: $1"
[[ -x "$exe" && ! -d "$exe" ]] || fail "Not an executable: $1"
shift

systemctl --user is-active --quiet mango-session.target \
  || fail 'No active Mango session. Log into the desktop first.'

# JSON avoids evaluating shell text, including credentials in the manager env.
# Read only the display values needed to validate this session.
session="$(systemctl --user show-environment --output=json)"
runtime="$(jq -er '.XDG_RUNTIME_DIR | select(type == "string" and length > 0)' <<<"$session")"
wayland="$(jq -er '.WAYLAND_DISPLAY | select(type == "string" and length > 0)' <<<"$session")"
signature="$(jq -er '.MANGO_INSTANCE_SIGNATURE | select(type == "string" and length > 0)' <<<"$session")"
display_socket="$wayland"
[[ "$display_socket" == /* ]] || display_socket="$runtime/$wayland"
[[ -S "$display_socket" && -S "$signature" ]] \
  || fail 'The desktop sockets are stale. Log into a working Mango session first.'
MANGO_INSTANCE_SIGNATURE="$signature" mmsg get all-clients >/dev/null 2>&1 \
  || fail 'Mango is not responding. No application was launched.'

# A transient user service inherits the manager's current environment. These
# overrides pin the display we just checked. Requisite prevents starting an
# empty session target if logout races the launch; PartOf ends the GUI at logout.
exec systemd-run --user --collect --service-type=exec --expand-environment=no \
  "${wait_args[@]}" \
  --property=ExitType=cgroup \
  --property=Requisite=mango-session.target \
  --property=After=mango-session.target \
  --property=PartOf=mango-session.target \
  --working-directory="$PWD" \
  --setenv="XDG_RUNTIME_DIR=$runtime" \
  --setenv="WAYLAND_DISPLAY=$wayland" \
  --setenv="MANGO_INSTANCE_SIGNATURE=$signature" \
  -- "$exe" "$@"
