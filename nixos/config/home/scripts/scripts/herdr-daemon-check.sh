#!/usr/bin/env bash
# herdr-daemon-check.sh — is the herdr server actually healthy, and who owns it?
#
# ── Why this exists ──────────────────────────────────────────────────────────
# herdr's client and server are separate processes on a private protocol, and
# three different things can go wrong that all look like "herdr is broken":
#
#   1. THE SERVER IS NOT THE UNIT'S. The whole reason herdr.service exists is
#      that a `nohup herdr server` from some terminal is pinned to that
#      terminal's session and dies with it. But it keeps working right up until
#      it doesn't, and while it does the unit's ExecCondition says "already
#      running, skip" — so from the operator's side the server is *fine* and
#      there is nothing anywhere that says its lifetime is still tied to a pty.
#      That is the exact failure the unit header was written to prevent, going
#      unnoticed.
#   2. THE CLI AND THE SERVER DISAGREE. `nix flake update herdr` moves the
#      client; the running server keeps the old binary until something restarts
#      it. herdr status reports protocol and compatibility flags, but nothing
#      surfaces them at boot. A resumed run that then talks to an older server
#      fails deep inside the protocol.
#   3. THE UNIT FAILED TO START. Restart=on-failure with RestartSec=2 burns the
#      start limit in about 25 seconds and then the unit sits dead — invisible
#      unless someone happens to run `systemctl --user status`.
#
# All three are REPORTED here. None of them is FIXED here, and in particular
# this script never stops, restarts or kills the server: the running server
# holds live agent panes, and resolving an ownership conflict by killing it
# destroys work that no unit file can bring back.
#
# ── Exit codes ───────────────────────────────────────────────────────────────
#   0  healthy — systemd owns it, client and server agree, unit is up
#   1  at least one conflict; the conflicts are named on stdout and stderr
#   2  usage error
set -o nounset -o pipefail

PROGRAM_NAME=${0##*/}

HERDR_BIN=${HERDR_BIN:-herdr}
HERDR_UNIT=${HERDR_UNIT:-herdr.service}
SYSTEMCTL_BIN=${SYSTEMCTL_BIN:-systemctl}
# Overridable so a test can point at a fixture /proc tree instead of the real
# one. Reading the real /proc is safe but not hermetic.
PROC_ROOT=${PROC_ROOT:-/proc}

sayf() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; }

FORMAT=text
usage() {
	cat >&2 <<EOF
usage: $PROGRAM_NAME [--json] [--herdr PATH] [--unit NAME]

  --json        emit the machine-readable form (what the health module reads)
  --herdr PATH  herdr client to query (default: \$HERDR_BIN or 'herdr')
  --unit NAME   systemd user unit that should own the server
                (default: \$HERDR_UNIT or 'herdr.service')

exit: 0 healthy, 1 conflicts reported, 2 usage
EOF
	exit 2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--json) FORMAT=json; shift ;;
	--herdr)
		HERDR_BIN="$2"
		shift 2
		;;
	--herdr=*) HERDR_BIN="${1#--herdr=}"; shift ;;
	--unit)
		HERDR_UNIT="$2"
		shift 2
		;;
	--unit=*) HERDR_UNIT="${1#--unit=}"; shift ;;
	-h | --help) usage ;;
	*) sayf "unknown argument '$1'"; usage ;;
	esac
done

# ── tiny YAML reader for `herdr status` ─────────────────────────────────────
#
# herdr status is `key:` / `  key: value` pairs. A full YAML parser is not a
# reasonable dependency for six scalars, but `awk -F': *'` on the specific keys
# would silently return the WRONG value when a key appears under two sections
# (`version` appears under both client and server, and they can differ — that
# difference is the whole of check 2). So the section is tracked explicitly and
# only `server.version` is ever read.
status_scalar() {
	local section="$1" key="$2"
	awk -v want="$section" -v key="$key" '
    /^[^[:space:]][^:]*:[[:space:]]*$/ {
      cur = $0; sub(/:[[:space:]]*$/, "", cur); inwant = (cur == want); next
    }
    /^[^[:space:]][^:]*:/ {
      cur = $0; sub(/:.*$/, "", cur); inwant = (cur == want); next
    }
    inwant && /^[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (line ~ "^" key ":") { sub("^" key ":[[:space:]]*", "", line); print line; exit }
    }
  '
}

