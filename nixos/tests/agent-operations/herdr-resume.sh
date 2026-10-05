#!/usr/bin/env bash
# nixos/tests/agent-operations/herdr-resume.sh
#
# The resume unit's decision-making, against a disposable state directory and
# fake herdr/systemctl. Nothing here touches a real project, a real herdr server
# or a real process: the runners are short-lived disposable shell scripts under
# $TMP and the locks are $TMP files.
#
# Each case is one the OLD implementation got wrong, which is why it has a test:
#
#   * a hard-coded project that may not exist on this host   -> explicit opt-in
#   * exit 1 counted as success                              -> each code means something
#   * no lock, so two starts launch the same run twice       -> flock, and a refusal
#   * a bare pid check, defeated by pid reuse                 -> pid + start-time identity
#   * "state file exists" mistaken for "the run is alive"     -> heartbeat freshness gate
#   * a missing session, or an incompatible CLI               -> capability check, refuse
#   * native herdr restore already brought the panes back     -> do not duplicate it
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="herdr-resume"

fixture_new
# Keep fallback coverage independent of the host's user manager.
unset INVOCATION_ID
fake systemctl <<'FAKE'
exit 1
FAKE

export AGENT_OPS_STATE_DIR="$TMP/state"
export AGENT_OPS_RESUME_ROOTS="$TMP/roots-file"
export HERDR_BIN="$TMP/bin/herdr"
mkdir -p "$TMP/project" "$TMP/other"

# ── a fake herdr client ─────────────────────────────────────────────────────
# A FUNCTION, not a bare `fake herdr` call, so a block that installs
# single-purpose behaviour can put the shared one back. Without that, one
# block's fake makes every later block exit 5 ("server not running") for a
# reason that has nothing to do with what it is testing.
write_herdr_fake() {
	fake herdr <<'FAKE'
if [[ "$1" == "status" && "$2" == "server" ]]; then
	printf 'status: %s\n' "${FAKE_HERDR_STATUS:-running}"
	exit 0
fi
printf 'herdr %s\n' "$*"
FAKE
}
write_herdr_fake

# ── a runner that touches a heartbeat, and one that exits immediately ───────
mk_runner() {
	local path="$1" body="$2"
	{
		printf '#!/bin/sh\n'
		printf '%s\n' "$body"
	} >"$path"
	chmod +x "$path"
}

# A well-behaved task: writes its heartbeat immediately, then waits.
HEARTBEAT="$TMP/project/hb"
mk_runner "$TMP/project/good.sh" "touch '$HEARTBEAT'
sleep 60"
# A task that dies on startup.
mk_runner "$TMP/project/dies.sh" "exit 3"
# A task that starts but never writes a heartbeat.
mk_runner "$TMP/project/silent.sh" "sleep 60"

cat >"$TMP/project/.agent-ops-resume" <<EOF
good|$TMP/project/good.sh|$HEARTBEAT
EOF

opt_in() {
	# opt_in <runner> <heartbeat> [name]
	local name="${3:-task}"
	printf '%s|%s|%s\n' "$name" "$1" "$2" >"$TMP/project/.agent-ops-resume"
}

resume() {
	START_TIMEOUT="${START_TIMEOUT:-4}"
	MAX_HEARTBEAT_AGE="${MAX_HEARTBEAT_AGE:-3600}"
	bash "$RESUME" --root "$TMP/project" "$@" 2>&1
}

