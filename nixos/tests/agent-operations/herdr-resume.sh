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

export AGENT_OPS_STATE_DIR="$TMP/state"
export AGENT_OPS_RESUME_ROOTS="$TMP/roots-file"
export HERDR_BIN="$TMP/bin/herdr"
mkdir -p "$TMP/project" "$TMP/other"

# ── a fake herdr client ─────────────────────────────────────────────────────
# FAKE_HERDR_STATUS drives what `herdr status server` answers.
fake herdr <<'FAKE'
#!/bin/bash
if [[ "$1" == "status" && "$2" == "server" ]]; then
	printf 'status: %s\n' "${FAKE_HERDR_STATUS:-running}"
	exit 0
fi
printf 'herdr %s\n' "$*"
FAKE

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
assert_contains "$out" 'before writing a heartbeat' 'and the reason is specific'
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
_t_start "a fresh heartbeat with no recorded pid is assumed owned by someone else"
cleanup_runs
rm -f "$rec"
touch "$HEARTBEAT"
out="$(START_TIMEOUT=8 resume)"
assert_contains "$out" 'no pid is recorded' 'the missing pid is named'
assert_contains "$out" 'Assuming another launcher owns it' 'and the decision is to stand aside'
assert_contains "$out" 'Use --force' 'with the documented override'

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

assert_no_reboot "$TMP/reboots"
summary