#!/usr/bin/env bash
# herdr-resume.sh — restart explicitly opted-in agent runs after a herdr restart.
#
# ── Why this is not just "relaunch the contract pipeline" ─────────────────────
# herdr's own session restore brings back workspaces, tabs, panes and their
# working directories — but NOT their commands: session.json has no command
# field. So after a restart (or a reboot) every pane is a bare shell, and a
# long-running job that lived in one of those panes is simply gone from the
# user's point of view even though its state is still on disk.
#
# The previous implementation of this unit was wrong in five ways, and each one
# is a separate guard here rather than a comment:
#
#   1. IT HARD-CODED ONE REPOSITORY. `repoRoot` was a literal path to a
#      personal project, so the unit started a task for a directory that may not
#      exist on this host, on a machine whose whole point is that nobody is at
#      it. There is now no default: nothing happens until a root is named.
#   2. EXIT 1 WAS TREATED AS SUCCESS. `SuccessExitStatus = "0 1"` existed so a
#      failed scan would not mark the session unhealthy. But the runner's exit 1
#      is indistinguishable from "the thing I asked for did not happen", and
#      marking that healthy is exactly backwards. The exit code now MEANS
#      something and each one is documented below.
#   3. NO LOCK. Two starts (a manual `systemctl --user start` racing the
#      WantedBy=herdr.service trigger) launch the same run twice.
#   4. PID WITHOUT IDENTITY. Checking "is 4711 alive" is not "is my run alive":
#      pids are reused, and a reused pid would make this skip a run that really
#      did die — or relaunch one that is still going.
#   5. NO HEARTBEAT GATE. A run whose state file exists is not a run that is
#      alive. Several review-stage runs sat on disk for two days and would all
#      have been relaunched at once.
#
# ── What it will and will not do ─────────────────────────────────────────────
# It launches a NAMED, OPTED-IN task. It never touches herdr's own restore, it
# never stops a pane, and it never runs a command it was not given on the
# command line or in an explicitly named task file.
#
# ── Task file format ─────────────────────────────────────────────────────────
# One task per line, `|`-separated (not TAB: tab is IFS whitespace and an empty
# field would shift the rest). Blank lines and #-comments ignored.
#
#     NAME|RUNNER|HEARTBEAT_FILE
#
# NAME     [A-Za-z0-9_.-]+  an identifier for the state record and the lock
# RUNNER   absolute path to an executable. It is executed DIRECTLY — never
#          through a shell — so nothing in it can be word-split, glob-expanded
#          or command-substituted by this script.
# HEARTBEAT_FILE  path whose mtime is the progress signal. Only a current-boot
#          PID + start-time record proves ownership; heartbeat alone cannot.
#          A relaunched run must update this file during its start window.
#
# ── Exit codes ───────────────────────────────────────────────────────────────
#   0  nothing to do, or everything asked for was already running
#   1  a task failed to start or died during its start window
#   2  usage / configuration error (bad name, relative runner, missing root)
#   3  a capability check failed; nothing was launched
#   4  another resume holds the lock for that root
#   5  the herdr server is not running, or the CLI cannot talk to it
set -o nounset -o pipefail

PROGRAM_NAME=${0##*/}

HERDR_BIN=${HERDR_BIN:-herdr}
STATE_DIR=${AGENT_OPS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-ops/resume}
# How long to wait for the herdr server to start listening. Bounded: a server
# that never comes up must leave the unit visibly failed, not hanging.
SERVER_WAIT=${SERVER_WAIT:-60}
# How stale a heartbeat may be before the run counts as dead. Generous enough
# for a long tool call, tight enough that a two-day-old file is obviously not a
# live orchestrator.
MAX_HEARTBEAT_AGE=${MAX_HEARTBEAT_AGE:-3600}
# How long to wait for a freshly launched task to write its first heartbeat.
# Absent a heartbeat, the task is stopped again rather than left orphaned.
START_TIMEOUT=${START_TIMEOUT:-120}
# Marker file a project drops in its root to opt in at all.
OPT_IN_MARKER=${OPT_IN_MARKER:-.agent-ops-resume}
# PID/start ticks are only identities within one boot. Never trust an old
# heartbeat (or a reused PID with the same ticks) as ownership after reboot.
BOOT_ID=""
IFS= read -r BOOT_ID </proc/sys/kernel/random/boot_id || exit 2
[[ -n "$BOOT_ID" ]] || exit 2

declare -a ROOTS=()
ROOTS_FILE=""
TASKS_FILE=""
DRY_RUN=0
FORCE=0

sayf() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; }
say() { printf '%s\n' "$*"; }

