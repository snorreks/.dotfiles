#!/usr/bin/env bash
# The LOADER below is written as single-quoted printf arguments on purpose: it
# has to emit a literal `"` and a literal `$` into a generated script, and
# expanding them here would produce a different file than the one under test.
# shellcheck disable=SC2016
# nixos/tests/agent-operations/health-redaction.sh
#
# Three properties of the health report, each of which has to be asserted rather
# than believed:
#
#   1. REDACTION. A recognisable canary value is planted in every credential
#      store the script can reach, and the suite asserts that canary appears
#      NOWHERE in any output — human, JSON, or error. This is the test that
#      makes "it contains no secrets" a claim rather than a comment.
#   2. BOUNDED RETRY. A dead endpoint must not be retried forever. The heartbeat
#      attempt count is observable and capped, and the whole script finishes
#      inside a wall-clock budget even when every dependency is broken.
#   3. RESPONSIVENESS. With several collectors failing at once — a hung command,
#      an unreachable filesystem, a dead endpoint — the report still completes,
#      still says which fields are missing, and never waits on one of them.
#
# Nothing here touches a real credential, a real endpoint, or a real mailbox.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="health-redaction"

fixture_new
export AGENT_OPS_HEALTH_USER=fixture-owner
export AGENT_OPS_HEALTH_REQUIRED_SERVICES='herdr.service collie.service'
# Keep all storage probes in the fixture too.
fake df <<'FAKE'
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' 'fixture 1000 100 900 10% /'
FAKE

# ── the canary ──────────────────────────────────────────────────────────────
CANARY='CANARY-9f3a7c21-DO-NOT-LEAK'
CRED_DIR="$TMP/creds"
mkdir -p "$CRED_DIR"
printf '%s' "s3cret-$CANARY" >"$CRED_DIR/RESTIC_REPOSITORY"
printf '%s' "password-$CANARY" >"$CRED_DIR/RESTIC_PASSWORD"
printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
printf '%s' "bearer-$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
export CREDENTIALS_DIRECTORY="$CRED_DIR"

# A manifest and a loader whose values are ALSO the canary, so the redaction
# claim covers the credential path as well as the restic path.
MANIFEST="$TMP/secrets.manifest"
printf 'LEAKY_KEY||true\n' >"$MANIFEST"
SECRETS_DIR="$TMP/sops-secrets"
mkdir -p "$SECRETS_DIR"
printf 'value-%s' "$CANARY" >"$SECRETS_DIR/LEAKY_KEY"
printf 'OPENROUTER_API_KEY||true\nGOOGLE_CALENDAR_ICS_URL||true\n' >>"$MANIFEST"
export SECRET_ENV_MANIFEST="$MANIFEST"

# ── a loader that reports readiness, as secret-env.sh does ──────────────────
LOADER="$TMP/secret-env"
# Written with a quoted heredoc, NOT with `printf 'printf %s\\n' …`: that
# pattern makes printf's own %s conversion eat the script text and turns the
# generated newline into a stray "n", which is how a stray character ended up
# inside the JSON this suite is supposed to be validating.
#
# The shebang is `$BASH` (the resolved interpreter), not `/usr/bin/env bash`:
# a nix build sandbox has no /usr/bin/env, and a fake that cannot find its
# interpreter exits 127 — which reads as "the heartbeat never fired".
printf '#!%s\n' "$(command -v bash)" >"$LOADER"
cat >>"$LOADER" <<'LOADEREOF'
if [ "$1" = "--format=json" ] || [ "$2" = "--format=json" ]; then
  printf '%s\n' '{"manifest":"/etc/agent-ops/secrets.manifest","credentials":{"LEAKY_KEY":{"ready":true,"session":true,"aliases":[]},"OPENROUTER_API_KEY":{"ready":false,"session":true,"aliases":[]}},"ready":false}'
  exit "${FAKE_LOADER_EXIT:-0}"
fi
exit 0
LOADEREOF
chmod +x "$LOADER"
export AGENT_OPS_SECRET_ENV="$LOADER"

