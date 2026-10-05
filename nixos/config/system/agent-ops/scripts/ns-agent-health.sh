#!/usr/bin/env bash
# ns-agent-health.sh — one private, redacted answer to "is this box fine?".
#
# ── Why one script and not a dozen units' statuses ───────────────────────────
# The question is asked from a phone, from a second SSH session, or from a
# heartbeat endpoint, usually while something is already wrong. The answer has
# to arrive in seconds and it must never itself be the outage. So:
#
#   * it is ONE bounded call, not `systemctl status` on forty units;
#   * every external command has a deadline;
#   * every sub-collector is independent, so a hung `df` costs its own field
#     and nothing else;
#   * it NEVER mutates and NEVER reboots. In particular: an ISP outage makes
#     every network-dependent check fail at once, and the tempting response to
#     "everything is down" is to reboot. That is the one action guaranteed to
#     make it worse and to destroy the evidence. There is no reboot path in
#     this file, on purpose.
#
# ── Redaction ───────────────────────────────────────────────────────────────
# The output contains: booleans, counts, ages, sizes, unit names, file names
# and the first line of an error. It contains NO credential values, ever, under
# any code path — credentials are reported as ready/not-ready and their
# NAMES are only emitted from the generated manifest, which is itself names
# only. The test suite asserts this by planting recognisable canary values in
# every credential store and grepping the whole output for them.
#
# ── Deliberately absent ─────────────────────────────────────────────────────
# No recipient is inferred. There is no default heartbeat URL, no service
# signup, and no "helpful" default of posting to a paste site or a chat webhook.
# Outside heartbeat happens only when the operator configures an endpoint AND
# supplies its token as a credential; otherwise the field reads "unconfigured",
# which is a true answer.
#
# ── Exit codes ───────────────────────────────────────────────────────────────
#   0  healthy     1  not healthy     2  usage     4  not configured
set -o nounset -o pipefail

# 🔴 errexit OFF, DELIBERATELY. writeShellApplication injects
# `set -o errexit -o nounset -o pipefail`; under errexit the `bounded()` helper —
# which is designed to swallow a failed subcommand and substitute a fallback —
# would instead abort the whole report on the first hung collector. The tests
# run this file with plain `bash`, which has no errexit, so without this line
# the suites cannot see the difference.
set +o errexit

PROGRAM_NAME=${0##*/}

# Bound per external command. `timeout` is coreutils; without it a single hung
# collector is the whole outage.
CMD_TIMEOUT=${CMD_TIMEOUT:-5}
HEALTH_RETENTION_HOURS=${HEALTH_RETENTION_HOURS:-24}

say() { printf '%s\n' "$*"; }
sayf() { printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2; }

usage() {
	cat >&2 <<EOF
usage: $PROGRAM_NAME [--json] [--no-heartbeat]

  --json            machine-readable output (default is human-readable)
  --no-heartbeat    never contact the configured heartbeat endpoint

exit: 0 healthy, 1 not healthy, 2 usage, 4 not configured
EOF
	exit 2
}

FORMAT=text
DO_HEARTBEAT=1
while [[ $# -gt 0 ]]; do
	case "$1" in
	--json) FORMAT=json; shift ;;
	--no-heartbeat) DO_HEARTBEAT=0; shift ;;
	-h | --help) usage ;;
	*) sayf "unknown argument '$1'"; usage ;;
	esac
done

timeout_bin() { command -v timeout >/dev/null 2>&1 && printf 'timeout %s' "$CMD_TIMEOUT" || printf ''; }
TMO=$(timeout_bin)

USER_SYSTEMCTL=(systemctl --user)
if [[ $EUID == 0 && -n "${AGENT_OPS_HEALTH_USER:-}" ]]; then
	USER_SYSTEMCTL+=(--machine "${AGENT_OPS_HEALTH_USER}@.host")
fi