SERVER_STATUS=""
CLIENT_VERSION=""
SERVER_VERSION=""
ENDPOINT_COMPAT=""
ENDPOINT_PROTOCOL=""
PRIVATE_COMPAT=""
PRIVATE_PROTOCOL=""

if [[ -x "$HERDR_BIN" ]] || command -v "$HERDR_BIN" >/dev/null 2>&1; then
	status_out="$("$HERDR_BIN" status 2>&1 || true)"
	SERVER_STATUS="$(status_scalar server status <<<"$status_out")"
	SERVER_VERSION="$(status_scalar server version <<<"$status_out")"
	CLIENT_VERSION="$(status_scalar client version <<<"$status_out")"
	ENDPOINT_COMPAT="$(status_scalar server endpoint_compatible <<<"$status_out")"
	ENDPOINT_PROTOCOL="$(status_scalar server endpoint_protocol_generation <<<"$status_out")"
	PRIVATE_COMPAT="$(status_scalar server private_protocol_compatible <<<"$status_out")"
	PRIVATE_PROTOCOL="$(status_scalar server private_protocol <<<"$status_out")"
else
	sayf "herdr client '$HERDR_BIN' not found — cannot ask the server anything."
fi

# ── who owns the running server ──────────────────────────────────────────────
#
# herdr status does not print a pid, so the pid is found from /proc: any process
# whose comm is the binary's basename and whose argv contains the `server`
# subcommand. That is the same shape `herdr server` actually has, and reading
# /proc needs no tool that might be missing.
server_pids() {
	local d comm argv
	for d in "$PROC_ROOT"/[0-9]*; do
		[[ -r "$d/comm" && -r "$d/cmdline" ]] || continue
		comm="$(cat "$d/comm" 2>/dev/null || true)"
		[[ "$comm" == "herdr" ]] || continue
		# cmdline is NUL separated; turn it into spaces and look for the word.
		argv="$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null || true)"
		case " $argv " in
		*" server "*) printf '%s\n' "${d##*/}" ;;
		esac
	done
}

mapfile -t PIDS < <(server_pids)
UNIT_PID=""
if command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || [[ -x "$SYSTEMCTL_BIN" ]]; then
	UNIT_PID="$("$SYSTEMCTL_BIN" --user show "$HERDR_UNIT" -p MainPID --value 2>/dev/null || true)"
	UNIT_PID="${UNIT_PID//[[:space:]]/}"
	[[ "$UNIT_PID" =~ ^[0-9]+$ ]] || UNIT_PID=""
fi

