#!/usr/bin/env bash
# nixos/tests/agent-operations/run.sh — this lane's own entry point.
#
# Deliberately separate from nixos/tests/run.sh: the lanes are developed in
# parallel and each must be runnable on its own before any of them are merged.
# Adding this lane's suites to the shared runner is the integration step, and
# doing it here would mean every lane's diff touched every other lane's runner.
# D's repo-contracts work is what consolidates discovery afterwards; this lane
# does not wait for it.
#
# errexit.sh exists because every production script below is built by
# writeShellApplication, which injects `set -o errexit -o nounset -o pipefail`.
# Running them with plain `bash` — as every other suite here does — cannot see
# that at all, so the errexit contract is asserted once, directly.
#
# The backup suite needs real restic and sqlite3. They are in the flake check's
# closure, so `nix build .#checks.…agent-operations` runs it for real; a
# developer running this script by hand without them gets a clear SKIP rather
# than a silent pass, because a silently skipped restore test is worse than no
# restore test.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

SUITES=(
	"errexit.sh"
	"secret-values-as-data.sh"
	"agent-lifetime.sh"
	"daemon-roots.sh"
	"herdr-resume.sh"
	"health-redaction.sh"
	"health-history.sh"
	"backup-restore.sh"
)

# Scripts this lane added or rewrote. Listed explicitly rather than discovered,
# because a discovery rule that silently stops matching is a check that silently
# stops running.
SHELLCHECKED=(
	"config/home/scripts/scripts/secret-env.sh"
	"config/home/scripts/scripts/herdr-daemon-check.sh"
	"config/home/scripts/scripts/herdr-resume.sh"
	"config/system/agent-ops/scripts/ns-agent-daemon-roots.sh"
	"config/system/agent-ops/scripts/ns-agent-backup.sh"
	"config/system/agent-ops/scripts/ns-agent-health.sh"
	"tests/agent-operations/lib/fixture.sh"
	"tests/agent-operations/run.sh"
)
for s in "${SUITES[@]}"; do
	SHELLCHECKED+=("tests/agent-operations/$s")
done

# Nix files this lane added, parsed rather than evaluated: a parse check is
# seconds, and the real evaluation of agent-lifetime.nix over the whole
# (headless x mobileAgents) matrix is agent-lifetime.sh's job.
NIX_PARSED=(
	"config/home/agent-lifetime.nix"
	"config/system/agent-ops/health.nix"
)

failed=0

printf '\033[1m=== lint: shellcheck\033[0m\n'
if command -v shellcheck >/dev/null 2>&1; then
	for f in "${SHELLCHECKED[@]}"; do
		# -x follows `source=` directives; -P resolves them relative to this
		# directory rather than the caller's cwd.
		if shellcheck -x -P "$HERE" -S style "$ROOT/$f"; then
			printf '    ok   %s\n' "$f"
		else
			printf '    FAIL %s\n' "$f"
			failed=1
		fi
	done
else
	printf '    shellcheck not on PATH — skipping (it is in the flake check closure)\n'
fi

printf '\n\033[1m=== lint: bash -n\033[0m\n'
for f in "${SHELLCHECKED[@]}"; do
	if bash -n "$ROOT/$f"; then
		printf '    ok   %s\n' "$f"
	else
		printf '    FAIL %s\n' "$f"
		failed=1
	fi
done

printf '\n\033[1m=== lint: nix (the generated config and the modules)\033[0m\n'
if command -v nix-instantiate >/dev/null 2>&1; then
	for f in "${NIX_PARSED[@]}"; do
		if nix-instantiate --parse "$ROOT/$f" >/dev/null 2>&1; then
			printf '    ok   %s parses\n' "$f"
		else
			printf '    FAIL %s does not parse\n' "$f"
			failed=1
		fi
	done
else
	printf '    nix not on PATH — skipping\n'
fi

for suite in "${SUITES[@]}"; do
	printf '\n\033[1m=== %s\033[0m\n' "$suite"
	if bash "$HERE/$suite"; then
		:
	else
		printf '\033[31mFAILED: %s\033[0m\n' "$suite"
		failed=1
		break
	fi
done

if ((failed != 0)); then
	printf '\n\033[31magent-operations: FAILED\033[0m\n'
	exit 1
fi
printf '\n\033[32magent-operations: all checks passed\033[0m\n'