usage() {
	cat >&2 <<EOF
usage: $PROGRAM_NAME [--root PATH [--root PATH]...] [--roots-file FILE]
                      [--tasks FILE] [--dry-run] [--force]

  --root PATH     a repository root to consider. Repeatable. Nothing happens
                  without at least one root, from --root or --roots-file.
  --roots-file F  newline-separated roots, '#' comments allowed. When neither
                  --root nor --roots-file is given, this defaults to
                  \$AGENT_OPS_RESUME_ROOTS, then to
                  ~/.config/agent-ops/resume-roots. A missing default file is a
                  no-op, not an error: the feature is off until you turn it on.
  --tasks FILE    task file. Defaults to <root>/$OPT_IN_MARKER in each root.
                  A root with no such file is skipped, not an error.
  --dry-run       report what would be launched; launch nothing
  --force         relaunch even if a live process and fresh heartbeat exist

exit: 0 ok, 1 task failed, 2 config error, 3 capability check failed,
      4 locked by another resume, 5 herdr server unusable
EOF
	exit 2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--root)
		ROOTS+=("$2")
		shift 2
		;;
	--root=*) ROOTS+=("${1#--root=}"); shift ;;
	--roots-file)
		ROOTS_FILE="$2"
		shift 2
		;;
	--roots-file=*) ROOTS_FILE="${1#--roots-file=}"; shift ;;
	--tasks)
		TASKS_FILE="$2"
		shift 2
		;;
	--tasks=*) TASKS_FILE="${1#--tasks=}"; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--force) FORCE=1; shift ;;
	-h | --help) usage ;;
	*) sayf "unknown argument '$1'"; usage ;;
	esac
done