cleanup_runs() {
	local p
	for p in "$AGENT_OPS_STATE_DIR"/records/*; do
		[[ -e "$p" ]] || continue
		local pid
		pid="$(grep -o '^PID=.*' "$p" | cut -d= -f2- || true)"
		[[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
	done
	rm -rf -- "$AGENT_OPS_STATE_DIR"
	mkdir -p "$AGENT_OPS_STATE_DIR"
}
trap 'cleanup_runs; fixture_free' EXIT

# ═══════════════════════════════════════════════════════════════════════════
_t_start "nothing happens without an explicit opt-in"
out="$(bash "$RESUME" 2>&1)"
rc=$?
assert_eq '0' "$rc" 'no roots configured is a clean no-op'
assert_contains "$out" 'nothing to resume' 'and says so'
assert_contains "$out" 'resume-roots' 'and names the file that turns it on'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'no record was written'

out="$(bash "$RESUME" --root "$TMP/does-not-exist" 2>&1)"
rc=$?
assert_eq '0' "$rc" 'a root that does not exist on this host is skipped, not fatal'
assert_contains "$out" 'skipping' 'and says it is skipping'

mkdir -p "$TMP/no-marker"
out="$(bash "$RESUME" --root "$TMP/no-marker" 2>&1)"
assert_contains "$out" 'not opted in' 'a root without the marker file is skipped'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "capability check: a stopped server refuses to launch anything"
export FAKE_HERDR_STATUS=stopped
out="$(bash "$RESUME" --root "$TMP/project" 2>&1)"
rc=$?
assert_eq '5' "$rc" 'exit 5 means the herdr server is unusable'
assert_contains "$out" 'not running' 'and says so'
assert_contains "$out" 'nothing can reach' 'and explains why launching would be pointless'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'and launched nothing'
export FAKE_HERDR_STATUS=running

out="$(HERDR_BIN="$TMP/bin/no-such-herdr" bash "$RESUME" --root "$TMP/project" 2>&1)"
rc=$?
assert_eq '3' "$rc" 'a missing herdr CLI is exit 3 (capability check failed)'
assert_contains "$out" 'not found' 'and names the problem'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "capability check: an unusable runner is refused BEFORE the lock"
opt_in "$TMP/project/not-executable" "$HEARTBEAT"
chmod -x "$TMP/project/not-executable" 2>/dev/null || true
out="$(resume)"
rc=$?
assert_contains "$out" 'not executable' 'a runner that cannot be executed is a capability failure'
assert_contains "$out" 'capability check failed' 'and says which check failed'

opt_in "relative/runner.sh" "$HEARTBEAT"
out="$(resume)"
assert_contains "$out" 'not an absolute path' 'a relative runner is refused'
assert_contains "$out" 'wrong binary of the same name' 'with the reason it is unsafe'

opt_in "$TMP/project/good.sh" "relative/heartbeat"
out="$(resume)"
assert_contains "$out" 'not absolute' 'a relative heartbeat path is refused'

opt_in "$TMP/project/good.sh" "$HEARTBEAT" 'bad name'
out="$(resume)"
assert_contains "$out" "task name 'bad name' is not" 'a task name outside the grammar is refused'

printf 'only|two\n' >"$TMP/project/.agent-ops-resume"
out="$(resume)"
assert_contains "$out" "expected 3" 'a malformed task line names the shape it expected'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a task that dies during startup is reported, not called successful"
opt_in "$TMP/project/dies.sh" "$TMP/project/never"
out="$(resume)"
rc=$?
assert_ne '0' "$rc" 'a task that exits before its heartbeat is a failure'
assert_contains "$out" 'exited' 'and the reason is specific'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'and no record was written claiming success'

out="$(resume)"
rc=$?
assert_eq '1' "$rc" 'a task that dies on startup exits 1, which is NOT success'
assert_contains "$out" 'log' 'and points at the log to read'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a task that starts but never writes a heartbeat is stopped, not orphaned"
opt_in "$TMP/project/silent.sh" "$TMP/project/silent-hb"
out="$(START_TIMEOUT=4 resume)"
rc=$?
assert_ne '0' "$rc" 'no heartbeat within the window is a failure'
assert_contains "$out" 'no heartbeat within' 'and says which wait expired'
assert_contains "$out" 'rather than leaving an untracked run' 'and that it cleaned up'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'no success record either'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a heartbeat followed by immediate exit never claims a running task"
mk_runner "$TMP/project/beat-exit.sh" "touch '$TMP/project/beat-exit-hb'
exit 9"
opt_in "$TMP/project/beat-exit.sh" "$TMP/project/beat-exit-hb"
out="$(START_TIMEOUT=4 resume)"
assert_ne '0' "$?" 'heartbeat does not substitute for a live process'
assert_not_contains "$out" 'running as pid' 'no successful launch verdict for an exited runner'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'no new running record for a dead or zombie runner'

_t_start "a healthy task starts, and its identity is recorded"
rm -f "$HEARTBEAT"
opt_in "$TMP/project/good.sh" "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
rc=$?
assert_eq '0' "$rc" 'a task whose heartbeat appears exits 0'
assert_contains "$out" 'running as pid' 'and reports the pid'
rec="$(find "$AGENT_OPS_STATE_DIR/records" -type f | head -1)"
RECORDED_PID="$(grep -o '^PID=.*' "$rec" | cut -d= -f2-)"
assert_file "$rec" 'a record was written'
assert_contains "$(cat "$rec")" 'PID_START=' 'with the process START TIME, not just the pid'
assert_ne '' "$(grep -o '^PID_START=.*' "$rec" | cut -d= -f2-)" 'and the start time is not empty'
assert_eq "$(</proc/sys/kernel/random/boot_id)" "$(grep '^BOOT_ID=' "$rec" | cut -d= -f2-)" 'records the current boot ID'
sleep 1

# ═══════════════════════════════════════════════════════════════════════════
_t_start "NO DUPLICATE: a second resume does not launch the same task again"
out="$(START_TIMEOUT=8 resume)"
rc=$?
assert_eq '0' "$rc" 'a second resume with a live process exits 0'
assert_contains "$out" 'already running' 'and says why it declined'
assert_contains "$out" 'not relaunching' 'explicitly'
assert_contains "$out" 'Use --force' 'and points at the documented override'
# And the record still describes the SAME process, not a new one.
assert_eq "$RECORDED_PID" "$(grep -o '^PID=.*' "$rec" | cut -d= -f2-)" \
	'the recorded identity is unchanged — no second process was started'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "PID REUSE: a live pid with a different start time is NOT our run"
rec="$(find "$AGENT_OPS_STATE_DIR/records" -type f | head -1)"
pid="$(grep -o '^PID=.*' "$rec" | cut -d= -f2-)"
kill "$pid" 2>/dev/null || true
sleep 1
# Same pid, different start time: exactly what pid reuse looks like.
sed -i.bak "s/^PID_START=.*/PID_START=999999999/" "$rec"
rm -f "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
assert_contains "$out" 'has been reused' 'a reused pid is recognised, not assumed to be our run'
assert_contains "$out" 'Treating as dead' 'and the run is treated as dead'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "fresh prior-boot heartbeat is not ownership, even with matching live PID ticks"
cleanup_runs
mkdir -p "$AGENT_OPS_STATE_DIR/records"
rec="$AGENT_OPS_STATE_DIR/records/$(printf '%s' "$TMP/project/task" | tr -c 'A-Za-z0-9_.-' '_')"
printf 'PID=%s\nPID_START=%s\nBOOT_ID=prior-boot\n' "$$" "$(awk '{print $22}' /proc/$$/stat)" >"$rec"
touch "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
assert_eq '0' "$?" 'fresh prior-boot heartbeat does not prevent resume'
assert_contains "$out" 'heartbeat is not ownership' 'prior-boot ownership is explicitly rejected'
assert_contains "$out" "launching '$TMP/project/good.sh'" 'the orphan is relaunched'
assert_eq "$(</proc/sys/kernel/random/boot_id)" "$(grep '^BOOT_ID=' "$rec" | cut -d= -f2-)" 'new record belongs to this boot'
out="$(START_TIMEOUT=8 resume)"
assert_contains "$out" 'already running' 'current-boot duplicate is suppressed'
cleanup_runs

_t_start "fresh prior-boot heartbeat with a dead PID is resumed"
mkdir -p "$AGENT_OPS_STATE_DIR/records"
printf 'PID=999999999\nPID_START=1\nBOOT_ID=prior-boot\n' >"$rec"
touch "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
assert_eq '0' "$?" 'dead prior-boot run resumes despite fresh heartbeat'
assert_contains "$out" "launching '$TMP/project/good.sh'" 'fresh prior-boot dead record cannot skip permanently'
cleanup_runs

_t_start "fresh heartbeat without a record cannot suppress resume"
touch "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
assert_contains "$out" "launching '$TMP/project/good.sh'" 'a heartbeat alone is not ownership'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "--force overrides both gates"
out="$(START_TIMEOUT=8 resume --force)"
assert_contains "$out" 'launching' '--force launches despite a live-looking heartbeat'
cleanup_runs

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the lock refuses a duplicate launch"
opt_in "$TMP/project/good.sh" "$HEARTBEAT"
rm -f "$HEARTBEAT"
# Take the same lock the script will take, and hold it.
mkdir -p "$AGENT_OPS_STATE_DIR/locks"
lockfile="$(find "$AGENT_OPS_STATE_DIR/locks" -name '*task*' 2>/dev/null | head -1)"
if [[ -z "$lockfile" ]]; then
	# Derive it the same way the script does, rather than hard-coding a slug.
	lockfile="$AGENT_OPS_STATE_DIR/locks/$(printf '%s' "$TMP/project/task" | tr -c 'A-Za-z0-9_.-' '_').lock"
fi
mkdir -p "$(dirname "$lockfile")"
exec 8>"$lockfile"
flock -n 8
out="$(START_TIMEOUT=4 resume)"
rc=$?
assert_eq '4' "$rc" 'a held lock exits 4, which is distinct from "failed"'
assert_contains "$out" 'another resume holds' 'and names the conflict'
assert_contains "$out" 'not launching a duplicate' 'explicitly'
exec 8>&-
rm -f "$lockfile"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "dry-run launches nothing and claims nothing"
cleanup_runs
rm -f "$HEARTBEAT"
out="$(START_TIMEOUT=4 resume --dry-run)"
assert_contains "$out" 'DRY-RUN' 'dry-run says so'
assert_contains "$out" 'would launch' 'and describes what it would do'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f 2>/dev/null | grep -c .)" 'no record written'
assert_no_file "$HEARTBEAT" 'and the task never ran'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "multiple roots: each is considered, missing ones do not stop the rest"
printf '%s\n%s\n%s\n' "$TMP/project" "$TMP/absent" "$TMP/other" >"$AGENT_OPS_RESUME_ROOTS"
cat >"$TMP/other/.agent-ops-resume" <<EOF
other|$TMP/other/good.sh|$TMP/other/hb
EOF
mk_runner "$TMP/other/good.sh" "touch '$TMP/other/hb'
sleep 60"
out="$(START_TIMEOUT=8 bash "$RESUME" 2>&1)"
rc=$?
assert_eq '0' "$rc" 'a mix of present and absent roots still succeeds'
assert_contains "$out" 'absent' 'the absent root is named'
assert_contains "$out" 'task' 'and the present one still ran'
cleanup_runs