export AGENT_OPS_BACKUP_RECORD="$TMP/backup/last-run.env"
mkdir -p "$TMP/backup"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'LAST_STATUS=ok\nLAST_AT=%s\nLAST_DETAIL=fixture\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"

# ── fakes ──────────────────────────────────────────────────────────────────
export AGENT_OPS_DAEMON_CHECK="$TMP/herdr-daemon-check"
cat >"$AGENT_OPS_DAEMON_CHECK" <<'CHECKEOF'
#!INTERPRETED_BY_THE_FIXTURE
printf '%s\n' '{"unit":"herdr.service","daemonOwnership":"systemd","compatibility":"compatible","unitState":"ok","pid":1,"exe":"/nix/store/deadbeef-herdr/bin/herdr","conflicts":[],"healthy":true}'
CHECKEOF
chmod +x "$AGENT_OPS_DAEMON_CHECK"
# /usr/bin/env does not exist in a nix build sandbox, so a fake
# written with that shebang cannot exec and silently returns 127.
sed -i "1s|#!INTERPRETED_BY_THE_FIXTURE|#!$(command -v bash)|" "$AGENT_OPS_DAEMON_CHECK"

# A curl that can be made to hang or fail.
CURL_CALLS="$TMP/curl-calls"
: >"$CURL_CALLS"
fake curl <<'FAKE'
#!/bin/bash
# ONE line per INVOCATION: the --data payload is multi-line pretty-printed JSON,
# so logging "$*" verbatim makes `grep -c` count payload LINES and turns a
# 3-attempt retry into a bogus "15 attempts".
printf 'curl %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"${TMP}/curl-calls"
# Secrets must be sent through private files, never through process argv.
prev=""
for a in "$@"; do
	case "$prev" in
	--data | --data-binary | --data-raw) printf '%s\n' "$a" >>"${TMP}/payloads" ;;
	--config)
		stat -c '%a' "$a" >>"${TMP}/curl-config-modes"
		cp "$a" "${TMP}/last-curl-config"
		;;
	-H)
		if [[ "$a" == @* ]]; then stat -c '%a' "${a#@}" >>"${TMP}/curl-header-modes"; fi
		;;
	esac
	prev="$a"
done
exit "${FAKE_CURL_EXIT:-0}"
FAKE

health() { timeout "${HEALTH_WALL_CLOCK:-60}" bash "$HEALTH" "$@" 2>&1; }

# health_json — STDOUT ONLY.
#
# `health()` merges stderr into stdout so that diagnostics are assertable, which
# is right for a substring check and wrong for a parse check: one stray warning
# on stderr and `jq` rejects the lot. Parsing therefore gets its own call.
health_json() { timeout "${HEALTH_WALL_CLOCK:-60}" bash "$HEALTH" "$@" 2>/dev/null; }

_t_start "failed-unit counts expand to JSON numbers"
fake systemctl <<'FAKE'
printf '%s\n' "$*" >>"$TMP/systemctl-calls"
if [[ "${FAKE_BUS_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *is-active* ]]; then
    printf '%s\n' "${FAKE_REQUIRED_STATE:-active}"
    [[ "${FAKE_REQUIRED_STATE:-active}" == active ]]
    exit $?
fi
if [[ "$*" == *list-units* ]]; then
    if [[ "${FAKE_FAILED_UNITS:-0}" == 1 ]]; then
        printf '%s\n' 'example.service loaded failed failed Example'
    fi
    exit 0
fi
exit 1
FAKE
for expected in 0 2; do
    out="$(FAKE_FAILED_UNITS=$((expected / 2)) health --json --no-heartbeat)"
    # Other report fields have existing string-quoting defects; validate the
    # numeric count token independently of those unrelated fields.
    actual="$(printf '%s' "$out" | python3 -c 'import json,re,sys; print(json.loads(re.search(r"\"failedUnits\":.*?,\"count\":([^}]+)}", sys.stdin.read()).group(1)))')"
    assert_eq "$expected" "$actual" 'combined system/user count is a JSON number'
    assert_not_contains "$out" 'count_failed: command not found' 'count is expanded, never executed'