if ((${#ROOTS[@]} == 0)); then
	ROOTS_FILE="${ROOTS_FILE:-${AGENT_OPS_RESUME_ROOTS:-$HOME/.config/agent-ops/resume-roots}}"
	if [[ -r "$ROOTS_FILE" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			line="${line%$'\r'}"
			[[ -z "$line" || "$line" == \#* ]] && continue
			ROOTS+=("$line")
		done <"$ROOTS_FILE"
	fi
fi

if ((${#ROOTS[@]} == 0)); then
	say "no opted-in roots — nothing to resume."
	say "Add a line to ~/.config/agent-ops/resume-roots, or pass --root."
	exit 0
fi

command -v flock >/dev/null 2>&1 || {
	sayf "flock is not available; refusing to run without a lock."
	exit 2
}

mkdir -p "$STATE_DIR/locks" "$STATE_DIR/records" || {
	sayf "cannot create state directory $STATE_DIR"
	exit 2
}

# ── capability checks ───────────────────────────────────────────────────────
#
# Refuse before touching anything. A resume that half-works is worse than one
# that declines: it leaves a run's state saying "in progress" with nothing
# driving it, which is the state that made the heartbeat gate necessary.
if ! command -v "$HERDR_BIN" >/dev/null 2>&1 && [[ ! -x "$HERDR_BIN" ]]; then
	sayf "herdr CLI '$HERDR_BIN' not found; cannot check the server."
	exit 3
fi
# 🔴 WAIT FOR THE SERVER, BOUNDEDLY.
#
# `herdr.service` is Type=simple: systemd considers it started the moment it
# forks, so `After=herdr.service` does NOT mean the socket is listening. This
# script is WantedBy=herdr.service and therefore fires in exactly that window.
# A single `herdr status` there reads "stopped", the script exits 5, and
# SuccessExitStatus=0 marks the unit failed — so on a cold boot the opted-in
# tasks are never resumed and nothing retries. herdr.nix's comment claiming this
# script "waits for the server" was simply wrong.
server_status=""
waited=0
while ((waited < SERVER_WAIT)); do
	server_status="$("$HERDR_BIN" status server 2>/dev/null | awk '/^status:/ {print $2; exit}' || true)"
	[[ "$server_status" == "running" ]] && break
	sleep 2
	waited=$((waited + 2))
done
case "$server_status" in
running) ;;
*)
	sayf "herdr server is not running (status '${server_status:-unknown}')."
	sayf "Resuming into a stopped server would create panes nothing can reach."
	exit 5
		;;
esac

# ── helpers ─────────────────────────────────────────────────────────────────
slugify() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# proc_start_time PID — field 22 of /proc/PID/stat, the process start time in
# clock ticks since boot. Combined with the pid AND boot ID this is a process
# identity that survives pid reuse and reboot.
proc_start_time() {
	local pid="$1"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	[[ -r "/proc/$pid/stat" ]] || return 1
	# comm can contain spaces and parentheses; everything after the LAST ')'
	# is positionally stable, so cut there first.
	local stat rest ticks state
	IFS= read -r stat <"/proc/$pid/stat" || return 1
	rest="${stat##*) }"
	state="${rest%% *}"
	[[ "$state" != Z && "$state" != X && "$state" != x ]] || return 1
	ticks="$(awk '{print $20}' <<<"$rest")" || return 1
	[[ "$ticks" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$ticks"
}

record_path() { printf '%s/records/%s' "$STATE_DIR" "$(slugify "$1")"; }

# release_lock — drop the per-task lock. Idempotent: every early return between
# acquiring and launching goes through it, so there is exactly one place that
# knows how to release, and a `return` added later cannot forget to.
release_lock() {
	[[ -n "${lockfd:-}" ]] || return 0
	flock -u "$lockfd" 2>/dev/null || true
	exec {lockfd}>&-
	lockfd=""
}
lock_path() { printf '%s/locks/%s.lock' "$STATE_DIR" "$(slugify "$1")"; }

# ── per-task run ────────────────────────────────────────────────────────────
RC=0
LOCKED_TASKS=()
LAUNCHED=()

run_task() {
	local root="$1" name="$2" runner="$3" heartbeat="$4"

	# ---- validation. Fail before the lock: a bad task file is a configuration
	# error and taking the lock for it would just block the real run.
	[[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
		sayf "task name '$name' is not [A-Za-z0-9_.-]+ — refusing."
		RC=2
		return
	}
	[[ "$runner" == /* ]] || {
		sayf "task '$name': runner '$runner' is not an absolute path."
		sayf "Refusing a relative runner: it would resolve against whatever cwd"
		sayf "the unit happens to have, which is how a task ends up running the"
		sayf "wrong binary of the same name."
		RC=2
		return
	}
	[[ -x "$runner" ]] || {
		sayf "task '$name': runner '$runner' is not executable — capability check failed."
		RC=3
		return
	}
	if [[ -n "$heartbeat" ]]; then
		case "$heartbeat" in
		/*) ;;
		*)
			sayf "task '$name': heartbeat path '$heartbeat' is not absolute."
			RC=2
			return
			;;
		esac
	fi

	# ---- LOCK FIRST, THEN LOOK.
	#
	# 🔴 The lock used to be taken AFTER the record and heartbeat were read.
	# Two resume processes — a manual `systemctl --user start` racing the
	# WantedBy=herdr.service trigger — could both read "no live pid, stale
	# heartbeat". The first took the lock, launched the task, wrote the record and
	# released it; the second then took the lock and launched the SAME task again,
	# because its decision was made from state it had read before the lock was
	# held. That is the duplicate launch the lock exists to prevent, and it is
	# exactly what header item 3 promised against.
	#
	# Non-blocking, so the loser REFUSES (exit 4) rather than queueing and then
	# launching everything a second time when it eventually gets the lock.
	local lockfd lockfile
	lockfile="$(lock_path "$root/$name")"
	exec {lockfd}>"$lockfile" || {
		sayf "cannot open lock $lockfile"
		RC=2
		return
	}
	if ! flock -n "$lockfd"; then
		exec {lockfd}>&-
		sayf "task '$name': another resume holds $lockfile — not launching a duplicate."
		LOCKED_TASKS+=("$name")
		RC=4
		return
	fi

	# ---- identity of the previously recorded run
	local rec pid pid_start recorded_boot alive=0
	rec="$(record_path "$root/$name")"
	pid=""
	pid_start=""
	if [[ -f "$rec" ]]; then
		# `KEY=value`, one per line. Read with grep -o rather than source: this
		# file is written by us but lives in the user's state directory, and
		# `source`ing anything from $HOME is the exact habit being removed from
		# this codebase.
		pid="$(grep -o '^PID=.*' "$rec" 2>/dev/null | head -1 | cut -d= -f2- || true)"
		pid_start="$(grep -o '^PID_START=.*' "$rec" 2>/dev/null | head -1 | cut -d= -f2- || true)"
		recorded_boot="$(grep -o '^BOOT_ID=.*' "$rec" 2>/dev/null | head -1 | cut -d= -f2- || true)"
		if [[ "$recorded_boot" != "$BOOT_ID" ]]; then
			say "task '$name': prior/unknown boot record — heartbeat is not ownership."
		elif [[ "$pid" =~ ^[0-9]+$ ]]; then
			local cur_start
			if cur_start="$(proc_start_time "$pid")" && [[ "$cur_start" == "$pid_start" ]]; then
				alive=1
			else
				sayf "task '$name': pid $pid is gone or has been reused (start time"
				sayf "recorded ${pid_start:-?}, found ${cur_start:-gone}). Treating as dead."
			fi
		fi
	fi

	# ---- heartbeat
	local beat_age=999999999
	if [[ -n "$heartbeat" && -e "$heartbeat" ]]; then
		local mtime now
		mtime="$(stat -c %Y "$heartbeat" 2>/dev/null || echo 0)"
		now="$(date +%s)"
		beat_age=$((now - mtime))
	fi

	if ((alive == 1)) && ((FORCE == 0)); then
		say "task '$name': already running (pid $pid, heartbeat ${beat_age}s old) — not relaunching."
		say "              This is herdr's own restored pane doing the work; relaunching"
		say "              would duplicate it. Use --force to override deliberately."
		release_lock
		return
	fi
	# A heartbeat measures progress, not ownership. Only a live process with
	# matching PID, start ticks AND boot ID can suppress a resume.

	if ((DRY_RUN == 1)); then
		say "DRY-RUN task '$name': would launch '$runner' in '$root' (heartbeat ${heartbeat:-none}, last seen ${beat_age}s ago)."
		LAUNCHED+=("$name")
		release_lock
		return
	fi

	local previous_heartbeat=""
	if [[ -n "$heartbeat" && -e "$heartbeat" ]]; then
		previous_heartbeat="$(stat -c %y "$heartbeat" 2>/dev/null || true)"
	fi
	say "task '$name': launching '$runner' in '$root'."
	# A separate service owns its own cgroup and survives this oneshot's exit.
	# setsid only detaches the session; it is sufficient outside systemd.
	local out="$STATE_DIR/logs" new_pid="" task_unit=""
	mkdir -p "$out"
	if command -v systemd-run >/dev/null 2>&1 &&
		systemctl --user show-environment >/dev/null 2>&1; then
		task_unit="herdr-task-$$-$RANDOM.service"
		if ! systemd-run --user --quiet --collect --service-type=exec \
			--unit="$task_unit" --working-directory="$root" \
			--setenv="HERDR_RESUMED_TASK=$name" --setenv="HERDR_RESUMED_ROOT=$root" \
			--property="StandardOutput=append:$out/$name.log" \
			--property="StandardError=append:$out/$name.log" -- "$runner"; then
			sayf "task '$name': could not start user service $task_unit."
			RC=1
			release_lock
			return
		fi
		new_pid="$(systemctl --user show "$task_unit" --property=MainPID --value 2>/dev/null || true)"
		if [[ ! "$new_pid" =~ ^[1-9][0-9]*$ ]]; then
			sayf "task '$name': user service exited before recording its pid."
			systemctl --user stop "$task_unit" 2>/dev/null || true
			RC=1
			release_lock
			return
		fi
		printf '%s\n' "$new_pid" >"$out/$name.pid"
	elif [[ -n "${INVOCATION_ID:-}" ]]; then
		sayf "task '$name': user systemd is unavailable; cannot detach from this unit."
		RC=1
		release_lock
		return
	else
		(
			cd "$root" || exit 2
			HERDR_RESUMED_TASK="$name" HERDR_RESUMED_ROOT="$root" \
				setsid "$runner" >>"$out/$name.log" 2>&1 < /dev/null &
			echo $!
		) >"$out/$name.pid" || true
		new_pid="$(tr -dc '0-9' <"$out/$name.pid" 2>/dev/null || true)"
	fi

	# Capture identity before waiting: a heartbeat alone is not a live runner.
	local start_time="" current_start=""
	if ! start_time="$(proc_start_time "$new_pid")"; then
		sayf "task '$name': runner exited before establishing a live identity."
		sayf "  see $out/$name.log"
		[[ -z "$task_unit" ]] || systemctl --user stop "$task_unit" 2>/dev/null || true
		RC=1
		release_lock
		return
	fi

	# ---- wait for the first heartbeat, so a task that dies on startup is
	# caught here instead of being reported as successfully resumed.
	local waited=0
	local beat_seen=0
	while ((waited < START_TIMEOUT)); do
		if [[ -n "$heartbeat" && -e "$heartbeat" ]]; then
			local m2 n2
			m2="$(stat -c %Y "$heartbeat" 2>/dev/null || echo 0)"
			n2="$(date +%s)"
			if [[ "$(stat -c %y "$heartbeat" 2>/dev/null || true)" != "$previous_heartbeat" ]] &&
				((n2 - m2 <= MAX_HEARTBEAT_AGE)); then
				beat_seen=1
			fi
		fi
		if ! current_start="$(proc_start_time "$new_pid")" || [[ "$current_start" != "$start_time" ]]; then
			sayf "task '$name': process $new_pid exited or changed identity during startup."
			sayf "  see $out/$name.log"
			RC=1
			release_lock
			return
		fi
		if ((beat_seen == 1)); then break; fi
		sleep 2
		waited=$((waited + 2))
	done

	if ((beat_seen == 0)) && [[ -n "$heartbeat" ]]; then
		sayf "task '$name': no heartbeat within ${START_TIMEOUT}s."
		if [[ -n "$task_unit" ]]; then
			sayf "  stopping unit $task_unit rather than leaving an untracked run."
			systemctl --user stop "$task_unit" 2>/dev/null || true
		elif [[ -n "$new_pid" && -d "/proc/$new_pid" ]]; then
			sayf "  stopping pid $new_pid rather than leaving an untracked run."
			kill "$new_pid" 2>/dev/null || true
		fi
		RC=1
		release_lock
		return
	fi

	if ! current_start="$(proc_start_time "$new_pid")" || [[ "$current_start" != "$start_time" ]]; then
		sayf "task '$name': no matching live runner remains; refusing a running record."
		RC=1
		release_lock
		return
	fi
	{
		printf 'NAME=%s\n' "$name"
		printf 'ROOT=%s\n' "$root"
		printf 'RUNNER=%s\n' "$runner"
		printf 'PID=%s\n' "$new_pid"
		printf 'PID_START=%s\n' "$start_time"
		printf 'BOOT_ID=%s\n' "$BOOT_ID"
		printf 'STARTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} >"$rec"

	say "task '$name': running as pid $new_pid (identity start-time ${start_time:-unknown})."
	LAUNCHED+=("$name")
	release_lock
}

# ── main ────────────────────────────────────────────────────────────────────
ANY_ROOT=0
for root in "${ROOTS[@]}"; do
	if [[ ! -d "$root" ]]; then
		sayf "root '$root' does not exist — skipping (a machine may not have it)."
		continue
	fi
	ANY_ROOT=1
	if [[ -n "$TASKS_FILE" ]]; then
		[[ -r "$TASKS_FILE" ]] || {
			sayf "tasks file '$TASKS_FILE' is not readable."
			exit 2
		}
		tasks="$TASKS_FILE"
	else
		tasks="$root/$OPT_IN_MARKER"
		if [[ ! -r "$tasks" ]]; then
			say "root '$root': no $OPT_IN_MARKER — not opted in, skipping."
			continue
		fi
	fi

	lineno=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))
		line="${line%$'\r'}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		fields="$(awk -F'|' '{print NF}' <<<"$line")"
		if [[ "$fields" != "3" ]]; then
			sayf "$tasks:$lineno: expected 3 '|'-separated fields, got $fields."
			exit 2
		fi
		IFS='|' read -r t_name t_runner t_beat <<<"$line"
		run_task "$root" "$t_name" "$t_runner" "$t_beat"
	done <"$tasks"
done

if ((ANY_ROOT == 0)); then
	say "none of the given roots exist; nothing to resume."
	exit 0
fi

if ((${#LAUNCHED[@]} > 0)); then
	say "resumed: ${LAUNCHED[*]}"
fi
exit "$RC"