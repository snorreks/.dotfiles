#!/usr/bin/env bash
# nixos/tests/check-registry.sh — is the registry itself trustworthy?
#
# nixos/tests/run.sh claims three things. This file is what makes those claims
# checkable rather than aspirational:
#
#   1. A suite added under tests/ is DISCOVERED and its failure PROPAGATES.
#      Without the registry, a suite nobody registered simply never ran — and
#      the runner still reported success. That is the exact failure this
#      repository has already had once, with the agent-operations lane.
#   2. An UNREGISTERED suite is a hard failure, not a silent omission.
#   3. A suite that cannot run is never reported as a suite that passed.
#
# Everything here runs against COPIES of the registry and a scratch fixture
# tree. The real registry is never written to, and no suite is ever executed —
# a stub stands in for each one, so a registry bug cannot run a real test.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/harness.sh
source "$HERE/lib/harness.sh"

printf '\033[1mcheck registry — discovery, propagation, and no false green\033[0m\n'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── harness ─────────────────────────────────────────────────────────────────
#
# `harness` builds a throwaway copy of run.sh plus a fake tests/ tree, so the
# registry under test is a fixture rather than the real one.

# usage: harness <registry-file> <suite-path> [extra env assignments...]
harness() {
  local reg="$1" suite="$2"
  shift 2
  local home="$WORK/case$RANDOM$RANDOM"
  mkdir -p "$home/tests"

  # A minimal tests/ tree containing exactly the suite we are exercising, plus
  # whatever the registry names. run.sh resolves paths relative to its own
  # parent, so copying it next to the fixture tree is enough.
  cp "$HERE/run.sh" "$home/tests/run.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$home/$suite"
  chmod +x "$home/$suite"
  cp "$reg" "$home/tests/registry.tsv"

  # registry.tsv may name other paths; create trivial stand-ins so validation
  # does not fail on them for the wrong reason.
  while IFS=$'\t' read -r _lane path _scope _kind; do
    [[ -z "${path:-}" || "$path" == \#* ]] && continue
    [[ -e "$home/$path" ]] || { mkdir -p "$(dirname "$home/$path")"; printf '#!/usr/bin/env bash\nexit 0\n' >"$home/$path"; }
  done <"$reg"

  printf '%s' "$home"
}

# Run a harness tree, capturing combined output and exit status.
run_harness() {
  local home="$1"
  shift
  # Captured without toggling errexit.
  #
  # `set +e` / `set -e` around this looked harmless and was not: it rewrote the
  # caller's shell options, so the state after this function depended on what
  # the function did internally, and any later code relying on errexit could
  # behave differently depending on whether this had run. Using `if !` to
  # capture the status never touches the option at all, and a non-zero exit is
  # expected here anyway — several cases assert that run.sh fails.
  if REG_OUT="$(env "$@" bash "$home/tests/run.sh" 2>&1)"; then
    REG_STATUS=0
  else
    REG_STATUS=$?
  fi
}

# ── fixtures ────────────────────────────────────────────────────────────────

REAL_REG="$HERE/registry.tsv"

# A registry whose single suite fails, to prove propagation.
make_failing_registry() {
  local out="$WORK/failing.tsv"
  {
    printf '# fixture: the one suite fails\n'
    printf 'fixture\ttests/broken.sh\tfast\tshell\n'
  } >"$out"
  printf '%s' "$out"
}

# ── 1. an added fixture suite is discovered and its failure propagates ──────

t_start "an added suite that fails must fail the run"

reg="$(make_failing_registry)"
home="$(harness "$reg" tests/broken.sh)"

# Now make the suite actually fail.
printf '#!/usr/bin/env bash\necho "this suite fails on purpose" >&2\nexit 1\n' >"$home/tests/broken.sh"
chmod +x "$home/tests/broken.sh"

run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "1" "$REG_STATUS" "run.sh must exit non-zero when a suite fails"
assert_contains "$REG_OUT" "this suite fails on purpose" "the failing suite's own output must reach the operator"
assert_contains "$REG_OUT" "FAILED" "run.sh must say it failed"
assert_not_contains "$REG_OUT" "all checks passed" "run.sh must not claim success after a failure"

# ── 2. the same registry with a passing suite is green ──────────────────────

t_start "the same suite passing must be green"

reg="$(make_failing_registry)"
home="$(harness "$reg" tests/broken.sh)"
run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "0" "$REG_STATUS" "run.sh must exit zero when every suite passes"
# A harness tree may legitimately skip lint stages (shellcheck and nix are not
# always on PATH), and run.sh says so rather than claiming a clean pass. Both
# phrasings are a pass; what is NOT acceptable is neither, which the failure
# case above already asserts against.
if [[ "$REG_OUT" == *"all checks passed"* || "$REG_OUT" == *"declared skip"* ]]; then
  _ok "run.sh reports success (unqualified, or with its skips accounted for)"
else
  _fail "run.sh reports success (unqualified, or with its skips accounted for)" \
    "got neither an unqualified pass nor a skip summary"
fi

# ── 3. an UNREGISTERED suite is a failure, not a silent omission ────────────

t_start "an unregistered suite must fail the run"

reg="$WORK/empty.tsv"
{
  printf '# fixture: registers nothing about the extra suite\n'
  printf 'fixture\ttests/registered.sh\tfast\tshell\n'
} >"$reg"
home="$(harness "$reg" tests/registered.sh)"
# Drop a suite on disk that nobody registered — the agent-operations failure.
printf '#!/usr/bin/env bash\nexit 0\n' >"$home/tests/quietly-missed.sh"
chmod +x "$home/tests/quietly-missed.sh"

run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "1" "$REG_STATUS" "an unregistered suite must fail the run"
assert_contains "$REG_OUT" "unregistered suite: tests/quietly-missed.sh" \
  "run.sh must name the unregistered suite"
assert_not_contains "$REG_OUT" "all checks passed" \
  "an unregistered suite must never read as a green run"

# ── 4. a registry entry pointing at a missing file is a failure ─────────────

t_start "a registry entry for a missing file must fail the run"

reg="$WORK/missing.tsv"
{
  printf '# fixture: names a file that is not there\n'
  printf 'fixture\ttests/does-not-exist.sh\tfast\tshell\n'
} >"$reg"
# Build the tree WITHOUT the missing path (remove the stand-in harness made).
home="$(harness "$reg" tests/does-not-exist.sh)"
rm -f "$home/tests/does-not-exist.sh"

run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "1" "$REG_STATUS" "a registry entry with no file must fail the run"
assert_contains "$REG_OUT" "which does not exist" "run.sh must say the file is missing"

# ── 5. an unknown scope or kind is rejected before anything runs ────────────

t_start "an invalid scope must be rejected"

reg="$WORK/badscope.tsv"
{
  printf '# fixture: not a scope we know\n'
  printf 'fixture\ttests/registered.sh\tsometimes\t shell\n'
} >"$reg"
home="$(harness "$reg" tests/registered.sh)"
run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "1" "$REG_STATUS" "an unknown scope must fail the run"
assert_contains "$REG_OUT" "unknown scope" "run.sh must name the bad scope"

t_start "an invalid kind must be rejected"

reg="$WORK/badkind.tsv"
{
  printf '# fixture: not a kind we know\n'
  printf 'fixture\ttests/registered.sh\tfast\ttelepathy\n'
} >"$reg"
home="$(harness "$reg" tests/registered.sh)"
run_harness "$home" NM_REQUIRE_ALL=0
assert_eq "1" "$REG_STATUS" "an unknown kind must fail the run"
assert_contains "$REG_OUT" "unknown kind" "run.sh must name the bad kind"

# ── 6. a suite that cannot run must never read as one that passed ───────────

t_start "a skipped suite must not be reported as passed"

reg="$WORK/needsnix.tsv"
{
  printf '# fixture: an eval-scoped suite\n'
  printf 'fixture\ttests/needs-nix.sh\teval\tshell\n'
} >"$reg"
home="$(harness "$reg" tests/needs-nix.sh)"

# NM_SKIP_HOST_EVAL is the documented switch for "this eval-scoped suite
# cannot run here". It exercises the same skip path as a missing `nix` without
# emptying PATH — which would break `env bash` itself and turn the test into a
# pass for the wrong reason.
#
# NM_REQUIRE_ALL is passed EXPLICITLY rather than left to the environment's
# default. The flake check exports NM_REQUIRE_ALL=0 for its own reasons, and a
# test that silently inherits it would stop testing the default it claims to.
run_harness "$home" NM_SKIP_HOST_EVAL=1 NM_REQUIRE_ALL=1
assert_eq "1" "$REG_STATUS" "a suite that could not run must fail the default run"
assert_contains "$REG_OUT" "SKIPPED" "the skip must be reported"
assert_not_contains "$REG_OUT" "all checks passed" \
  "a skipped suite must never produce a green run"

# With the opt-out, the skip is allowed — but must still be visible.
run_harness "$home" NM_SKIP_HOST_EVAL=1 NM_REQUIRE_ALL=0
assert_eq "0" "$REG_STATUS" "the opt-out must allow a skip"
assert_contains "$REG_OUT" "SKIPPED" "an allowed skip must still be announced"
assert_contains "$REG_OUT" "declared skip" "the summary must account for the skip"
assert_not_contains "$REG_OUT" "all checks passed" \
  "a run with skips must not claim an unqualified pass"

# ── 7. kvm-scoped entries are declared but never run by run.sh ──────────────

t_start "kvm-scoped suites are declared, not run"

reg="$WORK/kvm.tsv"
{
  printf '# fixture: a kvm suite\n'
  printf 'fixture\ttests/vm-only.sh\tkvm\tshell\n'
} >"$reg"
home="$(harness "$reg" tests/vm-only.sh)"
# A kvm suite that would fail loudly if it were ever executed here.
printf '#!/usr/bin/env bash\necho "KVM SUITE MUST NOT RUN HERE" >&2\nexit 1\n' >"$home/tests/vm-only.sh"
chmod +x "$home/tests/vm-only.sh"

run_harness "$home" NM_REQUIRE_ALL=0
assert_not_contains "$REG_OUT" "KVM SUITE MUST NOT RUN HERE" "a kvm suite must not execute in run.sh"
assert_contains "$REG_OUT" "scope=kvm" "run.sh must say why the kvm suite did not run"
assert_contains "$REG_OUT" "NOT RUN" "run.sh must mark the kvm suite as not-run, not passed"

# ── 8. the REAL registry is internally consistent ───────────────────────────

t_start "the real registry is well formed"

assert_file "$REAL_REG" "registry.tsv exists"

# Every row has four tab-separated fields and a known scope/kind.
bad_rows="$(
  awk -F'\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 4 { print "row with " NF " fields: " $0 }
  ' "$REAL_REG"
)"
assert_eq "" "$bad_rows" "every registry row must have exactly 4 fields"

# Every path named in the real registry exists.
missing=""
while IFS=$'\t' read -r lane path _s _k; do
  [[ -z "${path:-}" || "$lane" == \#* ]] && continue
  [[ -e "$ROOT/$path" ]] || missing+="  $lane: $path"$'\n'
done <"$REAL_REG"
assert_eq "" "$missing" "every path in the real registry must exist"

# Every lane named in the real registry has at least one suite.
lanes_in_registry="$(awk -F'\t' '!/^[[:space:]]*#/ && NF==4 {print $1}' "$REAL_REG" | sort -u | wc -l | tr -d ' ')"
assert_ne "0" "$lanes_in_registry" "the real registry must declare at least one lane"

# The agent-operations lane must be present. It is the omission that motivated
# the registry; if it ever drops out again, this fails.
if awk -F'\t' '!/^[[:space:]]*#/ && NF==4 {print $1}' "$REAL_REG" | grep -qx 'agent-operations'; then
  _ok "the agent-operations lane is registered"
else
  _fail "the agent-operations lane is registered" \
    "it was silently omitted from the runner once before; it must not be again"
fi

# Same for media-travel and server-foundation.
for lane in agent-operations media-travel server-foundation maintenance repo-contracts; do
  if awk -F'\t' '!/^[[:space:]]*#/ && NF==4 {print $1}' "$REAL_REG" | grep -qx "$lane"; then
    _ok "lane '$lane' is registered"
  else
    _fail "lane '$lane' is registered" "missing from $REAL_REG"
  fi
done

# maintenanceVm must still be accounted for. It is a `nix build`, not a run.sh
# suite, so the registry names it in README terms — assert the derivation still
# exists so its absence would be noticed.
assert_file "$HERE/maintenance-vm.nix" "maintenance-vm.nix still exists (the KVM suite)"

suite_summary "check registry"
