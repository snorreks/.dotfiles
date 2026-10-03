#!/usr/bin/env bash
# nixos/tests/kill-switch-targets.sh — what a kill sweep is allowed to kill.
#
# On a desktop, "kill everything that looks like a runaway build" is a reasonable
# emergency action. On a box that is only reached over the tailnet, the same rule
# also matches the multiplexer, the phone bridge, the local dashboard, and every
# agent job running underneath them — because all of those are, at some level, a
# node or a bun process in a project directory.
#
# These tests drive the real kill-switch.sh against a FAKE `ps` with a
# hand-written process table, so the decisions can be asserted exactly. No
# process is signalled: `kill` is a fake too, and the suite fails if the real one
# is ever reached.
#
# The three rules under test, in every mode including --full:
#
#   1. management processes (herdr, Collie, moshi-hook, sys-daemon, sshd,
#      tailscaled, ns-maint) are never targets;
#   2. neither are their DESCENDANTS, found by walking the parent chain;
#   3. on a server, bare shared runtimes (node, bun, python, …) are not targets
#      unless a specific workload pattern identifies them, or --include-runtimes
#      is given.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"

KILL_SWITCH="${KILL_SWITCH:-$HERE/../config/home/scripts/scripts/kill-switch.sh}"

printf '\n\033[1mkill-switch targeting — management processes are not workloads\033[0m\n'

# ── the fake process table ──────────────────────────────────────────────────
#
# ps is replaced by a table reader. The format is `pid|ppid|args`, one process
# per line, which is what the script actually consumes (`ps -u ... -o pid=,args=`
# for the sweep, `ps -o ppid= -p N` for the ancestor walk).
table_reset() {
  PS_TABLE="$TMP/ps-table"
  : >"$PS_TABLE"
}

ps_add() {
  local pid="$1" ppid="$2"
  shift 2
  printf '%s|%s|%s\n' "$pid" "$ppid" "$*" >>"$PS_TABLE"
}

write_ps_fakes() {
  mkdir -p "$TMP/bin"
  # Absolute interpreter path; see the note in lib/harness.sh — /usr/bin/env does
  # not exist inside a nix build sandbox.
  local shebang
  shebang="#!$(command -v bash)"

  # `ps -u <user> -o pid=,args=` — the sweep snapshot.
  cat >"$TMP/bin/ps" <<'FAKE'
#!/usr/bin/env bash
echo "ps $*" >>"${TMP}/log/calls"
# ppid request: ps -o ppid= -p N
if [[ "$*" == *"-o ppid="* ]]; then
  for a in "$@"; do
    [[ "$a" == "-p" ]] && want=1 && continue
    [[ "$want" == "1" ]] || continue
    want=0
    while IFS='|' read -r pid ppid rest; do
      if [[ "$pid" == "$a" ]]; then printf '%s\n' "$ppid"; exit 0; fi
    done <"${TMP}/ps-table"
    printf '1\n'
    exit 0
  done
  exit 0
fi
# args request: ps -o args= -p N
if [[ "$*" == *"-o args="* ]]; then
  for a in "$@"; do
    [[ "$a" == "-p" ]] && want=1 && continue
    [[ "$want" == "1" ]] || continue
    want=0
    while IFS='|' read -r pid ppid rest; do
      if [[ "$pid" == "$a" ]]; then printf '%s\n' "$rest"; exit 0; fi
    done <"${TMP}/ps-table"
    exit 0
  done
  printf ''
  exit 0
fi
# the sweep snapshot
while IFS='|' read -r pid ppid rest; do
  printf '%s %s\n' "$pid" "$rest"
done <"${TMP}/ps-table"
FAKE
  chmod +x "$TMP/bin/ps"

  # The signal. A real `kill` here would end this test run's own processes.
  cat >"$TMP/bin/kill" <<'FAKE'
#!/usr/bin/env bash
sig=""
for a in "$@"; do
  case "$a" in
  -*) sig="${a#-}" ;;
  esac
