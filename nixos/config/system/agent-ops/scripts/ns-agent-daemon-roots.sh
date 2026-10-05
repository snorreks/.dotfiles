#!/usr/bin/env bash
# ns-agent-daemon-roots.sh — pin the ACTUAL RUNNING daemon's Nix closure.
#
# ── The problem this solves ──────────────────────────────────────────────────
# herdr.service deliberately does NOT name a store path. ExecStart is
# /etc/profiles/per-user/%u/bin/herdr, so a `nix flake update herdr` does not
# change the unit text, home-manager does not restart the service, and the
# running server keeps executing the binary it was started from. That is the
# whole point: restarting the server kills every live agent pane.
#
# The cost of that choice is that the running binary is now the ONLY thing
# referencing its store path. It is not in /run/current-system, not in the
# booted closure, and not in any generation. `nix-collect-garbage` is entitled
# to delete it — and when it does, the process keeps running from an unlinked
# inode until it next spawns or dlopen()s something, at which point it dies
# with an error nobody can explain.
#
# ns-maint already pins transaction closures, and those roots do the right
# thing for everything it knows about. But it only knows about the SYSTEM's
# closures: current, booted, candidate. PR #4's running-system roots therefore
# prove nothing at all about a USER daemon that is deliberately executing a
# store path no system closure references. Hence a separate pin, with its own
# name prefix, in the same roots directory.
#
# ── Why it is additive ───────────────────────────────────────────────────────
# Roots here are created as `<gcroots>/ns-ops-<name>` and nothing else in the
# ns-maint transaction format, phase machine or record is touched. `ns-maint gc`
# runs an ordinary `nix-store --gc`, which honours every root it can find under
# the gcroots directory — so these survive its collections, its --keep window
# and its refusal to ever pass --delete, with no coordination at all. And
# `ns-maint roots` will list them, because that command globs `ns-maint-*`...
# which means it will NOT. That is a deliberate, stated gap rather than an
# oversight: widening ns-maint's own listing is A's file, and this lane does
# not edit A's script. `ns-agent-daemon-roots.sh list` is the complete answer.
#
# ── What counts as the daemon ────────────────────────────────────────────────
# The executable the RUNNING process is executing, read from /proc/PID/exe — not
# the path the unit names, and not the newest store path. A daemon that was
# started from a stale profile, or replaced in place, is pinned at whatever it
# is actually running.
#
# ── Exit codes ───────────────────────────────────────────────────────────────
#   0  ok      1  a pin failed or a root is dangling      2  usage
#   3  not privileged (mutating commands)
set -o nounset -o pipefail

# 🔴 errexit OFF, DELIBERATELY. writeShellApplication injects errexit, under
# which `cmd_gc_check`'s `cmd_verify` (which returns 1 to report a dangling root)
# would abort the script before it prints the retention verdict. The tests run
# this file with plain `bash`, which has no errexit.
set +o errexit

PROGRAM_NAME=${0##*/}

# Deliberately the SAME directory ns-maint pins into. That is what makes the
# roots honoured by an ordinary `nix-store --gc` with no extra wiring.
NM_GCROOTS=${NM_GCROOTS:-/nix/var/nix/gcroots}
ROOT_PREFIX=${NS_OPS_ROOT_PREFIX:-ns-ops-}
PROC_ROOT=${PROC_ROOT:-/proc}
# Seam for the test suite, which cannot write to the real /nix/store. Production
# never sets it. Like PROC_ROOT above, it is overridable so a fixture can point
# the script at a model store instead of the real one.
NS_OPS_STORE_ROOT=${NS_OPS_STORE_ROOT:-/nix/store}
# NOT $NIX_STORE. That name is already in the environment of a Nix BUILD, where
# it is the store DIRECTORY, so the script would try to execute a directory the
# moment it ran from a derivation — and, because the failure is swallowed into a
# "could not pin" message, only the test that pins from a build would ever see
# it. Same reason PROC_ROOT is prefixed.
NS_OPS_NIX_STORE=${NS_OPS_NIX_STORE:-nix-store}
SYSTEMCTL_BIN=${SYSTEMCTL_BIN:-systemctl}

say() { printf '%s\n' "$*"; }
sayf() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; }
die() {
	sayf "$*"
	exit 2
}

