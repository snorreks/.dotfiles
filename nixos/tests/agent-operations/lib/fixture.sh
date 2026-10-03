# shellcheck shell=bash
# shellcheck disable=SC2016
# nixos/tests/agent-operations/lib/fixture.sh
#
# A small, self-contained harness for the agent-operations lane.
#
# ── Why this is not nixos/tests/lib/harness.sh ───────────────────────────────
# That harness is built around ns-maint: its fixture creates a maintenance state
# directory, a fake nix-store and a fake systemd-run, and its assertions include
# ns-maint-specific ones (gc_root, rec_field, switch_calls). Reusing it here
# would mean every test in this lane carried the transaction machinery it does
# not use, and the lane would stop being runnable on its own the moment that
# file changed under lane A.
#
# So this is a SEPARATE, smaller harness with the same conventions (assertions
# that count, `ok`/`FAIL` lines, fake binaries with hardcoded interpreter paths,
# disposable roots under $TMP, and every FAKE_* knob reset by the fixture). Lane
# D's repo-contracts work is what consolidates shared discovery later; this lane
# does not wait for it.
#
# Nothing here touches the real home directory, the real Nix store, the real
# systemd, or any running service, and nothing here reboots anything.
set -o nounset -o pipefail

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""
FAILURES=()

_t_start() {
	CURRENT_TEST="$1"
	printf '  \033[1m%s\033[0m\n' "$1"
}

_ok() { printf '    \033[32mok\033[0m   %s\n' "$1"; }
_fail() {
	printf '    \033[31mFAIL\033[0m %s\n' "$1"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	FAILURES+=("$CURRENT_TEST: $1")
}

assert_eq() {
	local expected="$1" actual="$2" msg="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		_ok "$msg"
	else
		_fail "$msg (expected '$expected', got '$actual')"
	fi
}

assert_ne() {
	local unexpected="$1" actual="$2" msg="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$unexpected" != "$actual" ]]; then
		_ok "$msg"
	else
		_fail "$msg (did not expect '$actual')"
	fi
}

assert_contains() {
	local haystack="$1" needle="$2" msg="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		_ok "$msg"
	else
		_fail "$msg (missing '$needle')"
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" msg="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		_ok "$msg"
	else
		_fail "$msg (unexpectedly contains '$needle')"
	fi
}

assert_file() {
	local path="$1" msg="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -e "$path" ]]; then
		_ok "$msg"
	else
		_fail "$msg (no such file: $path)"
	fi
}

assert_no_file() {
	local path="$1" msg="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ ! -e "$path" ]]; then
		_ok "$msg"
	else
		_fail "$msg (file exists but should not: $path)"
	fi
}

assert_symlink_target() {
	local link="$1" expected="$2" msg="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	local actual=""
	[[ -L "$link" ]] && actual="$(readlink "$link")"
	if [[ "$actual" == "$expected" ]]; then
		_ok "$msg"
	else
		_fail "$msg (expected link -> '$expected', got '$actual')"
	fi
}

# assert_no_reboot — the invariant every path in this lane must preserve.
# A test that never asserts this is a test that could pass while the machine
# rebooted.
assert_no_reboot() {
	local marker="${1:-$TMP/reboots}"
	TESTS_RUN=$((TESTS_RUN + 1))
	local n=0
	[[ -f "$marker" ]] && n="$(grep -c . "$marker")"
	if [[ "$n" == "0" ]]; then
		_ok "no reboot was issued on this path"
	else
		_fail "no reboot was issued on this path (marker has $n lines)"
	fi
}

summary() {
	printf '\n'
	if ((TESTS_FAILED == 0)); then
		printf '\033[32m%s: %d assertions, all passed\033[0m\n' "${SUITE_NAME:-suite}" "$TESTS_RUN"
		return 0
	fi
	printf '\033[31m%s: %d assertions, %d FAILED\033[0m\n' "${SUITE_NAME:-suite}" "$TESTS_RUN" "$TESTS_FAILED"
	printf '  - %s\n' "${FAILURES[@]}"
	return 1
}

