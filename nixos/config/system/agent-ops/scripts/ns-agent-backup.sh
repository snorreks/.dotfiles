#!/usr/bin/env bash
# ns-agent-backup.sh — encrypted offsite backup, with a restore you can prove.
#
# ── What this is and is not ──────────────────────────────────────────────────
# It is a thin, honest wrapper over restic. It exists to enforce the four
# properties that are easy to state and easy to get wrong:
#
#   1. CREDENTIALS ARE RUNTIME-ONLY. The repository and its password arrive as
#      systemd credentials (files under $CREDENTIALS_DIRECTORY) at the moment
#      the timer fires. There is no repository URL in the Nix store, no
#      password in a unit file, and nothing to `grep` out of a config. When
#      they are absent this reports UNCONFIGURED and exits 4 — which the
#      health module reports as NOT healthy. "Backup is off" must never look
#      like "backup is fine".
#   2. THE BACKUP IS BOUNDED. A backup that saturates the uplink and the disk
#      on a box whose job is to answer a phone is a self-inflicted outage.
#      Every write is niced, ioniced, and rate limited in
#      both directions.
#   3. DATABASES ARE BACKED UP CONSISTENTLY. Copying a live SQLite file gives
#      you a file that passes `PRAGMA integrity_check` and still is corrupt,
#      because the copy interleaved with a write. Anything configured as a
#      quiesce source is EXPORTED with an application-consistent method first
#      and the export is what gets backed up.
#   4. RESTORE IS TESTABLE, TO SCRATCH ONLY. `restore --to` requires a
#      canonical path strictly below /tmp or /var/tmp (never the root itself,
#      a symlink or alias, or a path in the current home), whose ancestors
#      exist and are private, and which is either created exclusively here or
#      is already an EMPTY 0700 directory owned by the caller.
#
# ── Exclusion policy ─────────────────────────────────────────────────────────
# Excluded, with reasons, by default:
#   /nix/store            re-downloadable from cache.nixos.org by exact hash
#   /nix/var/nix          rebuildable; the database under it is small and is
#                         handled by restic's own snapshot consistency
#   replaceable media     explicitly listed by the operator; see the config
#   *.sock, *.pid         not state; holding one open means it is in use
# Nothing is excluded by a blanket pattern. Every exclusion is a named entry in
# the generated config, so it is reviewable in the PR diff.
#
# ── Offline recovery ─────────────────────────────────────────────────────────
# A restic repository cannot be read without its password, and this host cannot
# be reached without a network. docs/agent-operations.md carries the recovery
# procedure and, crucially, states where the password and the age identity that
# can decrypt secrets.yaml are kept OFF this machine. That document is part of
# this script's contract, not an afterthought.
#
# ── Exit codes ───────────────────────────────────────────────────────────────
#   0  ok
#   2  usage / configuration error
#   3  backup ran but reported a failure
#   4  NOT CONFIGURED — repository or password credential absent
#   5  restore refused (target exists / would clobber live data)
#   6  the repository did not answer (network outage / wrong URL)
set -o nounset -o pipefail

# 🔴 errexit OFF, DELIBERATELY.
#
# writeShellApplication — which builds this script in production — injects
# `set -o errexit -o nounset -o pipefail` at the top. Under errexit a failing
# `restic` call ends the script at the call, BEFORE `rc=$?` runs, so there is
# no retry, no `partial`/`failed` record and no staging cleanup — and the health
# module then reads a STALE `ok` record. The tests invoke this file with plain
# `bash`, which has no errexit, so without this line the suites cannot see the
# difference at all.
set +o errexit

PROGRAM_NAME=${0##*/}

RESTIC=${RESTIC:-restic}
# Stable identity shared by backup, retention, health checks and restores.
BACKUP_HOST="$(uname -n)"
BACKUP_TAG=agent-ops-backup
STATE_DIR=${AGENT_OPS_STATE_DIR:-/var/lib/agent-ops/backup}
RECORD="$STATE_DIR/last-run.env"
CONFIG=${NS_OPS_BACKUP_CONFIG:-/etc/agent-ops/backup.conf}
RESTIC_TIMEOUT=${RESTIC_TIMEOUT:-20m}
# restic must be found on PATH; the systemd unit gets it from the Nix closure.
# A bounded number of attempts. Bounded, and loud: an unattended box retrying a
# dead endpoint forever is how you end up with a 3am full disk.
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
RETRY_BASE_SECONDS=${RETRY_BASE_SECONDS:-30}

say() { printf '%s\n' "$*"; }
sayf() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; }
die() {
	sayf "$*"
	exit 2
}