# Run a command with a deadline, capturing stdout. Failure yields the fallback,
# never an abort of the whole report.
#
# The exit status is published in BOUNDED_STATUS rather than returned: a
# function that both echoes a value and is tested with `&&` cannot report
# failure, and a heartbeat that "succeeded" against a dead endpoint would then
# be recorded as `sent`. That is a green light for a machine nobody is watching.
BOUNDED_STATUS=0
bounded() {
	local fallback="$1"
	shift
	local out
	if out=$($TMO "$@" 2>/dev/null); then
		BOUNDED_STATUS=0
		printf '%s' "$out"
	else
		BOUNDED_STATUS=$?
		printf '%s' "$fallback"
	fi
	return 0
}

# 🔴 BUILD JSON WITH jq, NOT BY HAND.
#
# The previous `JSON_SAFE` only ESCAPED: it turned `"` into `\"` but never
# added the surrounding quotes, so `"unit":$(JSON_SAFE "$u")` emitted
# `"unit":herdr.service` and the whole document was invalid JSON. Several call
# sites added their own quotes and the rest did not, so the output was wrong in
# most fields and right in a few. Control characters were passed through raw.
#
# Nothing detected it because every assertion in health-redaction.sh was a
# substring match. The suite now parses the document with `jq -e`.
#
# `jqs` is the string-escaping primitive: it produces a COMPLETE JSON string
# literal, quotes included, with control characters escaped.
jqs() { jq -Rn --arg v "$1" '$v'; }

# JSON_SAFE is kept as an ALIAS, not a second implementation: two escaping
# rules in one file is how they drift.
JSON_SAFE() { jqs "$1"; }

# ── collectors ──────────────────────────────────────────────────────────────
# Each appends JSON fragments to the arrays below.

PROBLEMS=()
WARNINGS=()

note_problem() { PROBLEMS+=("$1"); }
note_warning() { WARNINGS+=("$1"); }

# ── backup ──────────────────────────────────────────────────────────────────
BACKUP_STATE="unconfigured"
BACKUP_AGE_S=""
BACKUP_DETAIL=""
check_backup() {
	local record="${AGENT_OPS_BACKUP_RECORD:-/var/lib/agent-ops/backup/last-run.env}"
	if [[ ! -r "$record" ]]; then
		# Not "healthy with no data" — not configured is its own answer.
		BACKUP_STATE="unconfigured"
		BACKUP_DETAIL="no backup record at $record"
		note_problem "backup: $BACKUP_DETAIL"
		return
	fi
	local at status
	at="$(grep -o '^LAST_AT=.*' "$record" 2>/dev/null | head -1 | cut -d= -f2- || true)"
	status="$(grep -o '^LAST_STATUS=.*' "$record" 2>/dev/null | head -1 | cut -d= -f2- || true)"
	if [[ -z "$at" ]]; then
		BACKUP_STATE="unreadable"
		BACKUP_DETAIL="record has no timestamp"
		note_problem "backup: $BACKUP_DETAIL"
		return
	fi
	local stamp age
	stamp="$(date -d "$at" +%s 2>/dev/null || echo 0)"
	age=$(( $(date +%s) - stamp ))
	BACKUP_AGE_S="$age"
	case "$status" in
	ok)
		if ((age > ${BACKUP_MAX_AGE_SECONDS:-93600})); then
			BACKUP_STATE="stale"
			BACKUP_DETAIL="last success ${age}s ago"
			note_problem "backup: stale (${age}s)"
		else
			BACKUP_STATE="ok"
		fi
		;;
	partial)
		BACKUP_STATE="partial"
		BACKUP_DETAIL="last run reported unreadable sources"
		note_problem "backup: partial"
		;;
	failed | stale)
		BACKUP_STATE="$status"
		BACKUP_DETAIL="last run status '$status'"
		note_problem "backup: $status"
		;;
	*)
		BACKUP_STATE="unknown"
		BACKUP_DETAIL="unrecognised status '$status'"
		note_problem "backup: $BACKUP_DETAIL"
		;;
	esac
}