# A transient service must run independently, with the same cwd/environment,
# and the recorded PID must belong to the runner, not systemd-run.
_t_start "systemd launches a separate service and records its MainPID"
fake systemctl <<'FAKE'
case "$2" in
show-environment) exit "${FAKE_MANAGER_EXIT:-0}" ;;
show) cat "$TMP/unit.pid" ;;
stop)
    printf '%s\n' "$*" >>"$TMP/unit.stops"
    kill "$(cat "$TMP/unit.pid")" 2>/dev/null || true ;;
esac
FAKE
fake systemd-run <<'FAKE'
printf '%s\n' "$@" >"$TMP/unit.args"
[[ "${FAKE_RUN_FAIL:-0}" == 0 ]] || exit 1
while (($#)); do
    case "$1" in
    --working-directory=*) cd "${1#*=}" || exit 1 ;;
    --setenv=*) export "${1#*=}" ;;
    --) shift; break ;;
    esac
    shift
done
setsid "$@" >"$TMP/unit.log" 2>&1 < /dev/null &
printf '%s\n' "$!" >"$TMP/unit.pid"
FAKE
# Variables expand in the generated runner.
# shellcheck disable=SC2016
mk_runner "$TMP/project/unit.sh" 'printf "%s|%s|%s\n" "$PWD" "$HERDR_RESUMED_ROOT" "$HERDR_RESUMED_TASK" > "$TMP/unit.context"
touch "$TMP/project/hb"
sleep 60'
opt_in "$TMP/project/unit.sh" "$HEARTBEAT"
rm -f "$HEARTBEAT"
out="$(resume)"
assert_eq '0' "$?" 'transient launch succeeds'
rec="$(find "$AGENT_OPS_STATE_DIR/records" -type f | head -1)"
assert_contains "$(cat "$rec")" "PID=$(cat "$TMP/unit.pid")" 'records the service MainPID'
assert_eq "$TMP/project|$TMP/project|task" "$(cat "$TMP/unit.context")" 'preserves cwd and task environment'
for arg in --user --collect --service-type=exec "--property=StandardOutput=append:$AGENT_OPS_STATE_DIR/logs/task.log"; do
    assert_contains "$(cat "$TMP/unit.args")" "$arg" "launch includes $arg"