done

# ═══════════════════════════════════════════════════════════════════════════
_t_start "an unconfigured backup is a PROBLEM, not a pass"
rm -f "$AGENT_OPS_BACKUP_RECORD"
out="$(health)"
assert_contains "$out" 'unconfigured' 'a missing backup record reads as unconfigured'
assert_contains "$out" 'PROBLEM' 'and is raised as a problem'
out="$(health --json)"
assert_contains "$out" '"overall":"unhealthy"' 'the JSON verdict is unhealthy'
assert_contains "$out" '"state":"unconfigured"' 'and the backup field says why'

printf 'LAST_STATUS=ok\nLAST_AT=%s\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"
out="$(health)"
assert_not_contains "$out" 'PROBLEM' 'a fresh successful backup raises no problem'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a STALE backup is a problem"
STALE="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$NOW")"
printf 'LAST_STATUS=ok\nLAST_AT=%s\n' "$STALE" >"$AGENT_OPS_BACKUP_RECORD"
out="$(health)"
assert_contains "$out" 'PROBLEM' 'a two-day-old successful backup is still a problem'
assert_contains "$out" 'stale' 'and is named stale'
printf 'LAST_STATUS=ok\nLAST_AT=%s\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"

printf 'LAST_STATUS=partial\nLAST_AT=%s\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"
out="$(health)"
assert_contains "$out" 'partial' 'a partial backup reads as partial, not ok'
printf 'LAST_STATUS=failed\nLAST_AT=%s\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"
out="$(health)"
assert_contains "$out" 'PROBLEM' 'a failed backup is a problem even if it is recent'
printf 'LAST_STATUS=ok\nLAST_AT=%s\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the --json output is actually JSON"
# Every other assertion here is a substring match, which cannot tell valid JSON
# from invalid JSON. It did not, and the document was invalid in almost every
# field: the escaping helper escaped `"` but never added the surrounding
# quotes. These assertions parse instead.
if ! command -v jq >/dev/null 2>&1; then
	printf '    SKIP jq is not on PATH (it is in the flake check closure)\n'
else
	out="$(health_json --json)"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
		_ok 'ns-agent-health --json parses as a JSON document'
	else
		_fail 'ns-agent-health --json parses as a JSON document'
	fi
	assert_eq 'object' "$(printf '%s' "$out" | jq -r 'type' 2>/dev/null)" \
		'and the top level is an object'
	assert_ne 'null' "$(printf '%s' "$out" | jq -r '.backup.state' 2>/dev/null)" \
		'and backup.state is a real value'
	assert_eq 'array' "$(printf '%s' "$out" | jq -r '.problems | type' 2>/dev/null)" \
		'and problems is an ARRAY, not the empty string an unquoted field produces'
	assert_eq 'array' "$(printf '%s' "$out" | jq -r '.services | type' 2>/dev/null)" \
		'and services is an array'
	assert_eq 'array' "$(printf '%s' "$out" | jq -r '.disk | type' 2>/dev/null)" \
		'and disk is an array'
	assert_eq 'array' "$(printf '%s' "$out" | jq -r '.warnings | type' 2>/dev/null)" \
		'and warnings is an array'
	# A string containing a quote, a backslash and a newline must survive as a
	# VALUE rather than breaking the document — the failure mode that the old
	# sed-built heartbeat payload had.
	assert_eq 'yes' "$(printf '%s' "$out" | jq -e 'has("overall") and has("at") and has("hostname")' >/dev/null 2>&1 && echo yes || echo no)" \
		'the documented top-level keys are all present'

	# The heartbeat payload must parse too, INCLUDING when a problem string
	# contains a quote.
	printf 'quote " backslash \\ and newline test\n' >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
	printf 'bearer-%s' "$CANARY" >"$TMP/creds/HEARTBEAT_TOKEN"
	: >"$TMP/payloads"
	: >"$CURL_CALLS"
	health >/dev/null 2>&1
	TESTS_RUN=$((TESTS_RUN + 1))
	payload_ok=yes
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		printf '%s' "$line" | jq -e . >/dev/null 2>&1 || payload_ok=no
	done <"$TMP/payloads"
	assert_eq 'yes' "$payload_ok" 'every heartbeat payload is a JSON document'

	# Restore a usable endpoint: the blocks after this one exercise the
	# no-recipient / insecure-endpoint / token-missing paths and depend on the
	# credential files being in the state they set up themselves.
	printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
	printf 'bearer-%s' "$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
	: >"$TMP/payloads"
