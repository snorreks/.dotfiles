#!/usr/bin/env bash
# nixos/tests/media-travel/run.sh
#
# Entry point for the media-travel lane. Standalone and runnable on its own:
#
#   bash nixos/tests/media-travel/run.sh
#
# It follows the convention the server-foundation and agent-operations lanes
# already established: a plain bash script per property, runnable individually,
# with a thin runner over them. Every suite here also runs without `nix build`,
# so one failure reproduces in a second without building a flake.
#
# The suites evaluate REAL flake configurations and need `nix`. Set
# NM_SKIP_MEDIA_HOST_EVAL=1 to skip the host-evaluation suites (they are then
# reported loudly, never silently omitted), and NM_REQUIRE_ALL=0 to allow a
# skip in a build sandbox where `nix flake check` cannot reach flake inputs.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ordered cheapest-first so a developer sees the security-relevant failures
# before waiting on two flake evaluations.
SUITES=(
  # Drives the SHIPPED netns-up.sh with stubbed privileged tools and asserts the
  # netfilter calls it makes. No nix, no privileges, no namespace.
  "netns-failclosed.sh"
  # Runs the SHIPPED media-state.sh against a real SQLite database, including
  # the corrupt-database case.
  "state-restore.sh"
  # Static assertions on the shipped Syncthing ignore rules, against a fixture
  # tree containing one of each hazardous file type.
  "selective-sync.sh"
  # herdr-travel against a fake herdr, including the "never restart the server"
  # tripwire. No nix.
  "travel-builder.sh"
  # Evaluates both hosts. Needs `nix`.
  "host-isolation.sh"
)

HOST_EVAL_SUITES=("host-isolation.sh")

failed=0

printf '\033[1m=== media-travel: shellcheck\033[0m\n'
CHECKED=(
  "../../config/system/media/scripts/netns-up.sh"
  "../../config/system/media/scripts/netns-audit.sh"
  "../../config/system/media/scripts/media-state.sh"
  "../../config/system/media/scripts/media-offline-prep.sh"
  "../../config/system/media/scripts/jellyfin-accel-check.sh"
  "netns-failclosed.sh"
  "state-restore.sh"
  "selective-sync.sh"
  "travel-builder.sh"
  "host-isolation.sh"
  "lib/fixture.sh"
  "run.sh"
)
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${CHECKED[@]}"; do
    # -x follows `source=`; -P resolves it relative to this directory rather
    # than the caller's cwd.
    if shellcheck -x -P "$HERE" -S style "$HERE/$f"; then
      printf '    ok   %s\n' "${f#../../}"
    else
      printf '    FAIL %s\n' "${f#../../}"
      failed=1
    fi
  done
else
  printf '    shellcheck not on PATH — skipping (it is in the flake check closure)\n'
fi

printf '\n\033[1m=== media-travel: bash -n\033[0m\n'
for f in "${CHECKED[@]}"; do
  if bash -n "$HERE/$f"; then
    printf '    ok   %s\n' "${f#../../}"
  else
    printf '    FAIL %s\n' "${f#../../}"
    failed=1
  fi
done

# ── Skip policy ────────────────────────────────────────────────────────────
#
# A skipped suite must never read as a passed one. NM_REQUIRE_ALL defaults to 1
# (a developer run), so "the suite that evaluates the hosts did not run" cannot
# be a green result unless the caller explicitly said a skip is acceptable.
skip_allowed=0
if [[ "${NM_REQUIRE_ALL:-1}" != "1" ]]; then
  skip_allowed=1
fi
host_eval_ok=1
if [[ "${NM_SKIP_MEDIA_HOST_EVAL:-0}" == "1" ]] || ! command -v nix >/dev/null 2>&1; then
  host_eval_ok=0
fi

for suite in "${SUITES[@]}"; do
  is_host_eval=0
  for h in "${HOST_EVAL_SUITES[@]}"; do
    [[ "$suite" == "$h" ]] && is_host_eval=1
  done

  if [[ "$is_host_eval" == "1" && "$host_eval_ok" == "0" ]]; then
    reason="no nix on PATH"
    [[ "${NM_SKIP_MEDIA_HOST_EVAL:-0}" == "1" ]] && reason="NM_SKIP_MEDIA_HOST_EVAL=1"
    if [[ "$skip_allowed" == "0" ]]; then
      printf '\n\033[31mSKIPPED %s (%s), and this run requires every suite to actually run.\033[0m\n' "$suite" "$reason"
      printf '\033[31mRe-run with nix on PATH, or set NM_REQUIRE_ALL=0 if a skip is expected here.\033[0m\n'
      failed=1
    else
      printf '\n\033[33mSKIPPED %s (%s; expected in the checks sandbox)\033[0m\n' "$suite" "$reason"
    fi
    continue
  fi

  printf '\n\033[1m=== %s\033[0m\n' "$suite"
  if bash "$HERE/$suite"; then
    :
  else
    printf '\033[31mFAILED: %s\033[0m\n' "$suite"
    failed=1
    break
  fi
done

if [[ "$failed" -ne 0 ]]; then
  printf '\n\033[31mmedia-travel/run.sh: FAILED\033[0m\n'
  exit 1
fi
printf '\n\033[32mmedia-travel/run.sh: all checks passed\033[0m\n'

cat <<'NOTE'

Not covered here, and reported as PENDING rather than assumed:

  * A real network namespace. netns-failclosed.sh asserts the RULES the shipped
    script installs; netns-audit.sh asserts the rules that are actually IN
    effect on a live namespace, and needs root plus a provisioned tunnel. Run
    it on the server before travelling:
        netns-audit

  * Media services enabled. Every media service ships disabled, so this suite
    proves the defaults are inert — and inert-but-broken looks identical to
    inert. It is NOT expressible through `_module.args`: the flake passes
    `opts` via specialArgs, which outrank `_module.args`, so an extendModules
    override of `opts` is silently ignored.

    Instead, enable them in options.nix itself (the `enable = false` defaults
    under `media`, plus a tunnel endpoint and an upload limit), evaluate, and
    revert. That is how the enabled path gets checked, and it has to be done by
    hand: it found a set of faults that no default-off evaluation can see,
    including an unresolved `package = null`, a tmpfiles rule naming a
    directory option that did not exist, `networking.firewall.interfaces.*.log`,
    which is not an option, and an attrset passed to `serviceConfig.Environment`
    on three units. Any of those would have been the FIRST failure of a real
    deployment, discovered after the fact rather than in review.

  * Real hardware: Intel QSV/VAAPI acceleration, playback and seek, real-WAN
    throughput, direct-versus-relay. See docs/media-travel.md.
NOTE