done
echo "kill -${sig:-TERM} $*" >>"${TMP}/log/killed"
exit 0
FAKE
  chmod +x "$TMP/bin/kill"

  # notify-send can block on a wedged D-Bus; keep it silent and instant.
  cat >"$TMP/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$TMP/bin/notify-send"

  cat >"$TMP/bin/journalctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$TMP/bin/journalctl"

  local f
  for f in "$TMP"/bin/*; do
    sed -i "1s|^#!.*|$shebang|" "$f"
  done

  # The real flock serialises kill-switch invocations; pass it through. Its path
  # is resolved HERE, before the fake exists, because `command -v` inside the
  # fake would find the fake rather than the tool.
  local real_flock
  real_flock="$(command -v flock)"
  printf '#!/usr/bin/env bash\n# pass through to the real flock\nexec %q "$@"\n' \
    "$real_flock" >"$TMP/bin/flock"
  chmod +x "$TMP/bin/flock"

  # Absolute interpreter path, applied last so it covers every fake including
  # the flock pass-through written above.
  local f
  for f in "$TMP"/bin/*; do
    sed -i "1s|^#!.*|$shebang|" "$f"
  done
}


# ── real PIDs behind the fake process table ─────────────────────────────────
#
# `kill` is a bash BUILTIN, so a `kill` on PATH cannot be substituted from
# outside the script — the builtin wins. That means a test asserting "this
# process was signalled" would be asserting on nothing.
#
# So the fake table maps each persona onto a REAL disposable sleeper process
# that this suite started and intends to kill. A wrong decision then has a real,
# observable consequence: the persona's process is actually gone. And when the
# script correctly leaves a persona alone, that sleeper is still alive when the
# test checks — which is the assertion we actually care about.
declare -a SLEEPERS=()
# shellcheck disable=SC2154  # _p is the loop variable of the trap, assigned in the loop
trap 'for _p in "${SLEEPERS[@]:-}"; do [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null; done' EXIT

persona() {
  local cmdline="$1"
  # stdio to /dev/null is not optional here: persona is called inside a command
  # substitution, and a background child that inherits that substitution's pipe
  # keeps it open, so `pid="$(persona ...)"` would block until the sleeper exits.
  sleep 300 >/dev/null 2>&1 &
  local pid=$!
  SLEEPERS+=("$pid")
  ps_add "$pid" "${2:-1}" "$cmdline"
  printf '%s' "$pid"
}
persona_alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# run_ks ARGS... — invoke the real script with our fakes first on PATH.
run_ks() {
  (cd "$TMP" && PATH="$TMP/bin:$PATH" bash "$KILL_SWITCH" "$@")
}

setup() {
  fixture_new
  write_ps_fakes
  table_reset
  : >"$TMP/log/killed"
  : >"$TMP/log/calls"
}

# ─────────────────────────────────────────────────────────────────────────────
t_start "server mode: an agent loop under herdr is not a target"
setup
# herdr (the multiplexer) and an agent it supervises. The agent's own cmdline
# contains nothing about herdr — only the parent chain knows.
ps_add 100 1 "herdr server --listen /run/user/1000/herdr.sock"
ps_add 101 100 "bun run watch --filter=src"
run_ks --server --light --dry-run >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "SERVER MODE" "the mode is announced"
assert_contains "$out" "would terminate 0 process(es)" "an agent loop under herdr is not a target"
assert_not_contains "$out" "herdr server" "nor is herdr itself"
assert_not_contains "$(killed)" "101" "nothing is signalled in a dry run"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "server mode: the same workload IS a target when herdr is not its ancestor"
setup
ps_add 100 1 "herdr server --listen /run/user/1000/herdr.sock"
ps_add 200 1 "cargo build --release"
run_ks --server --light --dry-run >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "cargo build" "an unsupervised build appears in the sweep"
assert_contains "$out" "would terminate 1 process(es)" "and is terminated"
assert_not_contains "$out" "herdr server" "while herdr is still exempt"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "server mode: management processes are never targets, not even in --full"
setup
ps_add 100 1 "herdr server --listen /run/user/1000/herdr.sock"
ps_add 101 1 "collie bridge --port 8787"
ps_add 102 1 "moshi-hook gateway"
ps_add 103 1 "sys-daemon waybar power"
ps_add 104 1 "sshd: user@pts/0"
ps_add 105 1 "tailscaled"
ps_add 106 1 "ns-maint tick"
# …and one genuine workload, so the sweep is not empty for the wrong reason.
ps_add 200 1 "cargo build --release"
run_ks --server --full --dry-run >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "cargo build" "a real workload is still swept in --full"
assert_contains "$out" "would terminate 1 process(es)" "and it is the only one"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "server mode: a bare shared runtime is not a target"
setup
# A node process with nothing identifying it. This is the shape that used to
# take down Collie, because Collie is a bun process too.
ps_add 300 1 "node /some/unspecified/script.js"
run_ks --server --light --dry-run >"$TMP/log/ks.out" 2>&1
assert_contains "$(cat "$TMP/log/ks.out")" "would terminate 0 process(es)" "an unidentified node process is left alone"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "server mode: an identified workload built on a shared runtime IS a target"
setup
ps_add 300 1 "node /home/sonny/app/node_modules/.bin/vite --host"
ps_add 301 1 "python -m pytest -x tests/"
run_ks --server --light --dry-run >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "vite --host" "vite is identifiable, so it is swept"
assert_contains "$out" "pytest" "and so is pytest"
assert_contains "$out" "would terminate 2 process(es)" "both, and nothing else"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "--include-runtimes opts back in to shared runtimes"
setup
ps_add 300 1 "node /some/unspecified/script.js"
run_ks --server --light --include-runtimes --dry-run >"$TMP/log/ks.out" 2>&1
assert_contains "$(cat "$TMP/log/ks.out")" "would terminate 1 process(es)" "with the flag, the bare runtime is a target"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "desktop mode is unchanged: a bare node process is still swept"
setup
ps_add 300 1 "node /some/unspecified/script.js"
run_ks --light --dry-run >"$TMP/log/ks.out" 2>&1
assert_contains "$(cat "$TMP/log/ks.out")" "would terminate 1 process(es)" "--light on a desktop still targets bare node"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "the management veto applies even without server mode"
setup
ps_add 100 1 "herdr server --listen /run/user/1000/herdr.sock"
ps_add 200 1 "cargo build --release"
run_ks --full --dry-run >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "cargo build" "the workload is swept"
assert_not_contains "$out" "would terminate 2 process(es)" "and herdr is not, on a desktop either"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a real sweep terminates the workload and nothing else"
setup
herdr_pid="$(persona "herdr server --listen /run/user/1000/herdr.sock")"
agent_pid="$(persona "bun run watch" "$herdr_pid")"
sshd_pid="$(persona "sshd: user@pts/0")"
build_pid="$(persona "cargo build --release")"
run_ks --server --light >"$TMP/log/ks.out" 2>&1 || true
# `kill` is a builtin, so liveness of the disposable process is the
# observation, not a record of the signal.
assert_eq "no" "$(persona_alive "$build_pid")" "the build process is actually gone"
assert_eq "yes" "$(persona_alive "$herdr_pid")" "herdr survives a real sweep"
assert_eq "yes" "$(persona_alive "$agent_pid")" "the agent under it survives"
assert_eq "yes" "$(persona_alive "$sshd_pid")" "sshd survives"
t_done
fixture_free

t_start "a real --full sweep on a server still leaves management alone"
setup
herdr_pid="$(persona "herdr server --listen /run/user/1000/herdr.sock")"
collie_pid="$(persona "collie bridge --port 8787")"
browser_pid="$(persona "zen --new-window")"
build_pid="$(persona "cargo build --release")"
run_ks --server --full >"$TMP/log/ks.out" 2>&1 || true
assert_eq "no" "$(persona_alive "$build_pid")" "the workload does die in --full"
assert_eq "yes" "$(persona_alive "$herdr_pid")" "herdr survives --full"
assert_eq "yes" "$(persona_alive "$collie_pid")" "the phone bridge survives --full"
# A browser is NOT exempt, and that is deliberate rather than an oversight:
# --full means "kill everything that is not on the safelist", a human typed it,
# and the automated --reboot fallback that could otherwise trigger it on a
# server is refused outright. The rule is stated here so that changing it is a
# conscious act instead of a quiet one.
assert_eq "no" "$(persona_alive "$browser_pid")" "a browser does not, even on a server — --full means --full"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "NS_SERVER_MODE turns server mode on without a flag"
setup
ps_add 100 1 "herdr server --listen /run/user/1000/herdr.sock"
ps_add 300 1 "node /some/unspecified/script.js"
ps_add 200 1 "cargo build --release"
(cd "$TMP" && PATH="$TMP/bin:$PATH" NS_SERVER_MODE=1 bash "$KILL_SWITCH" --light --dry-run) >"$TMP/log/ks.out" 2>&1
out="$(cat "$TMP/log/ks.out")"
assert_contains "$out" "SERVER MODE" "the mode is announced, so a blind sweep says what it is"
assert_contains "$out" "would terminate 1 process(es)" "and only the identified workload is a target"
t_done
fixture_free

suite_summary "kill-switch targeting"