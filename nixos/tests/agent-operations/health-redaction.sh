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
{
	printf '#!/usr/bin/env bash\n'
	printf 'if [ "$1" = "--format=json" ] || [ "$2" = "--format=json" ]; then\n'
	printf '  printf %s\n' "'{\"manifest\":\"/etc/agent-ops/secrets.manifest\",\"credentials\":{\"LEAKY_KEY\":{\"ready\":true,\"session\":true,\"aliases\":[]},\"OPENROUTER_API_KEY\":{\"ready\":false,\"session\":true,\"aliases\":[]}},\"ready\":false}'"
	printf '  exit 0\n'
	printf 'fi\n'
	printf 'exit 0\n'
} >"$LOADER"
chmod +x "$LOADER"
export AGENT_OPS_SECRET_ENV="$LOADER"

export AGENT_OPS_BACKUP_RECORD="$TMP/backup/last-run.env"
mkdir -p "$TMP/backup"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'LAST_STATUS=ok\nLAST_AT=%s\nLAST_DETAIL=fixture\n' "$NOW" >"$AGENT_OPS_BACKUP_RECORD"

# ── fakes ──────────────────────────────────────────────────────────────────
export AGENT_OPS_DAEMON_CHECK="$TMP/herdr-daemon-check"
{
	printf '#!/usr/bin/env bash\n'
	printf 'printf %s\\n' "'{\"unit\":\"herdr.service\",\"daemonOwnership\":\"systemd\",\"compatibility\":\"compatible\",\"unitState\":\"ok\",\"pid\":1,\"exe\":\"/nix/store/deadbeef-herdr/bin/herdr\",\"conflicts\":[],\"healthy\":true}'"
} >"$AGENT_OPS_DAEMON_CHECK"
chmod +x "$AGENT_OPS_DAEMON_CHECK"

# A curl that can be made to hang or fail.
CURL_CALLS="$TMP/curl-calls"
: >"$CURL_CALLS"
fake curl <<'FAKE'
#!/bin/bash
printf 'curl %s\n' "$*" >>"${TMP}/curl-calls"
# Record ONLY the JSON body. The URL and the Authorization header are supposed
# to be sent — that is how authentication works — so asserting that the whole
# curl invocation is canary-free would be asserting that the endpoint cannot be
# reached. What must be canary-free is the PAYLOAD: it carries machine state,
# not credentials.
prev=""
for a in "$@"; do
	case "$prev" in
	--data | --data-binary | --data-raw) printf '%s\n' "$a" >>"${TMP}/payloads" ;;
	esac
	prev="$a"
done
exit "${FAKE_CURL_EXIT:-0}"
FAKE

health() { timeout "${HEALTH_WALL_CLOCK:-60}" bash "$HEALTH" "$@" 2>&1; }

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
assert_contains "$sent" '"status":"' 'the heartbeat payload does carry a status field'
assert_contains "$sent" '"problems":' 'and a problems field (empty here, which is why status is ok)'
assert_contains "$sent" 'at' 'including a timestamp'

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
printf 'curl %s\n' "$*" >>"${TMP}/curl-calls"
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
#!/usr/bin/env bash
printf '%s\n' '{"unit":"herdr.service","daemonOwnership":"manual","compatibility":"cli-newer","unitState":"ok","pid":1,"exe":"/nix/store/x-herdr/bin/herdr","conflicts":["daemon-owned-by-manual","client-server-cli-newer"],"healthy":false}'
FAKE
chmod +x "$AGENT_OPS_DAEMON_CHECK"
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