# Root has no implicit target: its user manager is not the operator's.
if [[ -z "${NS_OPS_USER:-}" ]]; then
	[[ "$(id -u)" != 0 ]] || die "root must set NS_OPS_USER to the target user."
	NS_OPS_USER="$(id -un)"
fi
NS_OPS_UID="$(id -u "$NS_OPS_USER")" || die "cannot resolve target user '$NS_OPS_USER'."

usage() {
	cat >&2 <<EOF
usage: $PROGRAM_NAME <command> [options]

  pin                 resolve every running daemon's executable closure and pin it
  list                print the pinned closures
  verify              re-resolve each pinned root; nonzero if any is missing
  gc-check            run nix-store --gc --dry-run, then verify the roots survived
  release <name>      remove one pin

  NS_OPS_USER         target user (required for root; defaults to self otherwise)

  --unit NAME         systemd user unit to take the main pid from
                       (default: \$NS_OPS_UNIT or herdr.service)
  --pid-file FILE     read the pid from FILE instead of asking systemd
  --name NAME         root name (default: derived from the unit)

exit: 0 ok, 1 failed/dangling, 2 usage, 3 not privileged
EOF
	exit 2
}

require_privileged() {
	[[ "$(id -u)" == "0" ]] && return 0
	[[ "${NS_OPS_TEST_MODE:-0}" == "1" ]] && return 0
	sayf "this needs root (it writes into $NM_GCROOTS)."
	return 3
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]; }

# ── daemon discovery ────────────────────────────────────────────────────────
UNIT=${NS_OPS_UNIT:-herdr.service}
PID_FILE=""
EXPLICIT_PID=""
ROOT_NAME=""
UNITS=()

user_systemctl() {
	if [[ "$(id -u)" == 0 ]]; then
		"$SYSTEMCTL_BIN" --user --machine "$NS_OPS_USER@.host" "$@"
	else
		"$SYSTEMCTL_BIN" --user "$@"
	fi
}

