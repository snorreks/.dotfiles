#!/usr/bin/env bash
# nixos/tests/agent-operations/errexit.sh
#
# The writeShellApplication contract.
#
# Every script in this lane that ends up in a systemd unit is built by
# `pkgs.writeShellApplication`, which PREPENDS
#
#     set -o errexit -o nounset -o pipefail
#
# to the file. That is invisible to every other suite here, because they all run
# these files with plain `bash`, which has no errexit. So a script whose logic
# depends on evaluating a command that is expected to fail — and three of them
# do — passes in the test suite and fails in production, at 3am, on the machine
# nobody is watching.
#
# This suite runs the real scripts the way systemd runs them: with errexit on.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="errexit-contract"

fixture_new

# The exact prologue writeShellApplication injects. Kept verbatim rather than
# paraphrased, so a change in nixpkgs shows up here as a diff.
readonly WSAP_PREFIX='set -o errexit -o nounset -o pipefail'

# Run a script the way the NixOS unit does: errexit on, and the unit's own
# SuccessExitStatus applied.
run_like_systemd() {
	local script="$1"
	shift
	bash -c "${WSAP_PREFIX}; source '${script}' \"\$@\"; " -- "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
_t_start "writeShellApplication's prologue is what we think it is"
# Assert the assumption itself rather than trusting it: if nixpkgs changes the
# injected prologue, this fails and says so, instead of the tests below quietly
# testing a different thing from what systemd does.
saw_errexit=no
bash -c "${WSAP_PREFIX}; case \"\$-\" in *e*) echo yes;; *) echo no;; esac" >"$TMP/probe.out"
[[ "$(cat "$TMP/probe.out")" == "yes" ]] && saw_errexit=yes
assert_eq 'yes' "$saw_errexit" 'the prologue under test really does enable errexit'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "every production script disables errexit itself"
# These four are the ones built by writeShellApplication. secret-env.sh is
# included: a `ns-secrets check` that aborted on the first absent credential
# would report nothing at all, which is the one thing it exists to do.
for script in "$BACKUP" "$HEALTH" "$DAEMON_ROOTS" "$SECRET_ENV"; do
	name="$(basename "$script")"
	out="$(grep -n '^set +o errexit' "$script" || true)"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -n "$out" ]]; then
		_ok "$name disables errexit (line ${out%%:*})"
	else
		_fail "$name does not disable errexit — writeShellApplication will enable it"
	fi
done

# ═══════════════════════════════════════════════════════════════════════════
_t_start "ns-agent-backup: a failing restic must not abort before the retry"
# The specific failure: `bounded_restic` fails, `rc=$?` captures it, the loop
# retries, and the record is written. Under errexit the script would die at the
# call and leave the PREVIOUS record in place, so health would keep reading a
# stale `ok`.
mkdir -p "$TMP/state"
printf '%s' "$TMP/repo" >"$TMP/creds/RESTIC_REPOSITORY"
printf 'p\n' >"$TMP/creds/RESTIC_PASSWORD"
printf 'sources=["%s"]\nexcludes=[]\nquiesceFile=%s/q.conf\n' "$TMP" "$TMP/state" >"$TMP/backup.conf"

# A restic that always fails, and records each attempt.
#
# Written with `fake`, which puts a HARD-CODED interpreter path in the shebang.
# A literal `#!/usr/bin/env bash` fails inside a nix build sandbox (no
# /usr/bin/env), the fake cannot exec, restic "runs" and returns 127 without
# ever writing its log, and the retry assertion below fails for a reason that has
# nothing to do with errexit.
fake restic <<'FAKE'
printf 'attempt\n' >>"${TMP}/log/restic-calls"
exit "${FAKE_RESTIC_EXIT:-1}"
FAKE

rm -f "$TMP/log/restic-calls"
out="$(CREDENTIALS_DIRECTORY="$TMP/creds" AGENT_OPS_STATE_DIR="$TMP/state" \
	MAX_ATTEMPTS=2 RETRY_BASE_SECONDS=0 \
	run_like_systemd "$BACKUP" --config "$TMP/backup.conf" backup 2>&1)"
attempts="$(grep -c . "$TMP/log/restic-calls" || true)"
assert_eq '2' "$attempts" 'both attempts ran, so the retry loop was reached'
assert_contains "$(cat "$TMP/state/last-run.env" 2>/dev/null || true)" 'LAST_STATUS=' \
	'and a record was written (the failure did not abort before write_record)'
assert_not_contains "$out" 'backup finished' 'and it is NOT recorded as a success'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "ns-agent-health: a failing collector must not abort the report"
# Same shape: `bounded()` substitutes a fallback precisely so one hung collector
# costs its own field and nothing else.
fake systemctl <<'FAKE'
if [ "${FAKE_SYSTEMCTL_EXIT:-0}" != 0 ]; then exit 1; fi
printf 'active\n'
FAKE
export AGENT_OPS_BACKUP_RECORD="$TMP/state/last-run.env"
export AGENT_OPS_SECRET_ENV="$TMP/bin/no-loader"
export AGENT_OPS_DAEMON_CHECK="$TMP/bin/no-check"
out="$(run_like_systemd "$HEALTH" --json 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$out" | grep -q '"problems"'; then
	_ok 'the JSON document was completed despite a failing collector'
else
	_fail "the JSON document was completed despite a failing collector (exit $rc)"
fi

# ═══════════════════════════════════════════════════════════════════════════
_t_start "ns-agent-daemon-roots: a dangling root must still print its verdict"
mkdir -p "$TMP/gcroots"
ln -sfn "$TMP/does-not-exist" "$TMP/gcroots/ns-ops-dangling"
out="$(NM_GCROOTS="$TMP/gcroots" NS_OPS_TEST_MODE=1 \
	run_like_systemd "$DAEMON_ROOTS" verify 2>&1)"
rc=$?
assert_contains "$out" 'DANGLING' 'the dangling root was reported'
assert_eq '1' "$rc" 'and verify exited 1 rather than aborting silently'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "secret-env: an absent credential must still produce a report"
# `check` is the readiness answer. Under errexit it would die at the first
# missing credential and print nothing, which is the one output it must always
# produce.
printf 'MISSING_KEY||true\n' >"$TMP/m.manifest"
out="$(SECRET_ENV_MANIFEST="$TMP/m.manifest" CREDENTIALS_DIRECTORY="$TMP/none" \
	run_like_systemd "$SECRET_ENV" --check 2>&1)"
rc=$?
assert_contains "$out" 'ABSENT' 'the absent credential was reported'
assert_eq '3' "$rc" 'and the documented exit code was returned'

assert_no_reboot "$TMP/reboots"
summary