done
assert_not_contains "$(cat "$TMP/unit.args")" '--scope' 'launch uses a service'
kill -0 "$(cat "$TMP/unit.pid")"
assert_eq '0' "$?" 'runner is alive after resume returns'
cleanup_runs

_t_start "failed transient launches do not fall back or record success"
rm -f "$HEARTBEAT"
out="$(FAKE_RUN_FAIL=1 resume)"
assert_eq '1' "$?" 'systemd-run failure is reported'
assert_no_file "$HEARTBEAT" 'runner was not launched through the fallback'
assert_eq '0' "$(find "$AGENT_OPS_STATE_DIR/records" -type f | wc -l)" 'no successful record'
out="$(FAKE_MANAGER_EXIT=1 INVOCATION_ID=fixture resume)"
assert_eq '1' "$?" 'inside a unit, unavailable user manager is an error'
assert_no_file "$HEARTBEAT" 'no fallback into the oneshot cgroup'

_t_start "heartbeat timeout stops the transient service"
opt_in "$TMP/project/silent.sh" "$TMP/project/silent-hb"
touch "$TMP/project/silent-hb"
out="$(START_TIMEOUT=2 resume)"
assert_eq '1' "$?" 'missing heartbeat fails'
assert_contains "$(cat "$TMP/unit.stops")" '--user stop herdr-task-' 'stops the entire task unit'
cleanup_runs

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a STARTING server is waited for, not reported as absent"
# herdr.service is Type=simple: systemd calls it started the moment it forks, so
# `After=herdr.service` does NOT mean the socket is listening. This unit is
# WantedBy=herdr.service and fires in exactly that window. A single `herdr
# status` there read "stopped", exited 5, and SuccessExitStatus=0 marked the
# unit failed — so on a cold boot the opted-in tasks were never resumed and
# nothing retried.
rm -f "$TMP/herdr-status-calls"
# `$(command -v bash)`, not /usr/bin/env: a nix build sandbox has no
# /usr/bin/env, and a fake that cannot exec fails for a reason that has nothing
# to do with what it is testing.
# The shebang is written separately from the body: an UNQUOTED heredoc expands
# "$1"/"${TMP}" while the fixture is being written, and a quoted one cannot
# expand "$(command -v bash)". Two writes is the only way to get both.
printf '#!%s\n' "$(command -v bash)" >"$TMP/bin/herdr"
cat >>"$TMP/bin/herdr" <<'FAKE'
if [ "$1" = "status" ] && [ "$2" = "server" ]; then
	# Count our own polls, so the assertion can see that the script actually
	# waited rather than deciding on the first answer.
	printf 'n\n' >>"${TMP}/herdr-status-calls"
	n=$(grep -c . "${TMP}/herdr-status-calls" 2>/dev/null || echo 0)
	# "starting" twice, then "running".
	if [ "$n" -ge 3 ]; then s=running; else s=starting; fi
	printf 'status: %s\n' "$s"
	exit 0