# ── credentials ─────────────────────────────────────────────────────────────
CRED_JSON=""
CRED_READY=0
CRED_TOTAL=0
CRED_MISSING=()
check_credentials() {
	local loader="${AGENT_OPS_SECRET_ENV:-$HOME/.config/agent-ops/secret-env}"
	if [[ ! -x "$loader" ]]; then
		CRED_JSON='{"available":false,"reason":"loader not present"}'
		note_problem "credentials: loader $loader is missing"
		return
	fi
	local out rc
	# Exit 3 is the loader's normal not-ready result and still carries JSON.
	out="$($TMO "$loader" --format=json 2>/dev/null)"
	rc=$?
	if [[ $rc != 0 && $rc != 3 ]]; then
		out=""
	fi
	# Reconstruct only the readiness schema, never forward arbitrary values.
	CRED_JSON="$(printf '%s' "$out" | jq -cse '
		select(length == 1) | .[0]
		| select(type == "object" and (.ready | type == "boolean") and (.credentials | type == "object"))
		| {available: true, ready: .ready, credentials: (.credentials | with_entries(
			select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
			| .value = {ready: (.value.ready == true), session: (.value.session == true),
				aliases: [(.value.aliases // [])[] | select(type == "string") | select(test("^[A-Za-z_][A-Za-z0-9_]*$"))]}
		))}' 2>/dev/null)"
	if [[ -z "$CRED_JSON" ]]; then
		CRED_JSON='{"available":false,"ready":false,"reason":"readiness unavailable"}'
		note_problem "credentials: readiness could not be read"
		return
	fi
	out="$CRED_JSON"
	if [[ $rc != 0 ]] || ! jq -e '.ready' <<<"$out" >/dev/null; then
		note_warning "credentials: readiness degraded"
	fi
	# 🔴 TOTAL COUNTS EVERY CREDENTIAL, READY COUNTS ONLY THE READY ONES.
	#
	# Both used to count `"ready":true` occurrences and CRED_READY was a copy of
	# CRED_TOTAL, so the human report printed "N ready" with no denominator: a
	# machine with 1 of 14 credentials decrypted and a machine with 14 of 14
	# produced the SAME line.
	CRED_TOTAL="$(printf '%s' "$out" | jq -r '(.credentials // {}) | length' 2>/dev/null || printf 0)"
	CRED_READY="$(printf '%s' "$out" |
		jq -r '[((.credentials // {})[]) | select(.ready == true)] | length' 2>/dev/null || printf 0)"
	# Names of the not-ready credentials. The loader's JSON has no values in
	# it at all, so this only ever moves NAMES into the report.
	local n
	while IFS= read -r n; do
		[[ -n "$n" ]] && CRED_MISSING+=("$n")
	done < <(printf '%s' "$out" | jq -r '.credentials | to_entries[] | select(.value.ready != true) | .key')
	if ((${#CRED_MISSING[@]} > 0)); then
		note_warning "credentials: ${#CRED_MISSING[@]} not ready (${CRED_MISSING[*]})"
	fi
}

# ── stateful services ───────────────────────────────────────────────────────
SERVICES_JSON=""
check_services() {
	local units=("$@")
	local first=1
	SERVICES_JSON="["
	local u state active rc
	for u in "${units[@]}"; do
		[[ -n "$u" ]] || continue
		state="$($TMO "${USER_SYSTEMCTL[@]}" is-active "$u" 2>/dev/null)"
		rc=$?
		[[ $rc == 0 || "$state" == inactive || "$state" == failed ]] || state=unknown
		[[ -n "$state" ]] || state=unknown
		active="$state"
		if [[ "$state" != active ]]; then
			note_problem "required service $u is $state"
		fi
		((first)) || SERVICES_JSON+=","
		first=0
		SERVICES_JSON+="{\"unit\":$(JSON_SAFE "$u"),\"state\":$(JSON_SAFE "$state"),\"failed\":$([[ "$active" == "failed" ]] && echo true || echo false)}"
	done
	SERVICES_JSON+="]"
}

# ── storage ─────────────────────────────────────────────────────────────────
DISK_JSON=""
check_disk() {
	local mounts=("$@")
	DISK_JSON="["
	local first=1 m line size used avail pct
	for m in "${mounts[@]}"; do
		[[ -d "$m" ]] || continue
		line="$(bounded '' df -P "$m" | tail -n 1)" || line=""
		if [[ -z "$line" ]]; then
			((first)) || DISK_JSON+=","
			first=0
			DISK_JSON+="{\"mount\":$(JSON_SAFE "$m"),\"error\":\"df failed or timed out\"}"
			note_problem "disk $m: df failed or timed out"
			continue
		fi
		size="$(awk '{print $2}' <<<"$line")"
		used="$(awk '{print $3}' <<<"$line")"
		avail="$(awk '{print $4}' <<<"$line")"
		pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
		if [[ ! "$pct" =~ ^[0-9]+$ ]]; then
			note_problem "disk $m: invalid df data"
			pct=0
		fi
		if ((10#${pct:-0} >= 90)); then
			note_problem "disk $m is ${pct}% full"
		fi
		((first)) || DISK_JSON+=","
		first=0
		DISK_JSON+="{\"mount\":$(JSON_SAFE "$m"),\"sizeKiB\":$(JSON_SAFE "$size"),\"usedKiB\":$(JSON_SAFE "$used"),\"availKiB\":$(JSON_SAFE "$avail"),\"usedPct\":$(JSON_SAFE "$pct")}"
	done
	DISK_JSON+="]"

	# inodes, which fill before bytes on a machine that builds a lot
	local line ipct
	for m in "${mounts[@]}"; do
		[[ -d "$m" ]] || continue
		line="$(bounded '' df -Pi "$m" | tail -n 1)"
		if [[ -z "$line" ]]; then
			note_problem "inodes $m: df failed or timed out"
			continue
		fi
		ipct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
		if [[ ! "$ipct" =~ ^[0-9]+$ ]]; then
			note_problem "inodes $m: invalid df data"
			continue
		fi
		if ((10#${ipct:-0} >= 90)); then
			note_problem "inodes on $m are ${ipct}% used"
		fi
	done
}

# ── thermals / power ────────────────────────────────────────────────────────
THERMAL_JSON=""
check_thermal() {
	local max_temp="" ac="unknown" scale="/sys/class/thermal/thermal_zone0/temp"
	if [[ -r "$scale" ]]; then
		max_temp="$(bounded '' cat "$scale")"
		max_temp="$(( ${max_temp:-0} / 1000 ))"
		if ((max_temp > 90)); then
			note_warning "thermal zone 0 at ${max_temp}C"
		fi
	fi
	local ps
	for ps in /sys/class/power_supply/*; do
		[[ -r "$ps/type" ]] || continue
		[[ "$(cat "$ps/type" 2>/dev/null)" == "Mains" ]] || continue
		ac="$(bounded unknown cat "$ps/online" 2>/dev/null || echo unknown)"
		break
	done
	[[ "$ac" == "unknown" && -z "$max_temp" ]] || true
	THERMAL_JSON="{\"cpuC\":$( [[ -n "$max_temp" ]] && printf '%s' "$max_temp" || echo null ),\"onAC\":$( [[ "$ac" == "1" ]] && echo true || echo false ),\"acState\":$(JSON_SAFE "$ac")}"
}

# ── maintenance ─────────────────────────────────────────────────────────────
MAINT_JSON=""
check_maintenance() {
	local dir="${NM_DIR:-/var/lib/nixos/maintenance}"
	local phase="none" txid=""
	if [[ -r "$dir/record.env" ]]; then
		phase="$(grep -o '^phase=.*' "$dir/record.env" 2>/dev/null | head -1 | cut -d= -f2- || echo unknown)"
		txid="$(grep -o '^txid=.*' "$dir/record.env" 2>/dev/null | head -1 | cut -d= -f2- || echo "")"
	fi
	case "$phase" in
	armed | applying | restoring | restore-failed | prepared)
		note_problem "ns-maint is in phase '$phase'${txid:+ (txid $txid)}"
		;;
	esac
	MAINT_JSON="{\"phase\":$(JSON_SAFE "$phase"),\"txid\":$(
		[[ -n "$txid" ]] && printf '%s' "$(JSON_SAFE "$txid")" || echo null
	)}"
}

# ── failed units ────────────────────────────────────────────────────────────
FAILED_JSON=""
check_failed_units() {
	local sys user count_failed
	if ! sys="$($TMO systemctl list-units --state=failed --no-legend --plain 2>/dev/null)"; then
		note_problem "system manager: failed-unit query unavailable"
		sys=""
	fi
	if ! user="$($TMO "${USER_SYSTEMCTL[@]}" list-units --state=failed --no-legend --plain 2>/dev/null)"; then
		note_problem "user manager: failed-unit query unavailable"
		user=""
	fi
	sys="$(awk '{print $1}' <<<"$sys")"
	user="$(awk '{print $1}' <<<"$user")"
	# Unquoted on purpose: these are two newline-separated lists of unit names,
	# and the word split is what flattens them into one list to count.
	# shellcheck disable=SC2086
	count_failed="$(printf '%s\n' $sys $user | grep -c . || true)"
	FAILED_JSON="{\"system\":["
	local first=1 u
	# shellcheck disable=SC2086 # flattened list of unit names
	for u in $sys $user; do
		[[ -n "$u" ]] || continue
		((first)) || FAILED_JSON+=","
		first=0
		FAILED_JSON+="$(JSON_SAFE "$u")"
	done
	FAILED_JSON+="],\"count\":${count_failed:-0}}"
	local count
	count="$count_failed"
	if ((count > 0)); then
		note_problem "$count failed unit(s)"
	fi
}

# ── daemon roots ────────────────────────────────────────────────────────────
DAEMON_JSON=""
check_daemon_roots() {
	local checker="${AGENT_OPS_DAEMON_CHECK-$HOME/.config/agent-ops/herdr-daemon-check}"
	if [[ ! -x "$checker" ]]; then
		DAEMON_JSON='{"available":false}'
		return
	fi
	local out rc
	out="$($TMO "$checker" --json 2>/dev/null)"
	rc=$?
	if [[ $rc != 0 && $rc != 1 ]] || ! jq -e 'type == "object" and (.healthy | type == "boolean")' <<<"$out" >/dev/null 2>&1; then
		DAEMON_JSON='{"available":false,"reason":"check failed or produced invalid output"}'
		note_problem "herdr daemon readiness unavailable"
		return
	fi
	DAEMON_JSON="$out"
	if [[ $rc != 0 ]]; then
		note_problem "herdr daemon check failed"
	fi
	if printf '%s' "$out" | grep -q '"healthy":false'; then
		note_problem "herdr daemon conflicts: $(printf '%s' "$out" | sed -n 's/.*"conflicts":\[\([^]]*\)\].*/\1/p')"
	fi
}

# ── outside heartbeat ───────────────────────────────────────────────────────
HEARTBEAT_STATE="unconfigured"
HEARTBEAT_SENT="no"
send_heartbeat() {
	((DO_HEARTBEAT)) || return 0
	local url_file="${CREDENTIALS_DIRECTORY:-}/AGENT_OPS_HEARTBEAT_URL"
	local tok_file="${CREDENTIALS_DIRECTORY:-}/AGENT_OPS_HEARTBEAT_TOKEN"
	if [[ -z "${CREDENTIALS_DIRECTORY:-}" ]]; then
		HEARTBEAT_STATE="unconfigured"
		return 0
	fi
	if [[ ! -r "$url_file" ]]; then
		# No endpoint configured. That is a legitimate steady state, NOT a
		# problem: nobody signed this machine up to talk to anybody.
		HEARTBEAT_STATE="unconfigured"
		return 0
	fi
	if [[ ! -r "$tok_file" ]]; then
		HEARTBEAT_STATE="token-missing"
		note_warning "heartbeat endpoint is configured but its token is not"
		return 0
	fi
	local url token
	# A sentinel preserves trailing newlines so injection cannot be hidden by
	# command substitution's newline stripping.
	url="$(cat -- "$url_file"; printf '.')"
	url=${url%.}
	token="$(cat -- "$tok_file"; printf '.')"
	token=${token%.}
	if [[ "$url$token" == *$'\n'* || "$url$token" == *$'\r'* ]]; then
		HEARTBEAT_STATE="refused-invalid-credential"
		note_warning "heartbeat credential contains a forbidden newline"
		return 0
	fi
	[[ "$url" == https://* ]] || {
		HEARTBEAT_STATE="refused-insecure-endpoint"
		note_warning "heartbeat endpoint is not https; refusing to send credentials to it"
		return 0
	}
	# 🔴 THE PAYLOAD IS BUILT BY jq.
	#
	# It used to be `printf '{"status":"%s","problems":%s,...}'` fed by
	# `sed 's/.*/"&"/' | paste -sd, -`, which produced invalid JSON whenever a
	# problem string contained a quote or a backslash (`unrecognised status
	# '...'` does), and produced `"problems":""` — a STRING, not an array — when
	# there were none, because `printf '%s\n' ` with no arguments still emits
	# one empty line.
	payload="$(printf '%s\0' ${PROBLEMS[@]+"${PROBLEMS[@]}"} |
		jq -Rs --arg status "$(
			(( ${#PROBLEMS[@]} == 0 )) && printf ok || printf degraded
		)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
			split("\u0000")
			| map(select(length > 0))
			| {status: $status, problems: ., at: $at}
		')"

	# 🔴 THE TOKEN GOES IN A HEADER FILE, NOT IN curl's ARGV.
	#
	# `-H "Authorization: Bearer $(cat …)"` put the token in the process argument
	# list, where any local user can read it from /proc/<pid>/cmdline for as
	# long as curl runs — up to 15s across three attempts. That defeats the
	# confidentiality LoadCredential provides. `curl -H @file` reads the header
	# from a file instead, and curl redacts it from its own /proc/self/cmdline
	# view as well.
	local hdr curl_config escaped_url
	hdr="$(mktemp)" || { note_problem "heartbeat: private file unavailable"; return 0; }
	curl_config="$(mktemp)" || { rm -f "$hdr"; note_problem "heartbeat: private file unavailable"; return 0; }
	chmod 0600 "$hdr" "$curl_config"
	trap 'rm -f "$hdr" "$curl_config"' RETURN
	printf 'Authorization: Bearer %s\n' "$token" >"$hdr"
	escaped_url=${url//\\/\\\\}
	escaped_url=${escaped_url//\"/\\\"}
	escaped_url=${escaped_url//$'\t'/\\t}
	printf 'url = "%s"\n' "$escaped_url" >"$curl_config"

	# Bounded retries with backoff. Bounded, because an outage is exactly when
	# this runs and an unbounded retry loop against a dead endpoint is how a
	# health check becomes the outage.
	#
	# The attempt count comes from the unit, and there is NO sleep after the last
	# attempt: worst case that was 3x10s of curl plus 5+10+15s of sleeping, which
	# is longer than the unit's TimeoutStartSec.
	local max="${AGENT_OPS_HEARTBEAT_MAX_ATTEMPTS:-3}"
	local attempt=0 rc=1
	while ((attempt < max)); do
		attempt=$((attempt + 1))
		bounded '' curl -fsS --retry 0 			-H "@$hdr" 			-H 'Content-Type: application/json' \
			--config "$curl_config" --data "$payload" >/dev/null 2>&1
		rc=$BOUNDED_STATUS
		if ((rc == 0)); then
			HEARTBEAT_STATE="sent"
			HEARTBEAT_SENT="yes"
			return 0
		fi
		((attempt < max)) && sleep $((attempt * 5))
	done
	rm -f "$hdr" "$curl_config"
	trap - RETURN
	HEARTBEAT_STATE="unreachable"
	note_warning "heartbeat endpoint did not answer after ${max} bounded attempts"
	return 0
}

# ── run everything ──────────────────────────────────────────────────────────
check_backup
check_credentials
# Only services selected by the configuration are required (not oneshot checks).
read -r -a REQUIRED_SERVICES <<<"${AGENT_OPS_HEALTH_REQUIRED_SERVICES:-}"
check_services "${REQUIRED_SERVICES[@]}"
check_disk / /home /nix
check_thermal
check_maintenance
check_failed_units
check_daemon_roots

OVERALL="healthy"
if ((${#PROBLEMS[@]} > 0)); then
	OVERALL="unhealthy"
elif ((${#WARNINGS[@]} > 0)); then
	OVERALL="degraded"
fi

send_heartbeat
# Heartbeat failures can add warnings too; report the final verdict.
if ((${#PROBLEMS[@]} > 0)); then
	OVERALL=unhealthy
elif ((${#WARNINGS[@]} > 0)); then
	OVERALL=degraded
fi

problems_json() {
	local first=1 p
	printf '['
	for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do
		((first)) || printf ','
		first=0
		printf '%s' "$(JSON_SAFE "$p")"
	done
	printf ']'
}
warnings_json() {
	local first=1 p
	printf '['
	for p in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
		((first)) || printf ','
		first=0
		printf '%s' "$(JSON_SAFE "$p")"
	done
	printf ']'
}

if [[ "$FORMAT" == "json" ]]; then
	printf '{'
	printf '"overall":%s,' "$(jqs "$OVERALL")"
	printf '"at":%s,' "$(jqs "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
	printf '"hostname":%s,' "$(JSON_SAFE "$(hostname 2>/dev/null || echo unknown)")"
	printf '"backup":{"state":%s,"ageSeconds":%s,"detail":%s},' \
		"$(jqs "$BACKUP_STATE")" \
		"$([[ -n "$BACKUP_AGE_S" ]] && printf '%s' "$BACKUP_AGE_S" || echo null)" \
		"$( [[ -n "$BACKUP_DETAIL" ]] && printf '%s' "$(JSON_SAFE "$BACKUP_DETAIL")" || echo null )"
	printf '"credentials":%s,' "$CRED_JSON"
	printf '"services":%s,' "$SERVICES_JSON"
	printf '"disk":%s,' "$DISK_JSON"
	printf '"thermal":%s,' "$THERMAL_JSON"
	printf '"maintenance":%s,' "$MAINT_JSON"
	printf '"failedUnits":%s,' "$FAILED_JSON"
	printf '"herdrDaemon":%s,' "$DAEMON_JSON"
	printf '"heartbeat":{"state":%s,"sent":%s},' "$(jqs "$HEARTBEAT_STATE")" "$(jqs "$HEARTBEAT_SENT")"
	printf '"problems":%s,' "$(problems_json)"
	printf '"warnings":%s' "$(warnings_json)"
	printf '}\n'
else
	printf 'health: %s  (%s)\n' "$OVERALL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '  backup        %s%s\n' "$BACKUP_STATE" \
		"$( [[ -n "$BACKUP_AGE_S" ]] && printf ' (%ss old)' "$BACKUP_AGE_S" )"
	printf '  credentials   %s of %s ready\n' "$CRED_READY" "$CRED_TOTAL"
	printf '  services      %s\n' "$SERVICES_JSON"
	printf '  disk          %s\n' "$DISK_JSON"
	printf '  thermal       %s\n' "$THERMAL_JSON"
	printf '  maintenance   %s\n' "$MAINT_JSON"
	printf '  failed units  %s\n' "$FAILED_JSON"
	printf '  herdr daemon  %s\n' "$DAEMON_JSON"
	printf '  heartbeat     %s (sent: %s)\n' "$HEARTBEAT_STATE" "$HEARTBEAT_SENT"
	for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do printf '  PROBLEM  %s\n' "$p"; done
	for p in ${WARNINGS[@]+"${WARNINGS[@]}"}; do printf '  warning  %s\n' "$p"; done
fi

case "$OVERALL" in
healthy) exit 0 ;;
degraded) exit 1 ;;
unhealthy) exit 1 ;;
esac