# UID and start ticks are checked before discovery, and again around pinning.
# A numeric PID by itself is not a process identity.
process_identity() {
	local pid="$1" stat uid
	uid="$(awk '/^Uid:/ {print $2}' "$PROC_ROOT/$pid/status" 2>/dev/null)" || return 1
	[[ "$uid" == "$NS_OPS_UID" ]] || return 1
	stat="$(cat "$PROC_ROOT/$pid/stat" 2>/dev/null)" || return 1
	stat="${stat##*) }"
	local -a fields
	read -r -a fields <<<"$stat"
	[[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
	printf '%s:%s' "$uid" "${fields[19]}"
}

is_herdr_server() {
	local pid="$1"
	local -a args=()
	mapfile -d '' -t args <"$PROC_ROOT/$pid/cmdline" 2>/dev/null || return 1
	# The actual packaged invocation is exactly `herdr server`. Status/stop
	# clients and another user's daemon must never replace its root.
	[[ "${#args[@]}" == 2 && "${args[0]##*/}" == herdr && "${args[1]}" == server ]]
}

resolve_pid() {
	if [[ -n "$EXPLICIT_PID" ]]; then
		printf '%s' "$EXPLICIT_PID"
		return
	fi
	if [[ -n "$PID_FILE" ]]; then
		[[ -r "$PID_FILE" ]] || return 1
		local p
		p="$(tr -dc '0-9' <"$PID_FILE")"
		[[ -n "$p" ]] || return 1
		printf '%s' "$p"
		return
	fi
	command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || return 1
	local p
	p="$(user_systemctl show "$UNIT" -p MainPID --value 2>/dev/null)" || return 1
	p="${p//[[:space:]]/}"
	[[ "$p" =~ ^[0-9]+$ ]] || return 1
	[[ "$p" != 0 ]] || return 2 # Confirmed stopped, not a failed query.
	printf '%s' "$p"
}

# Fall back to /proc when systemd cannot answer, because "systemd says 0" is
# exactly the manually-started-server case and refusing to pin it would leave
# the most at-risk daemon unprotected.
resolve_pid_from_proc() {
	local d executable found=''
	local -a args=()
	for d in "$PROC_ROOT"/[0-9]*; do
		process_identity "${d##*/}" >/dev/null || continue
		if [[ "$UNIT" == herdr.service ]]; then
			is_herdr_server "${d##*/}" || continue
		else
			mapfile -d '' -t args <"$d/cmdline" 2>/dev/null || continue
			executable="${args[0]:-}"
			[[ "${executable##*/}" == "${UNIT%.service}" ]] || continue
		fi
		# Multiple manual servers are ambiguous, not permission to pick one.
		[[ -z "$found" ]] || return 1
		found="${d##*/}"
	done
	[[ -n "$found" ]] || return 1
	printf '%s' "$found"
}

# The ACTUAL executable. readlink -f through /proc/PID/exe, which resolves the
# "(deleted)" suffix a collected path would leave behind — and which is exactly
# how you can tell that the binary is ALREADY gone from the store.
daemon_exe() {
	local pid="$1" link
	link="$(readlink "$PROC_ROOT/$pid/exe" 2>/dev/null || true)"
	[[ -n "$link" ]] || return 1
	case "$link" in
	*" (deleted)")
		sayf "WARNING: pid $pid is running a DELETED executable ($link)."
		sayf "         The store path was collected while it ran. Restarting the"
		sayf "         daemon is the only fix; this script will not do it."
		;;
	esac
	link="${link% (deleted)}"
	printf '%s' "$link"
}

is_store_path() {
	local p="$1"
	[[ "$p" == "$NS_OPS_STORE_ROOT"/* ]] || return 1
	local base="${p#"$NS_OPS_STORE_ROOT"/}"
	base="${base%%/*}"
	[[ "$base" =~ ^[a-z0-9]{32}-[A-Za-z0-9._+-]+$ || "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

store_path_of() {
	is_store_path "$1" || return 1
	local base="${1#"$NS_OPS_STORE_ROOT"/}"
	printf '%s/%s' "$NS_OPS_STORE_ROOT" "${base%%/*}"
}

closure_of() {
	"$NS_OPS_NIX_STORE" --query --requisites "$1" 2>/dev/null || return 1
}

# ── pinning ─────────────────────────────────────────────────────────────────
#
# `--add-root` writes a symlink whose NAME is relative to the directory nix is
# invoked from. ns-maint `cd`s into the gcroots directory for exactly this
# reason, and so does this: passing a path would create the root wherever the
# caller happened to be and silently protect nothing.
pin_root() {
	local name="$1" path="$2"
	mkdir -p "$NM_GCROOTS" || {
		sayf "cannot create $NM_GCROOTS"
		return 1
	}
	(cd "$NM_GCROOTS" && "$NS_OPS_NIX_STORE" --add-root "$ROOT_PREFIX$name" --realise "$path") || {
		sayf "nix-store --add-root failed for $name -> $path"
		return 1
	}
	say "pinned $ROOT_PREFIX$name -> $path ($(closure_count "$path") paths in closure)"
}

closure_count() {
	closure_of "$1" 2>/dev/null | wc -l
}

# ── commands ────────────────────────────────────────────────────────────────
cmd_pin() {
	require_privileged || exit $?

	local pid exe store_path identity discovery_rc=0
	pid="$(resolve_pid)" || discovery_rc=$?
	if ((discovery_rc != 0)); then
		# A stopped herdr unit may still have a manually launched server.
		# Other units use /proc only when the manager could not answer.
		if [[ -n "$EXPLICIT_PID" || -n "$PID_FILE" ]] ||
			{ ((discovery_rc == 2)) && [[ "$UNIT" != herdr.service ]]; } ||
			! pid="$(resolve_pid_from_proc)"; then
			sayf "cannot determine a running PID for $UNIT; no root created (discovery status $discovery_rc)."
			return 1
		fi
	fi
	[[ "$pid" =~ ^[0-9]+$ ]] || {
		sayf "refusing to pin: pid '$pid' is not a number."
		return 1
	}

	identity="$(process_identity "$pid")" || {
		sayf "refusing pid $pid: owner or process identity could not be verified."
		return 1
	}
	if [[ "$UNIT" == herdr.service ]] && ! is_herdr_server "$pid"; then
		sayf "refusing pid $pid: not the herdr server invocation."
		return 1
	fi
	if ! exe="$(daemon_exe "$pid")"; then
		sayf "cannot read $PROC_ROOT/$pid/exe."
		return 1
	fi
	say "running daemon: pid $pid, executable $exe"

	if ! is_store_path "$exe"; then
		# Not an error: a manually installed binary has no Nix closure to pin,
		# and pretending otherwise would invent a protection that does not exist.
		sayf "'$exe' is not a Nix store path — there is no closure to pin."
		sayf "This daemon is protected by whatever installed it, not by a GC root."
		return 0
	fi

	store_path="$(store_path_of "$exe")"
	if ! closure_of "$store_path" >/dev/null; then
		sayf "cannot query the closure of $store_path — is it still in the store?"
		sayf "That is the failure this script exists to make impossible."
		return 1
	fi

	local name="${ROOT_NAME:-$UNIT}"
	# The full name including any .service suffix: `herdr.service` matches
	# [A-Za-z0-9_.-]+ and is what the root file is named after. (Stripping
	# ".service" first would leave the EMPTY string, since # removes the whole
	# thing.)
	valid_name "$name" || {
		sayf "root name '$name' must be [A-Za-z0-9_.-]+"
		return 2
	}
	[[ "$(process_identity "$pid")" == "$identity" && "$(daemon_exe "$pid")" == "$exe" ]] || {
		sayf "refusing pid $pid: process changed while querying its closure."
		return 1
	}
	pin_root "$name" "$store_path" || return 1
	[[ "$(process_identity "$pid")" == "$identity" && "$(daemon_exe "$pid")" == "$exe" ]] || {
		sayf "pid $pid changed while pinning; retry before collecting."
		return 1
	}

	# The root is only useful if it points at the store path containing the running binary.
	verify_one "$name" "$store_path"
}

verify_one() {
	# Takes the BARE name; the prefix is added here. The callers that discover
	# roots by globbing get a name that already has the prefix on it, and
	# prepending a second time is how `ns-ops-ns-ops-herdr.service` happened.
	local name="$1" expect="${2:-}"
	local root="$NM_GCROOTS/$ROOT_PREFIX$name" target
	if [[ ! -e "$root" && ! -L "$root" ]]; then
		sayf "MISSING root $ROOT_PREFIX$name"
		return 1
	fi
	target="$(readlink -f "$root" 2>/dev/null || true)"
	if [[ -z "$target" || ! -e "$target" ]]; then
		sayf "DANGLING root $ROOT_PREFIX$name -> ${target:-<unreadable>}"
		return 1
	fi
	if [[ -n "$expect" && "$target" != "$expect" ]]; then
		sayf "MOVED root $ROOT_PREFIX$name: pinned $target, running $expect"
		return 1
	fi
	say "ok   $ROOT_PREFIX$name -> $target"
	return 0
}

cmd_list() {
	local root name found=0
	shopt -s nullglob
	for root in "$NM_GCROOTS/$ROOT_PREFIX"*; do
		[[ -e "$root" || -L "$root" ]] || continue
		found=1
		name="${root##*/}"
		printf '%-40s %s\n' "$name" "$(readlink -f "$root" 2>/dev/null || echo '(unreadable)')"
	done
	shopt -u nullglob
	((found == 1)) || say "no $ROOT_PREFIX* daemon roots are pinned."
	return 0
}

cmd_verify() {
	local root file rc=0
	shopt -s nullglob
	local -a roots=("$NM_GCROOTS/$ROOT_PREFIX"*)
	shopt -u nullglob
	((${#roots[@]} > 0)) || {
		say "no $ROOT_PREFIX* daemon roots are pinned; nothing to verify."
		return 0
	}
	for root in "${roots[@]}"; do
		file="${root##*/}"
		verify_one "${file#"$ROOT_PREFIX"}" || rc=1
	done
	return "$rc"
}

# ── The GC retention proof ──────────────────────────────────────────────────
#
# Running a real collection is not something a check may do, so this runs the
# collector's OWN dry run and then re-resolves every root. A root that a
# collection would delete fails here, before it matters.
cmd_gc_check() {
	require_privileged || exit $?
	local before
	before="$(cmd_list)"
	say "--- roots before ---"
	printf '%s\n' "$before"
	say "--- nix-store --gc --dry-run ---"
	if ! "$NS_OPS_NIX_STORE" --gc --dry-run 2>&1 | tail -n 20; then
		sayf "collector dry run failed; retention is not verified."
		return 1
	fi
	say "--- roots after dry-run ---"
	cmd_verify
	rc=$?
	if ((rc == 0)); then
		say "every $ROOT_PREFIX* root survived the collector's dry run."
		say "ns-maint gc runs the same collector without --delete, so these roots"
		say "are honoured by it too. They are independent of any transaction: a"
		say "pin exists whether or not a maintenance record does."
	fi
	return "$rc"
}

cmd_release() {
	require_privileged || exit $?
	local name="${1:-}"
	[[ -n "$name" ]] || die "release needs a root name."
	local root="$NM_GCROOTS/$ROOT_PREFIX$name"
	if [[ ! -e "$root" && ! -L "$root" ]]; then
		sayf "no such root: $ROOT_PREFIX$name"
		return 1
	fi
	rm -f "$root" "$root.link"
	say "released $ROOT_PREFIX$name"
	return 0
}

# ── dispatch ────────────────────────────────────────────────────────────────
CMD=${1:-}
[[ -n "$CMD" ]] || usage
shift || true

# Captured BEFORE the option loop shifts, because `release <name>` needs the
# positional argument and the loop would otherwise eat it.
REST_ARG1=${1:-}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--unit)
		UNITS+=("$2")
		shift 2
		;;
	--unit=*) UNITS+=("${1#--unit=}"); shift ;;
	--pid-file)
		PID_FILE="$2"
		shift 2
		;;
	--pid-file=*) PID_FILE="${1#--pid-file=}"; shift ;;
	--pid)
		EXPLICIT_PID="$2"
		shift 2
		;;
	--pid=*) EXPLICIT_PID="${1#--pid=}"; shift ;;
	--name)
		ROOT_NAME="$2"
		shift 2
		;;
	--name=*) ROOT_NAME="${1#--name=}"; shift ;;
	-h | --help) usage ;;
	# A bare word is a positional (the name `release` takes), not an option.
	*) break ;;
	esac
done

case "$CMD" in
pin)
	((${#UNITS[@]})) || UNITS=("$UNIT")
	rc=0
	for UNIT in "${UNITS[@]}"; do cmd_pin || rc=1; done
	exit "$rc"
	;;
list) cmd_list ;;
verify) cmd_verify ;;
gc-check) cmd_gc_check ;;
release) cmd_release "$REST_ARG1" ;;
*) usage ;;
esac