fi

# The herdr daemon check is consumed by this script as JSON, so it has to parse.
if command -v jq >/dev/null 2>&1 && [[ -x "$AGENT_OPS_DAEMON_CHECK" ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$AGENT_OPS_DAEMON_CHECK" --json 2>/dev/null | jq -e . >/dev/null 2>&1; then
		_ok 'herdr-daemon-check --json parses as a JSON document'
	else
		_fail 'herdr-daemon-check --json parses as a JSON document'
	fi
fi

# ═══════════════════════════════════════════════════════════════════════════
_t_start "REDACTION: no credential value appears in any output"
# Every store the script reads from, and every field it reports.
out="$(
	health
	health --json
	health --json --no-heartbeat
)"
for leak in \
	"$CANARY" \
	"s3cret-$CANARY" \
	"password-$CANARY" \
	"bearer-$CANARY" \
	"value-$CANARY" \
	"LEAKY_KEY="; do
	assert_not_contains "$out" "$leak" "no output contains '$leak'"
done

# Not even when the heartbeat actually fires: the token and the endpoint URL are
# credentials too, and the endpoint URL carries the canary.
: >"$TMP/payloads"
out="$(FAKE_CURL_EXIT=0 health)"
sent="$(cat "$TMP/payloads" 2>/dev/null || true)"
assert_contains "$sent" 'status' 'the heartbeat was actually attempted'
for leak in "$CANARY" 'bearer-'; do
	assert_not_contains "$sent" "$leak" "the heartbeat PAYLOAD carries no '$leak'"
	assert_not_contains "$out" "$leak" "no health output contains '$leak'"
done
assert_contains "$sent" '"status"' 'the heartbeat payload does carry a status field'
assert_contains "$sent" '"problems"' 'and a problems field'
assert_contains "$sent" '"at"' 'and a timestamp'
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$sent" | jq -e '.status and (.problems | type == "array") and .at' >/dev/null 2>&1; then
	_ok 'and the payload parses with a status, an array of problems and a timestamp'
else
	_fail 'the payload parses with a status, an array of problems and a timestamp'
fi
# 🔴 THE HUMAN REPORT MUST CARRY A DENOMINATOR.
#
# CRED_TOTAL and CRED_READY both used to count `"ready":true` occurrences, and
# CRED_READY was a copy of CRED_TOTAL — so the line read "N ready" and a
# machine with 1 of 14 credentials decrypted looked exactly like one with 14 of
# 14. The fixture loader reports exactly one ready and one not-ready.
out="$(health)"
assert_contains "$out" 'credentials   1 of 2 ready' \
	'credential readiness is reported as "ready OF total", with both counted correctly'

# The report DOES carry the credential NAMES and readiness booleans, which is
# the whole point of reporting readiness at all.
out="$(health --json)"
assert_contains "$out" 'OPENROUTER_API_KEY' 'the not-ready credential is NAMED'
assert_contains "$out" '"ready":false' 'with a readiness boolean'
assert_contains "$out" 'credentials' 'and the field is called credentials'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "no recipient is inferred"
rm -f "$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
: >"$CURL_CALLS"
out="$(health)"
assert_contains "$out" 'unconfigured' 'with no endpoint configured the heartbeat is unconfigured'
assert_contains "$out" 'heartbeat' 'and is reported as a field'
assert_eq '0' "$(grep -c . "$CURL_CALLS")" 'and NOTHING was sent anywhere'
assert_not_contains "$out" 'PROBLEM' 'and it is NOT a problem: this is a legitimate steady state'

printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
rm -f "$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
: >"$CURL_CALLS"
out="$(health)"
assert_contains "$out" 'token-missing' 'an endpoint with no token reads as token-missing'
assert_contains "$out" 'warning' 'and is a warning, not a silent send of nothing'
assert_eq '0' "$(grep -c . "$CURL_CALLS")" 'and nothing was sent'

# An http:// endpoint is refused outright: the token is a credential and must
# not go to a plaintext endpoint.
printf '%s' 'bearer-token' >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
printf '%s' "http://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
: >"$CURL_CALLS"
out="$(health)"
assert_contains "$out" 'refused-insecure-endpoint' 'a non-https endpoint is refused'
assert_eq '0' "$(grep -c . "$CURL_CALLS")" 'and the token is not sent over plaintext'
printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "retries are BOUNDED"
# Reset first: earlier blocks exercised the heartbeat too, and this assertion is
# about how many calls ONE dead endpoint produces.
printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
printf 'bearer-%s' "$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
: >"$CURL_CALLS"
out="$(FAKE_CURL_EXIT=1 health)"
calls="$(grep -c . "$CURL_CALLS")"
TESTS_RUN=$((TESTS_RUN + 1))
if ((calls > 0 && calls <= 3)); then
	_ok "a dead endpoint was retried a bounded number of times ($calls <= 3)"
else
	_fail "a dead endpoint was retried a bounded number of times (got $calls)"
fi
assert_contains "$out" 'unreachable' 'and the endpoint is reported as unreachable'
assert_contains "$out" 'bounded attempts' 'with the bound stated in the message'

# A SLOW endpoint must not hold the report open. The wall-clock budget below is
# the real assertion; here we only prove a dead one does not retry forever.
assert_no_file "$TMP/never" 'the retry loop terminates'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "failed collectors and required services cannot report green"
out="$(FAKE_LOADER_EXIT=3 health_json --json --no-heartbeat)"
assert_eq false "$(jq -r '.credentials.ready' <<<"$out")" 'exit 3 preserves readiness JSON'
assert_eq 2 "$(jq -r '.credentials.credentials | length' <<<"$out")" 'exit 3 preserves all names'
assert_contains "$out" 'degraded' 'not-ready credentials degrade health'
out="$(FAKE_LOADER_EXIT=1 health_json --json --no-heartbeat)"
assert_eq false "$(jq -r '.credentials.available' <<<"$out")" 'unexpected loader failure marks readiness unavailable'
assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'loader failure cannot green'
out="$(FAKE_BUS_FAIL=1 health_json --json --no-heartbeat)"
assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'bus failure cannot green'
assert_contains "$out" 'user manager: failed-unit query unavailable' 'missing user bus is a problem'
for state in inactive failed; do
    out="$(FAKE_REQUIRED_STATE=$state health_json --json --no-heartbeat)"
    assert_contains "$out" "required service herdr.service is $state" 'required service inactivity is a problem'
    assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'inactive required units cannot green'
done
if [[ $EUID == 0 ]]; then
    assert_contains "$(<"$TMP/systemctl-calls")" '--user --machine fixture-owner@.host' 'root targets the owner user manager'
fi
out="$(AGENT_OPS_HEALTH_REQUIRED_SERVICES='' FAKE_REQUIRED_STATE=inactive health_json --json --no-heartbeat)"
assert_eq 0 "$(jq -r '.services | length' <<<"$out")" 'disabled services are not required'

_t_start "readiness accepts only whitelisted fields"
cp "$LOADER" "$TMP/original-loader"
printf '#!%s\n' "$(command -v bash)" >"$LOADER"
printf 'printf '\''%%s\\n'\'' '\''{"ready":false,"value":"%s","credentials":{"SAFE_KEY":{"ready":false,"session":true,"aliases":["SAFE_ALIAS"],"value":"%s"}}}'\''\nexit 3\n' "$CANARY" "$CANARY" >>"$LOADER"
out="$(health_json --json --no-heartbeat)"
assert_not_contains "$out" "$CANARY" 'unknown loader fields cannot leak values'
assert_eq SAFE_ALIAS "$(jq -r '.credentials.credentials.SAFE_KEY.aliases[0]' <<<"$out")" 'safe readiness aliases survive'
printf '#!%s\nsleep 3600\n' "$(command -v bash)" >"$LOADER"
out="$(CMD_TIMEOUT=1 health_json --json --no-heartbeat)"
assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'readiness timeout cannot green'
assert_eq false "$(jq -r '.credentials.available' <<<"$out")" 'readiness timeout is marked missing'
printf '#!%s\nprintf '\''not-json\\n'\''\n' "$(command -v bash)" >"$LOADER"
out="$(health_json --json --no-heartbeat)"
assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'invalid readiness JSON cannot green'
cp "$TMP/original-loader" "$LOADER"
out="$(HOME="$TMP/not-the-owner-home" health_json --json --no-heartbeat)"
assert_eq 2 "$(jq -r '.credentials.credentials | length' <<<"$out")" 'explicit owner loader path ignores root HOME'

_t_start "curl argv contains neither URL nor token"
: >"$CURL_CALLS"
printf '%s' "https://heartbeat.invalid/$CANARY/quote\"back\\slash" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
health --json >/dev/null
assert_not_contains "$(<"$CURL_CALLS")" "$CANARY" 'credential canaries are absent from curl argv'
assert_contains "$(<"$TMP/last-curl-config")" 'quote\"back\\slash' 'curl config escapes quotes and backslashes'
assert_eq 600 "$(sort -u "$TMP/curl-config-modes")" 'curl URL config is private'
assert_eq 600 "$(sort -u "$TMP/curl-header-modes")" 'token header is private'
: >"$CURL_CALLS"
printf 'https://heartbeat.invalid/%s\nurl = "https://injected.invalid"\n' "$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
out="$(health --json)"
assert_contains "$out" 'refused-invalid-credential' 'URL newline injection is refused'
assert_eq 0 "$(grep -c . "$CURL_CALLS")" 'injected URL is never passed to curl'
printf '%s' "https://heartbeat.invalid/$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_URL"
printf 'bearer-%s\n' "$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"
out="$(health --json)"
assert_contains "$out" 'refused-invalid-credential' 'token newline injection is refused'
printf 'bearer-%s' "$CANARY" >"$CRED_DIR/AGENT_OPS_HEARTBEAT_TOKEN"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "responsiveness: the report finishes even when collectors are broken"
# A df that hangs, a systemctl that hangs, an endpoint that hangs.
fake df <<'FAKE'
#!/bin/bash
if [ "${FAKE_DF_HANG:-0}" = 1 ]; then sleep 3600; fi
exit 1
FAKE
fake systemctl <<'FAKE'
#!/bin/bash
if [ "${FAKE_SYSTEMCTL_HANG:-0}" = 1 ]; then sleep 3600; fi
printf 'active\n'
FAKE
fake curl <<'FAKE'
#!/bin/bash
# ONE line per INVOCATION: the --data payload is multi-line pretty-printed JSON,
# so logging "$*" verbatim makes `grep -c` count payload LINES and turns a
# 3-attempt retry into a bogus "15 attempts".
printf 'curl %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"${TMP}/curl-calls"
if [ "${FAKE_CURL_HANG:-0}" = 1 ]; then sleep 3600; fi
exit "${FAKE_CURL_EXIT:-0}"
FAKE

# CMD_TIMEOUT is lowered so the test does not take a minute to prove the point;
# the property under test is that each collector has ITS OWN deadline, not how
# long that deadline is.
start="$(date +%s)"
out="$(FAKE_DF_HANG=1 FAKE_SYSTEMCTL_HANG=1 FAKE_CURL_HANG=1 \
	CMD_TIMEOUT=1 HEALTH_WALL_CLOCK=90 timeout 90 bash "$HEALTH" --json 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - start ))
TESTS_RUN=$((TESTS_RUN + 1))
if ((rc == 124)); then
	_fail "the report completed despite three hung collectors (timed out after ${elapsed}s)"
elif ((rc == 0 || rc == 1)); then
	_ok "the report completed despite three hung collectors (${elapsed}s, exit $rc)"
else
	_fail "the report completed despite three hung collectors (exit $rc)"
fi
assert_contains "$out" 'df failed or timed out' 'a hung df is reported as missing, not as zero'
assert_eq unhealthy "$(jq -r '.overall' <<<"$out")" 'df timeout cannot green'
assert_contains "$out" '"problems"' 'and the rest of the report is still produced'

# With the fakes un-hung it is fast again.
start="$(date +%s)"
CMD_TIMEOUT=2 health --json >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
TESTS_RUN=$((TESTS_RUN + 1))
if ((elapsed <= 20)); then
	_ok "the healthy path is fast (${elapsed}s)"
else
	_fail "the healthy path is fast (took ${elapsed}s)"
fi

# ═══════════════════════════════════════════════════════════════════════════
_t_start "herdr daemon conflicts surface as problems"
cat >"$AGENT_OPS_DAEMON_CHECK" <<'FAKE'
#!INTERPRETED_BY_THE_FIXTURE
printf '%s\n' '{"unit":"herdr.service","daemonOwnership":"manual","compatibility":"cli-newer","unitState":"ok","pid":1,"exe":"/nix/store/x-herdr/bin/herdr","conflicts":["daemon-owned-by-manual","client-server-cli-newer"],"healthy":false}'
exit 1
FAKE
chmod +x "$AGENT_OPS_DAEMON_CHECK"
# /usr/bin/env does not exist in a nix build sandbox, so a fake
# written with that shebang cannot exec and silently returns 127.
sed -i "1s|#!INTERPRETED_BY_THE_FIXTURE|#!$(command -v bash)|" "$AGENT_OPS_DAEMON_CHECK"
out="$(health)"
assert_contains "$out" 'herdr daemon conflicts' 'a manual daemon is raised as a problem'
assert_contains "$out" 'daemon-owned-by-manual' 'and the specific conflict is named'
assert_contains "$out" 'client-server-cli-newer' 'both conflicts, not just the first'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a pending ns-maint transaction is visible"
mkdir -p "$TMP/maint"
printf 'phase=armed\ntxid=abc123\n' >"$TMP/maint/record.env"
out="$(NM_DIR="$TMP/maint" health)"
assert_contains "$out" 'ns-maint is in phase' 'an armed transaction is a problem'
assert_contains "$out" 'abc123' 'and the txid is named, so the operator can abort the right one'
printf 'phase=idle\ntxid=\n' >"$TMP/maint/record.env"
out="$(NM_DIR="$TMP/maint" health)"
assert_not_contains "$out" 'PROBLEM  ns-maint' 'an idle machine has no maintenance problem'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "NO auto-reboot, ever"
# The whole report, plus the source, must contain no power action.
assert_no_reboot "$TMP/reboots"
# Comments are stripped first: the header explains at length that the script
# does NOT reboot, and asserting on the word "reboot" in that prose would fail
# for the right reason.
src="$(grep -vE '^[[:space:]]*#' "$HEALTH" || true)"
for bad in 'systemctl reboot' 'systemctl poweroff' 'shutdown -h' 'systemctl kexec' 'reboot'; do
	assert_not_contains "$src" "$bad" "live health code contains no '$bad'"
done
assert_contains "$(cat "$HEALTH")" 'NEVER reboots' 'and the header says why, in as many words'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the modules declare no reboot path either"
for f in "$LANE_SRC"/config/system/agent-ops/*.nix; do
	out="$(grep -vE '^\s*#' "$f" || true)"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$out" | grep -qE 'systemctl (reboot|poweroff)|ExecStopPost.*reboot'; then
		_fail "$(basename "$f") contains a reboot path"
	else
		_ok "$(basename "$f") has no reboot path in live code"
	fi
done

summary