#!/usr/bin/env bash
# nixos/tests/run.sh — one entry point for every check this repository can run
# without a physical machine.
#
# Deliberately a thin, honest runner rather than a test framework:
#
#   * Every suite it runs is a plain bash script that also runs standalone, so a
#     developer can reproduce one failure without `nix build`.
#   * It exits non-zero on the FIRST failing suite, and prints which one, rather
#     than continuing and burying the first error under later noise.
#   * It does not pretend to be CI. The flake `checks` outputs below are what
#     runs this in a sandbox; there is no workflow file, because there is no CI
#     configured for this repository and a workflow that never runs is worse
#     than none.
#
# The NixOS VM test (nixos/tests/maintenance-vm.nix) is NOT run here. It needs
# KVM and builds a whole NixOS system, so it is a separate `nix build` — see
# nixos/tests/README.md.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SUITES=(
  "ns-maint-transaction.sh"
  "kill-switch-targets.sh"
  "disk-cleanup-safety.sh"
  # The server-foundation lane. Standalone and runnable on its own before any
  # central registry exists — `bash nixos/tests/server-foundation/host-eval.sh`
  # reproduces one of them without going through this runner at all.
  #
  # host-eval.sh is listed LAST and separately below: it evaluates four real
  # flake configurations, which needs `nix` and takes ~15s rather than
  # milliseconds. It is still here rather than hidden behind another entry point
  # so that "run everything this repository can run" means exactly that.
  "server-foundation/role-policy.sh"
  "server-foundation/boot-health.sh"
  "server-foundation/tailscale-reconcile.sh"
  "server-foundation/ssh-confirm.sh"
  "server-foundation/host-eval.sh"
)

failed=0

printf '\033[1m=== lint: shellcheck\033[0m\n'
# Lint first, because a syntax error in a script produces test output that is
# confusing rather than useful. Only the scripts this PR added or rewrote are
# listed; a repository-wide shellcheck run belongs to the repo-contracts PR.
SHELLCHECKED=(
  "config/system/maintenance/ns-maint.sh"
  "config/system/boot/health.sh"
  "config/system/tailscale/reconcile.sh"
  "config/system/battery/charge-limit.sh"
  "config/home/scripts/scripts/disk-cleanup.sh"
  "config/home/scripts/scripts/kill-switch.sh"
  "config/home/scripts/scripts/kill-switch-cleanup.sh"
  "tests/lib/harness.sh"
  "tests/ns-maint-transaction.sh"
  "tests/kill-switch-targets.sh"
  "tests/disk-cleanup-safety.sh"
  "tests/server-foundation/role-policy.sh"
  "tests/server-foundation/boot-health.sh"
  "tests/server-foundation/tailscale-reconcile.sh"
  "tests/server-foundation/ssh-confirm.sh"
  "tests/server-foundation/host-eval.sh"
)
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${SHELLCHECKED[@]}"; do
    # -x follows `source=` directives; -P lets `# shellcheck source=lib/harness.sh`
    # resolve relative to the tests directory rather than the caller's cwd.
    if shellcheck -x -P "$ROOT/tests" -S style "$ROOT/$f"; then
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
for f in "${SHELLCHECKED[@]}" "tests/run.sh"; do
  if bash -n "$ROOT/$f"; then
    printf '    ok   %s\n' "$f"
  else
    printf '    FAIL %s\n' "$f"
    failed=1
  fi
done

for suite in "${SUITES[@]}"; do
  # host-eval.sh evaluates four real flake configurations, which needs a nix
  # that can reach the store and the flake's inputs. A `checks` sandbox has
  # neither, so the check declares that it cannot run this one:
  #
  #   NM_SKIP_HOST_EVAL=1   set by the flake check, with the reason in
  #                        nixos/flake.nix
  #
  # It is skipped LOUDLY, and it is an error unless the caller has said a skip is
  # acceptable. NM_REQUIRE_ALL=1 is the default — a developer run — so "the
  # suite that checks the hosts did not run" can never be a green result there.
  # Run it directly with:
  #
  #   bash nixos/tests/server-foundation/host-eval.sh
  if [[ "${suite##*/}" == "host-eval.sh" ]] &&
    { [[ "${NM_SKIP_HOST_EVAL:-0}" == "1" ]] || ! command -v nix >/dev/null 2>&1; }; then
    reason="no nix on PATH"
    [[ "${NM_SKIP_HOST_EVAL:-0}" == "1" ]] && reason="NM_SKIP_HOST_EVAL=1"
    if [[ "${NM_REQUIRE_ALL:-1}" != "0" ]]; then
      printf '\n\033[31mSKIPPED %s (%s), and this run requires every suite to actually run.\033[0m\n' "$suite" "$reason"
      printf '\033[31mRe-run with nix on PATH and no NM_SKIP_HOST_EVAL, or set NM_REQUIRE_ALL=0\033[0m\n'
      printf '\033[31mif a skip is expected here.\033[0m\n'
      failed=1
    else
      printf '\n\033[33mSKIPPED %s (%s; expected in the checks sandbox)\033[0m\n' "$suite" "$reason"
    fi
    continue
  fi

  printf '\n\033[1m=== %s\033[0m\n' "${suite##*/}"
  if bash "$HERE/$suite"; then
    :
  else
    printf '\033[31mFAILED: %s\033[0m\n' "$suite"
    failed=1
    break
  fi
done

if [[ "$failed" -ne 0 ]]; then
  printf '\n\033[31mrun.sh: FAILED\033[0m\n'
  exit 1
fi
printf '\n\033[32mrun.sh: all checks passed\033[0m\n'