fi
FAKE
chmod +x "$TMP/bin/herdr"
rm -f "$TMP/herdr-status-calls"
cat >"$TMP/project/.agent-ops-resume" <<EOF
race|$TMP/project/good.sh|$TMP/project/hb
EOF
rm -f "$TMP/project/hb"
out="$(SERVER_WAIT=10 START_TIMEOUT=8 bash "$RESUME" --root "$TMP/project" 2>&1)"
rc=$?
assert_eq '0' "$rc" 'a server that becomes ready is not reported as exit 5'
assert_not_contains "$out" 'not running' 'and no "not running" refusal was printed'
calls="$(wc -l <"$TMP/herdr-status-calls" 2>/dev/null || echo 0)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$calls" -ge 3 ]]; then
	_ok "the server was polled until it was ready ($calls polls)"
else
	_fail "the server was polled until it was ready (only $calls polls)"
fi

# And a server that NEVER comes up must still fail visibly, not hang.
printf '#!%s\n' "$(command -v bash)" >"$TMP/bin/herdr"
cat >>"$TMP/bin/herdr" <<'FAKE'
if [ "$1" = "status" ] && [ "$2" = "server" ]; then printf 'status: starting\n'; exit 0; fi
FAKE
chmod +x "$TMP/bin/herdr"
start="$(date +%s)"
out="$(SERVER_WAIT=4 bash "$RESUME" --root "$TMP/project" 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq '5' "$rc" 'a server that never starts still exits 5'
assert_contains "$out" 'not running' 'with the documented refusal'
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$elapsed" -le 20 ]]; then
	_ok "and the wait is BOUNDED, not a hang (${elapsed}s)"
