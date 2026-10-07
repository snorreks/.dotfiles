#!/usr/bin/env bash
# Exercise session checks and argument forwarding without touching real services.
set -o nounset -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-operations/lib/fixture.sh
source "$HERE/agent-operations/lib/fixture.sh"
SUITE_NAME=gui-session
LAUNCHER="$LANE_SRC/config/home/gui-session/ns-gui.sh"
TRUE_EXE="$(type -P true)"

setup() {
  fixture_new
  export NG_ACTIVE=1 NG_IPC_OK=1
  mkdir -p "$TMP/runtime"
  python3 - "$TMP/runtime" <<'PY'
import socket, sys
for name in ('wayland-live', 'mango-live.sock'):
    s = socket.socket(socket.AF_UNIX)
    s.bind(sys.argv[1] + '/' + name)
    s.close()
PY
  fake systemctl <<'FAKE'
case "$*" in
  *is-active*) [[ "$NG_ACTIVE" == 1 ]] ;;
  *show-environment*) jq -n --arg runtime "$TMP/runtime" '{XDG_RUNTIME_DIR:$runtime,WAYLAND_DISPLAY:"wayland-live",MANGO_INSTANCE_SIGNATURE:($runtime+"/mango-live.sock")}' ;;
  *) exit 2 ;;
esac
FAKE
  fake mmsg <<'FAKE'
[[ "$NG_IPC_OK" == 1 && "$MANGO_INSTANCE_SIGNATURE" == "$TMP/runtime/mango-live.sock" ]]
FAKE
  fake systemd-run <<'FAKE'
printf '%s\n' "$@" >"$TMP/log/args"
FAKE
  export WAYLAND_DISPLAY=wayland-stale MANGO_INSTANCE_SIGNATURE=/stale/socket
}

run_gui() {
  bash "$LAUNCHER" "$@" >"$TMP/log/output" 2>&1 && rc=0 || rc=$?
  out="$(cat "$TMP/log/output")"
  args="$(cat "$TMP/log/args" 2>/dev/null || true)"
}

_t_start "GUI launches use the current manager environment and session lifetime"
setup
# shellcheck disable=SC2016
run_gui "$TRUE_EXE" 'a path with spaces' '$TOKEN $(touch unwanted) %literal'
assert_eq 0 "$rc" 'launch succeeds despite stale caller environment'
assert_contains "$args" '--setenv=WAYLAND_DISPLAY=wayland-live' 'the current display is supplied'
assert_contains "$args" "--setenv=MANGO_INSTANCE_SIGNATURE=$TMP/runtime/mango-live.sock" 'the current compositor is supplied'
assert_contains "$args" '--property=PartOf=mango-session.target' 'GUI stops with Mango'
assert_contains "$args" '--property=ExitType=cgroup' 'a CLI launcher exiting does not kill its GUI child'
assert_contains "$args" '--property=Requisite=mango-session.target' 'launch cannot start a missing session'
assert_contains "$args" '--expand-environment=no' 'systemd cannot expand argument text'
assert_contains "$args" "--working-directory=$PWD" 'project working directory is preserved'
# shellcheck disable=SC2016
assert_contains "$args" '$TOKEN $(touch unwanted) %literal' 'arguments are passed literally'
assert_not_contains "$args" 'stale' 'stale session values are not forwarded'

_t_start "no active desktop never falls back to a Herdr child"
setup
export NG_ACTIVE=0
run_gui "$TRUE_EXE"
assert_ne 0 "$rc" 'headless launch is refused'
assert_contains "$out" 'No active Mango session' 'failure explains how to get a desktop'
assert_eq '' "$args" 'no service is launched'

_t_start "explicit waiting preserves foreground command output and completion"
setup
run_gui --wait "$TRUE_EXE"
assert_eq 0 "$rc" 'waiting mode launches successfully'
assert_contains "$args" '--wait' 'systemd waits for completion'
assert_contains "$args" '--pipe' 'command input and output stay attached'

_t_start "a stale manager socket is refused"
setup
rm "$TMP/runtime/wayland-live"
run_gui "$TRUE_EXE"
assert_ne 0 "$rc" 'missing display is refused'
assert_eq '' "$args" 'no GUI is launched against a stale display'

_t_start "a compositor that no longer answers IPC is refused"
setup
export NG_IPC_OK=0
run_gui "$TRUE_EXE"
assert_ne 0 "$rc" 'dead compositor is refused'
assert_eq '' "$args" 'no GUI is launched against a dead compositor'

_t_start "unknown commands fail before launching a unit"
setup
run_gui no-such-gui-command
assert_ne 0 "$rc" 'missing executable is refused'
assert_eq '' "$args" 'no unit is created'

fixture_free
summary