DAEMON_OWNERSHIP="none"
OWNER_PID=""
if ((${#PIDS[@]} > 0)); then
	if [[ -n "$UNIT_PID" ]]; then
		found_unit=0
		for p in "${PIDS[@]}"; do
			[[ "$p" == "$UNIT_PID" ]] && found_unit=1
		done
		if ((found_unit)); then
			DAEMON_OWNERSHIP="systemd"
			OWNER_PID="$UNIT_PID"
		else
			# A server is running and it is not the unit's MainPID. Either the
			# unit never started and a terminal did, or there are two.
			DAEMON_OWNERSHIP="manual"
			OWNER_PID="${PIDS[0]}"
		fi
	else
		DAEMON_OWNERSHIP="manual"
		OWNER_PID="${PIDS[0]}"
	fi
fi

# ── unit state ──────────────────────────────────────────────────────────────
UNIT_STATE="unknown"
if command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || [[ -x "$SYSTEMCTL_BIN" ]]; then
	is_active="$("$SYSTEMCTL_BIN" --user is-active "$HERDR_UNIT" 2>/dev/null || true)"
	is_active="${is_active//[[:space:]]/}"
	is_failed="$("$SYSTEMCTL_BIN" --user is-failed "$HERDR_UNIT" 2>/dev/null || true)"
	is_failed="${is_failed//[[:space:]]/}"
	if [[ "$is_active" == "active" ]]; then
		UNIT_STATE="ok"
	elif [[ "$is_failed" == "failed" ]]; then
		UNIT_STATE="failed"
	elif [[ -z "$is_active" || "$is_active" == "inactive" || "$is_active" == "unknown" ]]; then
		if ((${#PIDS[@]} == 0)); then
			UNIT_STATE="never-started"
		else
			UNIT_STATE="ok"
		fi
	else
		UNIT_STATE="$is_active"
	fi
fi

# ── client/server compatibility ──────────────────────────────────────────────
#
# A plain version compare. Deliberately NOT "the newer one wins": a newer client
# against an older server is exactly the combination that has to be reported,
# because the fix (restart the server onto the new binary) kills every live pane.
version_cmp() {
	local a="$1" b="$2"
	[[ "$a" == "$b" ]] && {
		printf '0'
		return
	}
	local -a av bv
	IFS=. read -r -a av <<<"${a%%-*}"
	IFS=. read -r -a bv <<<"${b%%-*}"
	local i x y
	for i in 0 1 2; do
		x="${av[$i]:-0}"
		y="${bv[$i]:-0}"
		[[ "$x" =~ ^[0-9]+$ ]] || x=0
		[[ "$y" =~ ^[0-9]+$ ]] || y=0
		if ((10#$x > 10#$y)); then
			printf '1'
			return
		fi
		if ((10#$x < 10#$y)); then
			printf '-1'
			return
		fi
	done
	printf '0'
}

COMPATIBILITY="unknown"
if [[ -z "$SERVER_STATUS" ]]; then
	COMPATIBILITY="unknown"
elif [[ "$SERVER_STATUS" != "running" ]]; then
	COMPATIBILITY="server-${SERVER_STATUS}"
elif [[ "$ENDPOINT_COMPAT" == "yes" && "$PRIVATE_COMPAT" == "yes" ]]; then
	case "$(version_cmp "${CLIENT_VERSION:-0}" "${SERVER_VERSION:-0}")" in
	0) COMPATIBILITY="compatible" ;;
	1) COMPATIBILITY="cli-newer" ;;
	*) COMPATIBILITY="cli-older" ;;
	esac
elif [[ "$ENDPOINT_COMPAT" == "no" || "$PRIVATE_COMPAT" == "no" ]]; then
	COMPATIBILITY="protocol-mismatch"
fi

# ── the running executable ───────────────────────────────────────────────────
#
# Reported, and used by the daemon-root pinning script. `readlink` of
# /proc/PID/exe is the actual binary, which after `nix flake update herdr` is a
# store path the new profile may no longer reference — the closure that has to
# be pinned.
RUNNING_EXE=""
RUNNING_PID=""
if [[ -n "$OWNER_PID" && -L "$PROC_ROOT/$OWNER_PID/exe" ]]; then
	RUNNING_PID="$OWNER_PID"
	RUNNING_EXE="$(readlink -f "$PROC_ROOT/$OWNER_PID/exe" 2>/dev/null || true)"
	[[ "$RUNNING_EXE" == /* ]] || RUNNING_EXE=""
fi

# ── report ──────────────────────────────────────────────────────────────────
# The conflict list and its contents come from agent-lifetime.nix's `conflicts`,
# which is the single definition shared with the Nix-side unit generation and
# with the tests. This script computes the inputs and calls the same shape; see
# docs/agent-operations.md for why the two are kept in step.

CONFLICTS=()
if [[ "$DAEMON_OWNERSHIP" != "systemd" ]]; then
	CONFLICTS+=("daemon-owned-by-${DAEMON_OWNERSHIP}")
fi
if [[ "$COMPATIBILITY" != "compatible" ]]; then
	CONFLICTS+=("client-server-${COMPATIBILITY}")
fi
if [[ "$UNIT_STATE" != "ok" ]]; then
	CONFLICTS+=("unit-${UNIT_STATE}")
fi

# 🔴 QUOTE, not just escape.
#
# `json_escape` used to escape `"` and `\` but never added the surrounding
# quotes, so `"unit":$(json_escape "$HERDR_UNIT")` emitted
# `"unit":herdr.service` and the document was invalid JSON. An EMPTY version
# produced `"clientVersion":,` — a syntax error, not an empty string.
#
# The `exe` field on the line below added its own quotes and was therefore the
# only correct one, which is exactly the inconsistency that made this read as a
# formatting nit rather than a parser error.
#
# `--arg` also means no value is ever passed through a shell that could expand
# it, and the protocol numbers are validated as numeric because they are emitted
# UNQUOTED (they are JSON numbers, not strings).
json_escape() { jq -Rn --arg v "$1" '$v'; }

# json_number VALUE — a JSON number, or null when VALUE is not one. Used for the
# protocol fields, which are emitted bare.
json_number() {
	if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

if [[ "$FORMAT" == "json" ]]; then
	printf '{'
	printf '"unit":%s,' "$(json_escape "$HERDR_UNIT")"
	printf '"daemonOwnership":%s,' "$(json_escape "$DAEMON_OWNERSHIP")"
	printf '"compatibility":%s,' "$(json_escape "$COMPATIBILITY")"
	printf '"unitState":%s,' "$(json_escape "$UNIT_STATE")"
	printf '"pid":%s,' "${RUNNING_PID:-null}"
	printf '"exe":%s,' "$(
		if [[ -n "$RUNNING_EXE" ]]; then
			json_escape "$RUNNING_EXE"
		else
			printf 'null'
		fi
	)"
	printf '"clientVersion":%s,' "$(json_escape "$CLIENT_VERSION")"
	printf '"serverVersion":%s,' "$(json_escape "$SERVER_VERSION")"
	printf '"endpointProtocol":%s,' "$(json_number "$ENDPOINT_PROTOCOL")"
	printf '"privateProtocol":%s,' "$(json_number "$PRIVATE_PROTOCOL")"
	printf '"pidCount":%s,' "${#PIDS[@]}"
	printf '"conflicts":['
	for i in "${!CONFLICTS[@]}"; do
		((i > 0)) && printf ','
		json_escape "${CONFLICTS[$i]}"
	done
	printf '],'
	if ((${#CONFLICTS[@]} == 0)); then
		printf '"healthy":true}\n'
	else
		printf '"healthy":false}\n'
	fi
else
	printf 'herdr daemon check (%s)\n' "$HERDR_UNIT"
	printf '  ownership     %s' "$DAEMON_OWNERSHIP"
	if [[ "$DAEMON_OWNERSHIP" == "manual" ]]; then
		printf '   ← NOT the systemd unit; this server dies with whatever started it'
	fi
	printf '\n'
	printf '  unit state    %s\n' "$UNIT_STATE"
	printf '  client/server %s (client %s, server %s, endpoint proto %s, private proto %s)\n' \
		"$COMPATIBILITY" "${CLIENT_VERSION:-?}" "${SERVER_VERSION:-?}" \
		"${ENDPOINT_PROTOCOL:-?}" "${PRIVATE_PROTOCOL:-?}"
	printf '  running exe   %s\n' "${RUNNING_EXE:-<none>}"
	if ((${#CONFLICTS[@]} == 0)); then
		printf '  verdict       healthy\n'
		exit 0
	fi
	printf '  conflicts:\n'
	for c in "${CONFLICTS[@]}"; do
		printf '    - %s\n' "$c"
	done
	printf '  NOT fixing any of these: the running server holds live agent panes.\n'
	exit 1
fi

((${#CONFLICTS[@]} == 0))