else
	_fail "and the wait is BOUNDED, not a hang (${elapsed}s)"
fi
cleanup_runs
write_herdr_fake

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the lock is held BEFORE the record and heartbeat are read"
# 🔴 THE DUPLICATE LAUNCH THE LOCK EXISTS TO PREVENT.
#
# The lock used to be taken AFTER the record and heartbeat were read. Two
# resumes — a manual `systemctl --user start` racing the WantedBy=herdr.service
# trigger — could both read "no live pid, stale heartbeat". The first took the
# lock, launched the task, wrote the record and released it; the second then
# took the lock and launched the SAME task again, because its decision was made
# from state it had read before it held the lock.
#
# Reproduced deterministically: the runner NEVER writes a heartbeat, so the first
# resume stays inside its START_TIMEOUT wait — holding the lock for the whole of
# it. That is the window in which the second resume used to decide "dead, go
# ahead", then block on the lock, then launch a duplicate after the first
# released it.
mk_runner "$TMP/project/slow.sh" "sleep 25"
cat >"$TMP/project/.agent-ops-resume" <<EOF
dup|$TMP/project/slow.sh|$TMP/project/hb
EOF
rm -f "$TMP/project/hb"
cleanup_runs

lockfile="$AGENT_OPS_STATE_DIR/locks/$(printf '%s' "$TMP/project/dup" | tr -c 'A-Za-z0-9_.-' '_').lock"

START_TIMEOUT=10 bash "$RESUME" --root "$TMP/project" >"$TMP/first.out" 2>&1 &
FIRST=$!

# Wait until the lock is ACTUALLY held, rather than guessing with sleep. Polling
# the lock itself is the only thing that makes the race reproducible.
held=no
for _ in $(seq 1 60); do
	mkdir -p "$(dirname "$lockfile")"
	if [[ -f "$lockfile" ]] && ! flock -n 9 9>>"$lockfile" 2>/dev/null; then
		held=yes
		break
	fi
	sleep 0.25
done
assert_eq 'yes' "$held" 'the first resume is holding the lock'

out="$(START_TIMEOUT=10 bash "$RESUME" --root "$TMP/project" 2>&1)"
rc=$?
assert_eq '4' "$rc" 'the second resume, arriving while the first holds the lock, exits 4'
assert_contains "$out" 'another resume holds' 'and says the lock is held'
# The refusal text itself contains the word "launching" ("not launching a
# duplicate"), so assert on the launch line specifically.
assert_not_contains "$out" "launching '$TMP/project/slow.sh'" \
	'and does NOT launch a second copy'

wait "$FIRST" 2>/dev/null || true
runs="$(grep -c "launching '$TMP/project/slow.sh'" "$TMP/first.out" 2>/dev/null || true)"
assert_eq '1' "$runs" 'and the task was launched exactly once, not twice'
cleanup_runs

# 🔴 STRUCTURAL GUARD for the ORDERING FIX, and stated honestly.
#
# The test above cannot distinguish the two orderings: `flock -n` is
# NON-BLOCKING, so a second resume that arrives while the first still holds the
# lock gets exit 4 under EITHER ordering. The bug the ordering fix removes is
# narrower — the first resume FINISHING between the second's read of the record
# and its acquisition of the lock — and that window is too small to hit
# reliably.
#
# So this asserts the ORDER itself rather than pretending to reproduce the race:
# the non-blocking flock must be taken before the record and heartbeat are read.
# A structural check, clearly labelled as one, beats a behavioural test that
# passes against the old code.
src="$(cat "$RESUME")"
lock_line="$(grep -n 'flock -n' <<<"$src" | head -1 | cut -d: -f1)"
read_line="$(grep -n 'identity of the previously recorded run' <<<"$src" | head -1 | cut -d: -f1)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$lock_line" && -n "$read_line" ]] && ((lock_line < read_line)); then
	_ok "the lock is taken before the record is read (line $lock_line < $read_line)"
else
	_fail "the lock is taken before the record is read (lock at ${lock_line:-?}, read at ${read_line:-?})"
fi


# 🔴 RESTORE the shared herdr fake. The blocks above overwrote $TMP/bin/herdr
# with single-purpose versions, and leaving one in place makes every later
# block exit 5 ("server not running") for a reason that has nothing to do with
# what it is testing.
write_herdr_fake


assert_no_reboot "$TMP/reboots"
summary