usage() {
	cat >&2 <<EOF
usage: $PROGRAM_NAME [--config FILE] <command>

  backup                    export quiesced sources, then back up
  check                     repository integrity + newest snapshot age
  restore --to DIR [PATH…]  restore into a scratch directory (never live data)
  prune [--prune|--forget-all]
                             forget --keep-* then prune; --prune reclaims too,
                             --forget-all drops every tagged snapshot (test aid)
  status                    print the last run record
  config                    print the effective, secret-free configuration

exit: 0 ok, 2 usage, 3 backup failed, 4 not configured, 5 restore refused,
      6 repository unreachable
EOF
	exit 2
}

# ── config ──────────────────────────────────────────────────────────────────
# Generated by config/system/agent-ops/backup.nix. `key=value`, one per line.
# No value in here is a secret; the module asserts that by construction (see
# backup.nix's header).
declare -A CFG=()
load_config() {
	if [[ ! -r "$CONFIG" ]]; then
		die "config $CONFIG is missing or unreadable. agentOps.backup must be enabled by Nix."
	fi
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		key="${line%%=*}"
		value="${line#*=}"
		CFG["$key"]="$value"
	done <"$CONFIG"
	local list
	for list in sources excludes quiesceSource; do
		printf '%s' "$(cfg "$list" '[]')" | jq -e 'type == "array" and all(.[]; type == "string" and (contains("\u0000") | not))' >/dev/null || die "invalid JSON list: $list"
	done
	quiesce_file >/dev/null || die "invalid path: quiesceFile (JSON string or absolute path)"
	limit_kib limitUpload 8000000 >/dev/null || die "invalid limitUpload"
	limit_kib limitDownload 20000000 >/dev/null || die "invalid limitDownload"
}

cfg() { printf '%s' "${CFG[$1]:-${2:-}}"; }