# ── fixtures ────────────────────────────────────────────────────────────────
#
# A disposable root. $TMP is under the build sandbox's own $TMPDIR (or the
# caller's, for a standalone run) and is removed on exit, so a test cannot
# accidentally depend on state from a previous one.
fixture_new() {
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-ops-test.XXXXXXXX")"
	mkdir -p "$TMP/bin" "$TMP/creds" "$TMP/log" "$TMP/roots" "$TMP/home"
	export TMP
	write_showenv
	# Every knob reset by the fixture, not only the ones this test uses. A
	# leftover value silently changes the meaning of a later assertion — which
	# once made one failing activation fail in every test after it.
	unset FAKE_HERDR_STATUS FAKE_SYSTEMCTL_MAINPID FAKE_SYSTEMCTL_ACTIVE
	unset FAKE_SYSTEMCTL_FAILED FAKE_NIX_STORE_GC_KEEPS FAKE_RESTIC_FAIL
	unset FAKE_RESTIC_NO_SNAPSHOTS FAKE_HEARTBEAT_FAIL FAKE_NIX_STORE_MISSING
	unset CREDENTIALS_DIRECTORY SECRET_ENV_MANIFEST AGENT_OPS_BACKUP_RECORD
	unset AGENT_OPS_SECRET_ENV AGENT_OPS_DAEMON_CHECK AGENT_OPS_STATE_DIR
	unset AGENT_OPS_RESUME_ROOTS AGENT_OPS_HEARTBEAT_URL
	unset MAX_HEARTBEAT_AGE START_TIMEOUT NS_OPS_TEST_MODE NM_GCROOTS
	unset MAX_ATTEMPTS RESTIC_TIMEOUT
	PATH="$TMP/bin:$ORIG_PATH"
	export PATH
	trap 'fixture_free' EXIT
}

fixture_free() {
	[[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"
	return 0
}

ORIG_PATH="$PATH"

# fake — write an executable fake named $1 with the body on stdin.
#
# Hardcoded interpreter path, never `#!/usr/bin/env bash`: a nix build sandbox
# has a coreutils-only root where /usr/bin/env does not exist, and a fake that
# cannot find its interpreter fails with "bad interpreter", which reads like a
# bug in the tool under test rather than in the harness.
fake() {
	local name="$1"
	{
		printf '#!%s\n' "$(command -v bash)"
		cat
	} >"$TMP/bin/$name"
	chmod +x "$TMP/bin/$name"
}

# showenv — print the environment of a child process, portably.
#
# NOT `/usr/bin/env`: a nix build sandbox has a coreutils-only root where
# /usr/bin/env does not exist, so a test that shells out to it passes on a
# developer machine and fails in CI for a reason that has nothing to do with the
# code. bash's own `compgen -e` plus indirect expansion needs nothing else.
SHOWENV_BODY='#!/bin/bash
for k in $(compgen -e | LC_ALL=C sort); do printf "%s=%s\\n" "$k" "${!k}"; done'
write_showenv() {
	local f="$TMP/bin/showenv"
	{
		printf '#!%s\n' "$(command -v bash)"
		printf '%s\n' "$SHOWENV_BODY"
	} >"$f"
	chmod +x "$f"
}

# ── the tools under test ────────────────────────────────────────────────────
# Exported so shellcheck does not flag them as unused in this file: they are
# read by the suites that source it, which is the whole point of a harness.
LANE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SECRET_ENV="$LANE_SRC/config/home/scripts/scripts/secret-env.sh"
DAEMON_CHECK="$LANE_SRC/config/home/scripts/scripts/herdr-daemon-check.sh"
RESUME="$LANE_SRC/config/home/scripts/scripts/herdr-resume.sh"
export SECRET_ENV DAEMON_CHECK RESUME DAEMON_ROOTS BACKUP HEALTH LIFETIME_NIX
DAEMON_ROOTS="$LANE_SRC/config/system/agent-ops/scripts/ns-agent-daemon-roots.sh"
BACKUP="$LANE_SRC/config/system/agent-ops/scripts/ns-agent-backup.sh"
HEALTH="$LANE_SRC/config/system/agent-ops/scripts/ns-agent-health.sh"
LIFETIME_NIX="$LANE_SRC/config/home/agent-lifetime.nix"