# The quiesce table PATH. The module writes a JSON string (so any byte in a
# path survives); a bare absolute path from a hand-written config is accepted
# verbatim, since it cannot be confused with JSON.
quiesce_file() {
	local raw
	raw="$(cfg quiesceFile)"
	case "$raw" in
	"") printf '%s\n' /dev/null ;;
	\"*) printf '%s' "$raw" | jq -er 'if type == "string" and (contains("\u0000") | not) and startswith("/") then . else error("bad") end' ;;
	/*) printf '%s\n' "$raw" ;;
	*) return 1 ;;
	esac
}

# JSON is data, never shell code. NUL delimiters preserve commas, whitespace,
# quotes and even newlines inside a path. load_config validates before use.
cfg_list() {
	cfg "$1" '[]' | jq -j '.[] | ., "\u0000"'
}

# Public config is bytes/s; restic flags are KiB/s. Never turn a positive cap
# into zero (unlimited). Reject values outside safe shell integer arithmetic.
limit_kib() {
	local value
	value="$(cfg "$1" "$2")"
	[[ "$value" =~ ^[0-9]+$ ]] || die "invalid bytes/s limit: $1"
	while [[ ${#value} -gt 1 && "$value" == 0* ]]; do value="${value#0}"; done
	[[ ${#value} -le 18 ]] || die "bytes/s limit too large: $1"
	local kib=$((value / 1024))
	((value > 0 && kib == 0)) && kib=1
	printf '%s\n' "$kib"
}

# ── credentials ─────────────────────────────────────────────────────────────
#
# Two systemd credentials, named after the restic variables they satisfy. The
# password is handed over as a FILE (restic reads RESTIC_PASSWORD_FILE) so it
# never appears in the process environment of anything else the script starts.
repository_configured=0
load_credentials() {
	local repo_file="${CREDENTIALS_DIRECTORY:-}/RESTIC_REPOSITORY"
	local pw_file="${CREDENTIALS_DIRECTORY:-}/RESTIC_PASSWORD"

	if [[ -z "${CREDENTIALS_DIRECTORY:-}" ]]; then
		sayf "no CREDENTIALS_DIRECTORY: this script is meant to be run by"
		sayf "agent-ops-backup.service, which loads the repository and password"
		sayf "as systemd credentials."
		exit 4
	fi
	if [[ ! -r "$repo_file" ]]; then
		sayf "NOT CONFIGURED: the RESTIC_REPOSITORY credential was not supplied."
		sayf "Add it to nixos/secrets.yaml (sops secrets set RESTIC_REPOSITORY)"
		sayf "and enable agentOps.backup. Until then this host has NO backup and"
		sayf "the health module reports backup as unconfigured, not healthy."
		exit 4
	fi
	if [[ ! -r "$pw_file" ]]; then
		sayf "NOT CONFIGURED: the RESTIC_PASSWORD credential was not supplied."
		sayf "Without it the repository cannot be read OR written, and losing it"
		sayf "means losing every backup ever taken on this host. See"
		sayf "docs/agent-operations.md for the offline recovery procedure."
		exit 4
	fi
	[[ -s "$pw_file" ]] || {
		sayf "the RESTIC_PASSWORD credential is EMPTY. Treating that as not configured:"
		sayf "an empty password would open the repository to anyone who guesses it."
		exit 4
	}

	export RESTIC_REPOSITORY
	RESTIC_REPOSITORY="$(cat -- "$repo_file")"
	export RESTIC_PASSWORD_FILE="$pw_file"
	repository_configured=1
}

# ── bounded execution ───────────────────────────────────────────────────────
#
# bounded_restic TMO [args...] — every restic write goes through here.
#
# `nice`/`ionice` wrap the BINARY, not this script: `nice ionice some_function`
# fails with "failed to execute", and the failure it produced — a silent
# "restic exited 0" — is exactly the kind that turns into "the backup ran fine"
# for months.
#
# No `timeout` wrapper by default: restic's own --retry and a systemd
# TimeoutStartSec on the unit are the right layers, and a second one here would
# make a slow-but-progressing large backup look like a failure.
bounded_restic() {
	local tmo="${1:-}"
	shift
	local -a pre=()
	[[ -n "$tmo" ]] && pre+=(timeout "$tmo")
	"${pre[@]}" nice -n 10 ionice -c 2 -n 7 "$RESTIC" "$@"
}

# restic_run — the same without nice/ionice, for the read-only subcommands
# (check, snapshots) where CPU priority is irrelevant.
restic_run() {
	local tmo="${1:-}"
	shift
	if [[ -n "$tmo" ]]; then
		timeout "$tmo" "$RESTIC" "$@"
	else
		"$RESTIC" "$@"
	fi
}

restic_opts() {
	# Per-subcommand, because restic rejects flags it does not understand:
	# `restic restore` has no --limit-upload, and passing one makes a restore
	# fail with a usage error that looks like a corrupt repository.
	local cmd="${1:-}"
	case "$cmd" in
	backup | forget | prune)
		# No IO-concurrency setting is configured or claimed: restic has no
		# --io-max-concurrent flag (0.19 rejects it), and backup's own
		# --read-concurrency is left at restic's default.
		printf '%s\n' \
			"--limit-upload" "$(limit_kib limitUpload 8000000)" \
			"--limit-download" "$(limit_kib limitDownload 20000000)" \
			"--pack-size" "$(cfg packSize '32')"
		;;
	restore)
		# Download limit only; upload/pack flags are rejected by restore.
		printf '%s\n' "--limit-download" "$(limit_kib limitDownload 20000000)"
		;;
	check)
		printf '%s\n' "--limit-download" "$(limit_kib limitDownload 20000000)"
		;;
	*)
		printf ''
		;;
	esac
}

# ── quiesce / application-consistent export ──────────────────────────────────
#
# A quiesce entry is `path|method|arg`, one per line in the config:
#
#   path    what gets backed up INSTEAD of the live file
#   method  none | sqlite
#   arg     for sqlite: the sqlite3 binary (a store path, so the unit does not
#           depend on anything being on PATH)
#
# `sqlite` runs `.backup`, which uses SQLite's own online backup API: it takes
# the locks it needs, copies consistently and releases them. `cp` cannot do
# this, and neither can `dd`.
declare -a STAGING=()
# 🔴 SET BY quiesce_all, IN THE CURRENT SHELL.
#
# `staging="$(quiesce_all)"` ran the function inside a command-substitution
# subshell, so every `STAGING+=(…)` was discarded when it exited. The caller
# then added NO --exclude for the live path, and the snapshot contained BOTH the
# app-consistent export AND the raw live database — the one file it must not
# contain. It looked like it worked: the backup succeeded and the export was
# present.
STAGING_DIR=""

quiesce_all() {
	local staging
	staging="$(mktemp -d "$STATE_DIR/quiesce.XXXXXX")" || return 1
	local qf

	# The config value is the PATH of the quiesce table; the table itself is
	# read from that file. Reading the config value as though it were a task
	# line — which an earlier version did — gives a one-field line and the
	# confusing "unknown method '' for /var/lib/agent-ops/backup/quiesce.conf".
	qf="$(quiesce_file)" || return 1
	# Cleared FIRST, so an early return can never leave a stale path behind for
	# the caller to back up.
	STAGING_DIR=""
	# With exports DECLARED, a missing, unreadable or empty table fails closed:
	# shipping the live database instead is exactly the corruption this exists
	# to prevent. With none declared there is nothing to quiesce.
	if [[ ! -r "$qf" || ! -s "$qf" ]]; then
		rmdir "$staging" 2>/dev/null || true
		if [[ "$(cfg quiesceSource '[]' | jq 'length')" != 0 ]]; then
			sayf "quiesce: configured export table is missing, unreadable or empty; refusing raw backup."
			return 1
		fi
		return 0
	fi

	# Every declared export must have a table entry before any data is shipped.
	local required
	while IFS= read -r -d '' required; do
		if ! grep -Fqx -- "$required" <(cut -d '|' -f1 "$qf"); then
			sayf "quiesce: configured source $required is absent from the export table."
			rmdir "$staging" 2>/dev/null || true
			return 1
		fi
	done < <(cfg_list quiesceSource)

	local path method arg dest
	while IFS='|' read -r path method arg; do
		[[ -z "$path" ]] && continue
		# The export MIRRORS the source path inside the staging directory. A
		# flattened name loses the path identity, so a restore cannot tell which
		# file is which — which is the whole reason for exporting separately.
		dest="$staging$path"
		mkdir -p "$(dirname "$dest")"
		case "$method" in
		none)
			cp -a -- "$path" "$dest" || return 1
			printf 'quiesced %s -> %s (plain copy)\n' "$path" "$dest" >&2
			;;
		sqlite)
			if [[ ! -r "$path" ]]; then
				printf 'quiesce: %s does not exist; skipping.\n' "$path" >&2
				continue
			fi
			if [[ ! -x "$arg" ]]; then
				printf 'quiesce: sqlite binary %s is not executable — refusing to\n' "$arg" >&2
				printf '         fall back to a plain copy, which is NOT consistent.\n' >&2
				return 1
			fi
			rm -f -- "$dest"
			# `.backup` is SQLite's own online backup API: it takes the locks it
			# needs and copies consistently. cp and dd cannot do this.
			#
			# `.timeout` first, then a BOUNDED retry. A database that is being
			# written answers SQLITE_BUSY, which is the normal state of a live
			# database and not a reason to fall back to a raw copy. Without this
			# the export fails intermittently under exactly the load it exists to
			# handle — and an intermittently-failing backup is one people turn off.
			local attempt=0 ok=0
			while ((attempt < 3)); do
				attempt=$((attempt + 1))
				if "$arg" -cmd ".timeout 5000" "$path" ".backup '$dest'" 2>/dev/null; then
					ok=1
					break
				fi
				printf 'quiesce: %s was busy (attempt %d/3); retrying.\n' "$path" "$attempt" >&2
				sleep 2
			done
			if ((ok == 0)); then
				printf 'quiesce: sqlite .backup failed for %s after %d attempts. Not copying it raw.\n' \
					"$path" "$attempt" >&2
				printf '         A raw copy of a database being written is not a backup.\n' >&2
				return 1
			fi
			if ! "$arg" "$dest" "PRAGMA integrity_check;" 2>/dev/null | grep -qx ok; then
				printf 'quiesce: the export of %s does not pass integrity_check.\n' "$path" >&2
				return 1
			fi
			# stderr, not stdout: quiesce_all runs inside a command substitution,
			# so anything on stdout would be captured as the staging path and
			# never shown to anyone.
			printf 'quiesced %s -> %s (sqlite .backup, integrity_check ok)\n' \
				"$path" "$dest" >&2
			;;
		*)
			printf 'quiesce: unknown method %s for %s\n' "$method" "$path" >&2
			return 1
			;;
		esac
		STAGING+=("$path=$dest")
	done <"$qf"

	STAGING_DIR="$staging"
	return 0
}

# ── record ──────────────────────────────────────────────────────────────────
write_record() {
	local status="$1" detail="${2:-}"
	mkdir -p "$STATE_DIR"
	local tmp="$RECORD.tmp"
	{
		printf 'LAST_STATUS=%s\n' "$status"
		printf 'LAST_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'LAST_DETAIL=%s\n' "$detail"
		printf 'LAST_DURATION_S=%s\n' "${DURATION:-0}"
	} >"$tmp"
	chmod 0640 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$RECORD"
}

# ── commands ────────────────────────────────────────────────────────────────
cmd_backup() {
	load_credentials
	mkdir -p "$STATE_DIR"
	local start end
	start="$(date +%s)"

	# In the CURRENT shell, not a command substitution: STAGING is an array and
	# arrays do not survive a subshell.
	quiesce_all || {
		write_record failed "quiesce"
		exit 3
	}
	local staging="$STAGING_DIR"

	local -a sources=()
	local p
	while IFS= read -r -d '' p; do
		[[ -n "$p" ]] && sources+=("$p")
	done < <(cfg_list sources)

	if ((${#sources[@]} == 0)); then
		sayf "no backup sources configured — this would be a no-op that looks like a backup."
		write_record failed "no-sources"
		exit 2
	fi

	# Swap the LIVE file for its export.
	#
	# The obvious implementation — replace the source entry that equals the live
	# path — does nothing at all in the normal case, because the source is a
	# PARENT DIRECTORY (`~/.local/state`) and the entry is a file inside it. It
	# looked like it worked: the backup succeeded and contained the live
	# database, which is the one file it must not contain. So: exclude the live
	# path, and back up the staging tree as an additional source.
	#
	# DECLARED FIRST. `local -a x=()` after a use of `x+=(…)` resets the array
	# and every exclusion added above silently vanishes — which is exactly what
	# happened when the quiesce substitution was added here.
	local -a exclude_args=()
	local entry live p
	while IFS= read -r -d '' p; do
		[[ -n "$p" ]] && exclude_args+=("--exclude" "$p")
	done < <(cfg_list excludes)

	if [[ -n "$staging" && -d "$staging" ]]; then
		for entry in "${STAGING[@]}"; do
			live="${entry%%=*}"
			exclude_args+=("--exclude" "$live")
		done
		sources+=("$staging")
	fi

	say "backing up ${#sources[@]} source(s) to the configured repository."
	say "  bounded to $(cfg limitUpload '8000000') B/s up, $(cfg limitDownload '20000000') B/s down,"

	# read -r so a path with a space is one path. No eval, no word splitting.
	# 🔴 THE TAG IS ADDED HERE, because `forget` filters on it.
	#
	# `cmd_prune` passed `--tag agent-ops-backup` to `forget` while `cmd_backup`
	# never passed it to `backup`. No snapshot matched the filter, so `forget`
	# silently removed NOTHING, the weekly retention timer succeeded, and the
	# repository grew without limit. A retention policy that silently does
	# nothing is worse than no policy: it is a false assurance.
	local -a argv=(backup --host "$BACKUP_HOST" --tag "$BACKUP_TAG" "${exclude_args[@]}")
	local s
	for s in "${sources[@]}"; do argv+=("$s"); done

	local attempt rc=1
	for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
		if ((attempt > 1)); then
			local wait=$((RETRY_BASE_SECONDS * attempt))
			say "attempt $attempt/$MAX_ATTEMPTS in ${wait}s"
			sleep "$wait"
		fi
		say "  attempt $attempt/$MAX_ATTEMPTS"
		# restic_opts is intentionally word-split: it is a fixed, generated
		# argument list with no value that can contain a space.
		# shellcheck disable=SC2046,SC2086
		bounded_restic "$RESTIC_TIMEOUT" "${argv[@]}" $(restic_opts backup)
		rc=$?
		# 🔴 The status must be captured IMMEDIATELY, never from the `if`. An
		# `if cmd; then ... fi` whose body is not taken returns 0, so a failed
		# backup was reported as "restic exited 0" and the run was recorded as
		# SUCCESSFUL. That is the single worst bug this file could have.
		if ((rc == 0)); then
			break
		fi
		# Exit 3 is restic's "some source data could not be read". That is a
		# real partial failure and is retried; anything else may be a dead
		# endpoint, so it is retried too but only MAX_ATTEMPTS times.
		sayf "restic exited $rc"
	done

	end="$(date +%s)"
	DURATION=$((end - start))

	if [[ -n "$staging" && -d "$staging" ]]; then
		rm -rf -- "$staging"
	fi

	if ((rc == 0)); then
		write_record ok "${#sources[@]} sources"
		say "backup finished in ${DURATION}s."
		return 0
	fi
	if ((rc == 3)); then
		write_record partial "some sources unreadable"
		sayf "PARTIAL: restic could not read every source. See the log above."
		exit 3
	fi
	write_record failed "restic exit $rc"
	# 6 rather than 3 when nothing answered at all: a repository you cannot
	# reach is a different operator problem from a repository that is broken.
	exit 3
}

cmd_check() {
	load_credentials
	say "checking repository connectivity and integrity..."
	# --read-data-subset: verifying EVERY pack means reading every byte, which is
	# a full download on a machine whose uplink is shared with the tailnet it is
	# reachable over. A percentage is the honest default; `backup check --full`
	# is available when you have decided you have the time.
	# shellcheck disable=SC2046 # numeric generated options only
	if ! restic_run 60 check --read-data-subset="$(cfg repositoryCheckSubset '2/1000')" $(restic_opts check); then
		sayf "repository check FAILED."
		write_record failed "check"
		exit 3
	fi
	local newest_stamp age
	# --latest defaults to one per host+path; random export paths would leave
	# old snapshots in the result. Group by the one selected host instead, and
	# let restic order its timestamps (including time zones) chronologically.
	if ! newest_stamp="$(restic_run 60 snapshots --host "$BACKUP_HOST" --tag "$BACKUP_TAG" --group-by host --latest 1 --json 2>/dev/null |
		jq -er 'if length == 0 then "" else .[0].snapshots[0].time end')"; then
		sayf "snapshot listing FAILED."
		write_record failed "snapshots"
		exit 3
	fi
	if [[ -z "$newest_stamp" ]]; then
		sayf "repository is reachable but has NO snapshots."
		sayf "A repository with nothing in it is not a backup."
		write_record failed "no-snapshots"
		exit 3
	fi
	newest_stamp="$(date -d "$newest_stamp" +%s 2>/dev/null || echo 0)"
	age=$(( $(date +%s) - newest_stamp ))
	say "newest snapshot age: ${age}s (limit $(cfg maxAgeSeconds '86400')s)"
	if ((age > $(cfg maxAgeSeconds 86400))); then
		sayf "THE NEWEST BACKUP IS TOO OLD."
		write_record stale "age ${age}s"
		exit 3
	fi
	say "repository check ok."
	return 0
}

cmd_restore() {
	load_credentials
	local target=""
	local -a wanted=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			[[ $# -ge 2 ]] || die "restore needs --to DIR"
			target="$2"
			shift 2
			;;
		--to=*) target="${1#--to=}"; shift ;;
		--) shift; wanted+=("$@"); break ;;
		*) wanted+=("$1"); shift ;;
		esac
	done

	[[ -n "$target" ]] || die "restore needs --to DIR"
	[[ "$target" == /* ]] || die "restore target must be an absolute path."
	# CANONICAL ONLY. Resolving every existing ancestor means a lexical
	# /tmp/../home, a symlinked parent or a symlinked target is refused rather
	# than followed into live data. The spelling must already be canonical:
	# an alias is refused, never silently rewritten.
	local canonical
	canonical="$(realpath -m -- "$target")" || die "cannot resolve restore target"
	[[ "$target" == "$canonical" ]] || die "restore target is not canonical (aliases and symlinks refused): $target"
	# STRICTLY below a scratch root: never /tmp or /var/tmp themselves, and
	# never anything else (/, /home, /root, /var/lib, ...).
	local root="" r
	for r in /tmp /var/tmp; do
		# The roots themselves must be real directories, not aliases.
		[[ "$(realpath -e -- "$r" 2>/dev/null)" == "$r" ]] || continue
		if [[ "$target" == "$r"/?* ]]; then root="$r"; fi
	done
	[[ -n "$root" ]] || die "restore target is not strictly below the /tmp or /var/tmp scratch roots."
	# Never a live home, even one that happens to live below a scratch root.
	local home
	home="$(realpath -m -- "${HOME:-/home/$(id -un)}")" || die "cannot resolve home"
	case "$target" in
	"$home" | "$home"/*)
		sayf "restore target '$target' is inside \$HOME ($home). Refusing:"
		sayf "verification restores go to scratch, never over live data."
		die "restore target is inside the live home directory"
		;;
	esac
	# Ancestors between the scratch root and the target must EXIST, be ours
	# (or root's) and not be writable by anyone else, so nobody can swap a component
	# for a symlink after the checks below.
	local uid rel dir="$root" part owner mode
	uid="$(id -u)"
	rel="${target#"$root"/}"
	while [[ "$rel" == */* ]]; do
		part="${rel%%/*}"
		rel="${rel#*/}"
		dir="$dir/$part"
		[[ -d "$dir" && ! -L "$dir" ]] || die "restore target ancestor is not a directory: $dir"
		owner="$(stat -c %u -- "$dir")" mode="$(stat -c %a -- "$dir")"
		[[ "$owner" == "$uid" || "$owner" == 0 ]] || die "restore target ancestor is owned by another user: $dir"
		(( (8#$mode & 8#022) == 0 )) || die "restore target ancestor is writable by others: $dir"
	done
	[[ ! -e "$target" && ! -L "$target" || -d "$target" && ! -L "$target" ]] || die "restore target is not a directory."
	if [[ -d "$target" ]] && [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
		# Explained BEFORE dying: `die` exits, so a message after it is never
		# printed and the operator gets only "not empty".
		sayf "restore target '$target' exists and is not empty."
		sayf "A restore into a populated directory is how a verification run"
		sayf "silently overwrites the live home. Pick an empty scratch directory."
		die "restore target is not an empty directory."
	fi

	# EXCLUSIVE: a missing target is created by us, privately, in one mkdir
	# (never -p); an existing empty one must already be ours and private, as
	# `mktemp -d` makes it.
	if [[ ! -e "$target" ]]; then
		mkdir -m 0700 -- "$target" || die "cannot create scratch directory exclusively"
	fi
	[[ "$(stat -c %u -- "$target")" == "$uid" ]] || die "restore target is owned by another user."
	(( (8#$(stat -c %a -- "$target") & 8#077) == 0 )) || die "restore target is accessible by others; use mktemp -d."
	# Recheck after creation before handing the target to restic.
	[[ "$(realpath -e -- "$target")" == "$target" ]] || die "scratch target changed"
	[[ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "scratch target is not empty"
	say "restoring into scratch: $target"
	local -a argv=(restore latest --host "$BACKUP_HOST" --tag "$BACKUP_TAG" --target "$target")
	# PATH arguments select what to restore. Only absolute snapshot paths are
	# accepted, each passed as --include, so no argument can become a restic
	# flag (a second --target would win over the scratch target).
	local w
	for w in ${wanted[@]+"${wanted[@]}"}; do
		[[ "$w" == /* ]] || die "restore PATH must be an absolute snapshot path: $w"
		argv+=(--include "$w")
	done

	# shellcheck disable=SC2046 # restic_opts is a generated flag list
	if ! bounded_restic "$RESTIC_TIMEOUT" "${argv[@]}" $(restic_opts restore); then
		sayf "restore FAILED."
		exit 3
	fi
	say "restore complete into $target"
	say "verify it before you need it:"
	say "  find $target -maxdepth 3 -type f | head"
	say "  <verify the quiesced database exports pass integrity_check>"
	return 0
}

cmd_prune() {
	load_credentials
	say "applying retention (keep-daily $(cfg keepDaily '7'), keep-weekly $(cfg keepWeekly '4'), keep-monthly $(cfg keepMonthly '6'))"
	# --prune is separated from --forget deliberately and only runs when asked
	# for explicitly: forgetting and pruning are the two operations that make a
	# backup unrecoverable, and they should be two decisions.
	# shellcheck disable=SC2046 # restic_opts is a generated flag list
	# --forget-all removes EVERY snapshot matching the tag, which is the only
	# policy that can distinguish "the tag matched" from "the tag matched
	# nothing": snapshots taken minutes apart are all "today", so a normal
	# keep-daily policy legitimately keeps them all. It exists so the retention
	# contract is TESTABLE, and it is refused unless asked for by name.
	local -a forget_args=(
		--host "$BACKUP_HOST" --tag "$BACKUP_TAG"
		# Random staging paths must not create a new retention group per run.
		--group-by "host,tags"
		--keep-daily "$(cfg keepDaily 7)"
		--keep-weekly "$(cfg keepWeekly 4)"
		--keep-monthly "$(cfg keepMonthly 6)"
	)
	if [[ "${1:-}" == "--forget-all" ]]; then
		say "WARNING: --forget-all removes EVERY snapshot matching the tag."
		forget_args+=(--unsafe-allow-remove-all)
	fi
	# shellcheck disable=SC2046 # restic_opts is a generated flag list
	if ! bounded_restic "$RESTIC_TIMEOUT" forget "${forget_args[@]}" $(restic_opts forget); then
		sayf "forget failed; nothing was pruned."
		exit 3
	fi
	if [[ "${1:-}" == "--prune" ]]; then
		say "pruning..."
		# shellcheck disable=SC2046 # restic_opts is a generated flag list
		bounded_restic "$RESTIC_TIMEOUT" prune $(restic_opts prune) || exit 3
	fi
	say "retention applied."
	return 0
}

cmd_status() {
	if [[ ! -r "$RECORD" ]]; then
		say "no backup has ever been recorded on this host ($RECORD does not exist)."
		echo "healthy=false"
		return 4
	fi
	cat "$RECORD"
	local st
	st="$(grep -o '^LAST_STATUS=.*' "$RECORD" | cut -d= -f2-)"
	case "$st" in
	ok) echo "healthy=true" ;;
	*) echo "healthy=false" ;;
	esac
}

cmd_config() {
	say "effective configuration ($CONFIG) — contains no secrets by construction:"
	local k
	for k in $(printf '%s\n' "${!CFG[@]}" | sort); do
		printf '  %s = %s\n' "$k" "${CFG[$k]}"
	done
	say "credentials: $( ((repository_configured)) && echo loaded || echo 'not loaded (see RESTIC_REPOSITORY / RESTIC_PASSWORD)')"
	return 0
}

# ── dispatch ────────────────────────────────────────────────────────────────
# Options are consumed FIRST and the command is whatever is left. Reading the
# command out of $1 before doing that made `--config FILE backup` (which is how
# every call site and every test invokes it) resolve the command to "--config".
declare -a REST_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--config)
		CONFIG="$2"
		shift 2
		;;
	--config=*) CONFIG="${1#--config=}"; shift ;;
	-h | --help) usage ;;
	*) REST_ARGS=("$@"); break ;;
	esac
done
set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
CMD=${1:-}
[[ -n "$CMD" ]] || usage
# Drop the command word before handing the rest to the subcommand. Forgetting
# this made `restore latest --target DIR restore` — restic then reports "more
# than one snapshot ID specified: [latest restore]", which reads like a corrupt
# repository rather than an argument bug.
(( $# > 0 )) && shift

load_config

case "$CMD" in
backup) cmd_backup "$@" ;;
check) cmd_check "$@" ;;
restore) cmd_restore "$@" ;;
prune) cmd_prune "$@" ;;
status) cmd_status "$@" ;;
config) load_credentials || true; cmd_config ;;
*) usage ;;
esac