#!/usr/bin/env bash
# nixos/tests/lib/harness.sh — the shared foundation for this repository's
# shell-level contract tests.
#
# Deliberately NOT bats, and deliberately not a framework. Three reasons:
#
#   * The things under test are bash scripts that call coreutils, flock, systemd
#     and git. Reproducing them in a mock-heavy test language would test the
#     mocks. Running the real script with real binaries, pointed at a temporary
#     root with a handful of fakes on PATH, tests the actual thing.
#   * `nix flake check` has to be able to run these in a sandbox with nothing
#     but bash, coreutils, util-linux and git present. One more dependency to
#     pin and keep working is one more thing to fail for an unrelated reason.
#   * A failure message that says "line 412, expected 3 got 4" is easier to act
#     on during an incident than a bats stack trace.
#
# What a fixture gives you:
#
#   $TMP/          everything below is per-test and disposable
#   $TMP/bin/      fakes for nix, nix-store, nix-env, systemctl, systemd-run,
#                  journalctl — behaviour driven by FAKE_* env vars
#   $TMP/store/    fake "closures": directories with kernel-modules/lib/modules
#   $TMP/run/      NM_CURRENT_SYSTEM and NM_BOOTED_SYSTEM symlinks
#   $TMP/profile/  NM_PROFILE, a generation-numbered profile directory
#   $TMP/state/    NM_DIR, the transaction record
#   $TMP/gcroots/  NM_GCROOTS
#   $TMP/log/      every fake command's invocation, one line per call
#
# Every fake logs to $TMP/log/calls, which is how the tests assert on what the
# tool DID rather than only on what it said.

set -o nounset -o pipefail

# ── assertions ──────────────────────────────────────────────────────────────
TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

t_start() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '\n  \033[1m%s\033[0m\n' "$CURRENT_TEST"
}

_ok() { printf '    \033[32mok\033[0m   %s\n' "$1"; }
_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '    \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
  if [[ -n "${DUMP_LOG:-}" && -f "$DUMP_LOG" ]]; then
    printf '         ---- fake command log ----\n'
    sed 's/^/         /' "$DUMP_LOG" | tail -40
  fi
  # Captured command output is usually where the actual explanation is. Without
  # this, a failure inside a sandbox — where nobody can afterwards read $TMP —
  # reports only the symptom.
  if [[ -n "${TMP:-}" && -d "$TMP/log" ]]; then
    local f
    for f in "$TMP"/log/*.out; do
      [[ -s "$f" ]] || continue
      printf '         ---- %s ----\n' "${f##*/}"
      tail -12 "$f" | sed 's/^/         /'
    done
  fi
}

assert_eq() {
  local want="$1" got="$2" what="$3"
  if [[ "$want" == "$got" ]]; then _ok "$what"; else _fail "$what" "expected [$want] got [$got]"; fi
}

assert_ne() {
  local unwanted="$1" got="$2" what="$3"
  if [[ "$unwanted" != "$got" ]]; then _ok "$what"; else _fail "$what" "did not expect [$unwanted]"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then _ok "$what"; else _fail "$what" "[$needle] not found in: $haystack"; fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" != *"$needle"* ]]; then _ok "$what"; else _fail "$what" "[$needle] should not appear in: $haystack"; fi
}

assert_file() {
  if [[ -e "$1" ]]; then _ok "$2"; else _fail "$2" "missing: $1"; fi
}

assert_no_file() {
  if [[ ! -e "$1" ]]; then _ok "$2"; else _fail "$2" "should not exist: $1"; fi
}

# assert_no_reboot — the invariant this whole PR exists to establish.
#
# Every fake reboot records itself here, and the suite calls this at the end of
# every test. The point is that it is a SINGLE assertion applied to ALL ordinary
# paths rather than "we checked the timeout path has no reboot" — the failure
# mode being defended against is a reboot somewhere nobody thought to check.
assert_no_reboot() {
  # Suites that are not about ns-maint (the cleanup and kill-switch ones) have
  # no fixture, so there is nothing that could have rebooted. Say so rather
  # than inventing an empty expectation.
  if [[ -z "${TMP:-}" ]]; then
    _ok "not applicable to this suite"
    return 0
  fi
  local n=0
  if [[ -f "$TMP/reboots" ]]; then
    n="$(grep -c . "$TMP/reboots" || true)"
  fi
  assert_eq 0 "$n" "no reboot was issued on this path"
}

assert_gc_root() {
  local name="$1" what="$2"
  if [[ -L "$TMP/gcroots/ns-maint-$name" ]]; then
    _ok "$what"
  else
    _fail "$what" "no GC root $TMP/gcroots/ns-maint-$name"
  fi
}

assert_no_gc_root() {
  local name="$1" what="$2"
  if [[ ! -e "$TMP/gcroots/ns-maint-$name" ]]; then
    _ok "$what"
  else
    _fail "$what" "GC root $TMP/gcroots/ns-maint-$name should have been released"
  fi
}

# ── fake store paths ────────────────────────────────────────────────────────
#
# Real Nix store paths, because ns-maint VALIDATES store paths on read and a
# fake-looking path would test the validator instead of the transaction.
_n=0
fake_store_path() {
  local label="${1:-closure}"
  _n=$((_n + 1))
  local h
  h="$(printf '%032d' "$_n")"
  # 32 chars of [a-z0-9] then a name from the same alphabet.
  h="$(printf '%s' "$h" | tr '0-9' 'abcdfghjkmnpqrstvwxyz')"
  printf '%s/%s-nixos-system-%s' "$NM_STORE_PREFIX" "$h" "$label"
}

# ── fixtures ────────────────────────────────────────────────────────────────
#
# usage: fixture_new [kernel_version]
#
# Sets: TMP, and exports the NM_* overrides. Creates a fresh, disposable world.
# Each test calls this so no test can see another's transaction record.
fixture_new() {
  local kernel="${1:-6.1.0-test}"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/ns-maint-test.XXXXXX")"
  export TMP
  mkdir -p "$TMP/bin" "$TMP/nixstore" "$TMP/run" "$TMP/profile" "$TMP/state" \
    "$TMP/gcroots" "$TMP/log" "$TMP/flake" "$TMP/esp"
  # /nix/store is read-only for an unprivileged user (and inside a nix build
  # sandbox it does not exist at all), so the fake closures live in a disposable
  # prefix. ns-maint's own store-path validation still applies in full — the 32
  # character hash, the name charset and the rejection of anything that could be
  # a path traversal are all exercised, and there is a test for it.
  export NM_STORE_PREFIX="$TMP/nixstore"
  DUMP_LOG="$TMP/log/calls"
  : >"$DUMP_LOG"
  : >"$TMP/reboots"

  FAKE_RUNNING="$(fake_store_path running)"
  FAKE_BOOTED="$FAKE_RUNNING"
  FAKE_CANDIDATE="$(fake_store_path candidate)"
  FAKE_SLOW_CANDIDATE="$(fake_store_path slow-candidate)"
  FAKE_OTHER_CANDIDATE="$(fake_store_path other-candidate)"

  make_closure "$FAKE_RUNNING" "$kernel"
  make_closure "$FAKE_BOOTED" "$kernel"
  make_closure "$FAKE_CANDIDATE" "$kernel"
  make_closure "$FAKE_SLOW_CANDIDATE" "$kernel"
  make_closure "$FAKE_OTHER_CANDIDATE" "$kernel"

  ln -sfn "$FAKE_RUNNING" "$TMP/run/current-system"
  ln -sfn "$FAKE_BOOTED" "$TMP/run/booted-system"

  # A generation-numbered profile, shaped like the real one: the profile is a
  # symlink to a generation link ("system-7-link"), and that link is a symlink to
  # the closure. So `readlink` on the profile yields a RELATIVE name, which is
  # exactly the case generation_of() has to parse, and which is also why
  # restore_profile_intent must resolve the generation link to a store path.
  ln -sfn "$FAKE_RUNNING" "$TMP/profile/system-7-link"
  ln -sfn "system-7-link" "$TMP/profile/system"

  install_tool
  write_fakes

  export NM_DIR="$TMP/state"
  export NM_GCROOTS="$TMP/gcroots"
  export NM_PROFILE="$TMP/profile/system"
  export NM_CURRENT_SYSTEM="$TMP/run/current-system"
  export NM_BOOTED_SYSTEM="$TMP/run/booted-system"
  export NM_FLAKE="$TMP/flake"
  export NM_HOST="legion"
  export NM_TEST_MODE=1
  export NM_TICK_SECONDS=1
  export NM_NIX="$TMP/bin/nix"
  export NM_NIX_STORE="$TMP/bin/nix-store"
  export NM_ENV="$TMP/bin/nix-env"
  export NM_SYSTEMCTL="$TMP/bin/systemctl"
  export NM_SYSTEMD_RUN="$TMP/bin/systemd-run"
  export NM_JOURNALCTL="$TMP/bin/journalctl"
  export NM_SWITCH_TO_CONFIGURATION="$TMP/bin/switch-to-configuration"
  export NM_REBOOT_CMD="$TMP/bin/reboot-cmd"
  export NM_SSH_UNIT="sshd.service"

  # The EFI-space preflight `ns-maint stage` runs before it writes a bootloader
  # entry. Pointed at a disposable directory with a FAKE `df`, because:
  #
  #   * a test that measured the machine's real /boot would fail or pass
  #     depending on how full the developer's ESP is — which, on this machine,
  #     is a real problem (see config/system/boot.nix), not a test fixture;
  #   * `df` needs no privilege to statvfs, so there is no security reason for
  #     the real one to be involved at all.
  #
  # FAKE_ESP_FREE_MIB is what a test sets to make the ESP look full or empty.
  export NM_ESP_PATH="$TMP/esp"
  export NM_DF="$TMP/bin/df"
  export NM_ESP_MIN_MIB=150

  # Defaults the fakes read. A test overrides one of these to inject a failure.
  #
  # EVERY knob is reset here, not just the ones this fixture happens to use:
  # these are exported into the environment, so a value left over from an
  # earlier test would silently change the meaning of a later one. (It did,
  # once: a candidate activation that failed in one test was still failing in
  # every test after it, which made a dozen unrelated assertions fail at once.)
  export FAKE_BUILD_RESULT="$FAKE_CANDIDATE"
  export FAKE_BUILD_SLEEP=0
  export FAKE_BUILD_EXIT=0
  export FAKE_SWITCH_LOG="$TMP/log/switch"
  export FAKE_SWITCH_SLEEP=0
  export FAKE_PROFILE_SET_EXIT=0
  export FAKE_PROFILE_RESTORE_EXIT=0
  unset FAKE_STOP_DEADLINE_PID_FILE
  export FAKE_SWITCH_OLD_SLEEP=0
  export NM_RESTORE_TIMEOUT=3
  export FAKE_SWITCH_IGNORE_TERM=0
  export FAKE_SWITCH_CANDIDATE_EXIT=0
  export FAKE_SWITCH_OLD_EXIT=0
  export FAKE_SWITCH_OLD_BOOT_EXIT=0
  export FAKE_SWITCH_MOVES_PROFILE=1
  export FAKE_FAILED_UNITS=""
  export FAKE_SSHD_LOG="$TMP/log/sshd"
  export FAKE_SYSTEMD_RUN_MODE=foreground
  export FAKE_SYSTEMD_RUN_EXIT=0
  export FAKE_RESTORE_UNIT_STATE=""
  : >"$TMP/log/switch"
  : >"$TMP/log/sshd"
}

make_closure() {
  local path="$1" kernel="$2"
  local modules="$NM_STORE_PREFIX/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-modules-$kernel"
  mkdir -p "$path" "$modules/lib/modules/$kernel"
  ln -sfn "$modules" "$path/kernel-modules"
  # A switch-to-configuration is expected to exist; the FAKE one replaces it at
  # call time via NM_SWITCH_TO_CONFIGURATION, but its presence is what makes the
  # closure pass ns-maint's own sanity checks.
  printf '#!/bin/sh\nexit 0\n' >"$path/bin-switch"
  mkdir -p "$path/bin"
  printf '#!/bin/sh\necho "real switch-to-configuration $*" >>%s\nexit 0\n' "$TMP/log/switch-real" >"$path/bin/switch-to-configuration"
  chmod +x "$path/bin/switch-to-configuration"
}

fixture_free() {
  [[ -n "${TMP:-}" && -d "$TMP" && "${KEEP_TMP:-0}" != "1" ]] && rm -rf "$TMP"
  return 0
}

# ── record access (the tool's own status output, not the file) ───────────────
# rec_field — read one field out of the tool's own JSON status output.
#
# Deliberately reads the PUBLIC interface rather than the record file, so a test
# cannot pass while the operator-facing output is wrong. No JSON parser: the
# output is a flat object of scalar values with no escapes, so a sed that pulls
# out the first "field":"value" pair is enough and keeps the sandbox's
# dependencies to bash + coreutils.
rec_field() {
  local f="$1"
  ns_maint status --json | sed -n 's/.*"'"$f"'":"\([^"]*\)".*/\1/p'
}

txid() { rec_field txid; }
phase() { rec_field phase; }

fake_calls() {
  [[ -f "$TMP/log/calls" ]] && cat "$TMP/log/calls" || true
}

switch_calls() {
  [[ -f "$TMP/log/switch" ]] && cat "$TMP/log/switch" || true
}

# ── the tool under test ─────────────────────────────────────────────────────
#
# Invoked from source, with the deployment's overrides pointed at the fixture.
# writeShellApplication wraps this identically in production; the only
# difference is that here it is not read-only in the store.
#
# `activate` resolves its own absolute path and hands THAT to systemd-run, so the
# transient unit runs the same script by the same route it would in production.
# The source file in the tree is not executable (writeShellApplication is what
# makes the store copy executable), so the fixture installs an executable copy
# and points NS_MAINT_SCRIPT at it. Otherwise every test would be asserting on a
# unit that failed with EACCES.
NS_MAINT_SRC="${NS_MAINT_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/system/maintenance/ns-maint.sh}"

ns_maint() {
  bash "$NS_MAINT_SCRIPT" "$@"
}

# ns_maint_bg — start the tool detached, to prove activation outlives its caller.
ns_maint_bg() {
  bash "$NS_MAINT_SCRIPT" "$@" >"$TMP/log/bg.out" 2>&1 &
  printf '%s' "$!"
}

# install_tool — an executable copy of the script under test, in the fixture's
# own bin directory.
install_tool() {
  NS_MAINT_SCRIPT="$TMP/bin/ns-maint"
  install -m 0755 "$NS_MAINT_SRC" "$NS_MAINT_SCRIPT"
  export NS_MAINT_SCRIPT
}

# ── fake commands ───────────────────────────────────────────────────────────
write_fakes() {
  local b="$TMP/bin"

  # Every fake is written with a hardcoded interpreter path rather than
  # `#!/usr/bin/env bash`. A nix build sandbox has a coreutils-only root: /bin/sh
  # exists, /usr/bin/env does not, and a fake that cannot find its interpreter
  # fails with "bad interpreter" — which looks like a bug in the tool under test
  # rather than in the test harness.
  local shebang
  shebang="#!$(command -v bash)"

  cat >"$b/nix" <<'FAKE'
#!/usr/bin/env bash
# Fake `nix`. Only `build ... --print-out-paths` and `flake update` are used by
# ns-maint. FAKE_BUILD_SLEEP models a build that outlasts any timeout;
# FAKE_BUILD_EXIT models a build failure. Neither can produce a side effect the
# tool is not supposed to produce on those paths, which is exactly what the
# build-timeout test asserts.
#
# `flake update` is NOT a stub that accepts anything. The real command treats
# every POSITIONAL argument as an input name and selects the flake with
# --flake, so a fake that accepted any argv would have passed while the real
# nix failed with "invalid flake input attribute path element". This fake
# enforces the same shape: the flake must arrive via --flake, and at least one
# positional input must remain.
echo "nix $*" >>"${TMP}/log/calls"
if [[ "$*" == *"flake update"* ]]; then
  had_flake=0
  inputs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    flake) shift ;;
    update) shift ;;
    --flake) had_flake=1; shift 2 ;;
    --extra-experimental-features | --offline | --no-link | --print-out-paths)
      shift 2
      ;;
    -*) shift ;;
    *) inputs+=("$1"); shift ;;
    esac
  done
  if [[ "$had_flake" -ne 1 ]]; then
    echo "error: the flake must be selected with --flake, not given positionally" >>"${TMP}/log/calls"
    exit 1
  fi
  if [[ "${#inputs[@]}" -eq 0 ]]; then
    echo "error: 'nix flake update' would recreate the whole lock file" >>"${TMP}/log/calls"
    exit 1
  fi
  echo "flake-update inputs=${inputs[*]}" >>"${TMP}/log/calls"
  exit 0
fi
if [[ "${FAKE_BUILD_SLEEP:-0}" -gt 0 ]]; then
  echo "build-sleep-start" >>"${TMP}/log/calls"
  sleep "${FAKE_BUILD_SLEEP}"
  echo "build-sleep-end" >>"${TMP}/log/calls"
fi
if [[ "${FAKE_BUILD_EXIT:-0}" -ne 0 ]]; then
  echo "build-failed" >>"${TMP}/log/calls"
  exit "${FAKE_BUILD_EXIT}"
fi
echo "build-ok" >>"${TMP}/log/calls"
echo "${FAKE_BUILD_RESULT}"
FAKE

  cat >"$b/nix-store" <<'FAKE'
#!/usr/bin/env bash
# Fake `nix-store`. Implements --add-root (creating the indirect root symlink the
# real one would create, in the directory it was invoked from) and --gc, and
# records whether -d / --delete was asked for: generations must never be
# deleted, and that is only observable here.
echo "nix-store $*" >>"${TMP}/log/calls"
root=""
realise=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --add-root) root="$2"; shift 2 ;;
  --realise | -r) shift ;;
  --gc) echo "gc-args ${*:2}" >>"${TMP}/log/calls"; exit 0 ;;
  -*) shift ;;
  *) realise="$1"; shift ;;
  esac
done
[[ -n "$root" ]] || exit 0
ln -sfn "$realise" "$root"
echo "gc-root $root -> $realise" >>"${TMP}/log/calls"
exit 0
FAKE

  cat >"$b/nix-env" <<'FAKE'
#!/usr/bin/env bash
# Fake `nix-env`. Supports --list-generations and --switch-generation against a
# profile directory, which is how restore_profile_intent restores the PROFILE
# intent rather than just the runtime.
echo "nix-env $*" >>"${TMP}/log/calls"
prof=""
gen=""
b=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --profile | -p) prof="$2"; shift 2 ;;
  --list-generations)
    # Real nix-env reports generation, date and time, not store paths.
    for l in "$(dirname "$prof")"/system-*-link; do
      [[ -L "$l" ]] || continue
      b="${l##*/}"
      g="${b#system-}"
      g="${g%-link}"
      printf '%s 2026-10-01 12:00:00\n' "$g"
    done
    exit 0
    ;;
  --set)
    [[ "${FAKE_PROFILE_SET_EXIT:-0}" -eq 0 ]] || exit "$FAKE_PROFILE_SET_EXIT"
    ln -sfn "$2" "${prof}-8-link"
    ln -sfn "${prof##*/}-8-link" "$prof"
    exit 0
    ;;
  --switch-generation)
    [[ "${FAKE_PROFILE_RESTORE_EXIT:-0}" -eq 0 ]] || exit "$FAKE_PROFILE_RESTORE_EXIT"
    gen="$2"; shift 2 ;;
  *) shift ;;
  esac
done
link="$(dirname "$prof")/system-$gen-link"
if [[ -L "$link" ]]; then
  # Real nix-env points the profile at the GENERATION LINK, not at the store
  # path, so the profile's own `readlink` keeps yielding a generation name.
  # Preserve that shape: a fake that resolved it all the way to a store path
  # would stop exercising generation_of() and the generation verification.
  ln -sfn "system-$gen-link" "$prof"
  echo "switch-generation $gen" >>"${TMP}/log/calls"
  exit 0
fi
echo "nix-env: generation $gen not found" >&2
exit 1
FAKE

  cat >"$b/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >>"${TMP}/log/calls"
if [[ "$*" == *ns-maint-restore-* ]]; then
  case "$1" in
  show)
    if [[ -n "${FAKE_RESTORE_UNIT_STATE:-}" ]]; then echo loaded; else echo not-found; fi
    exit 0 ;;
  is-active)
    [[ "${FAKE_RESTORE_UNIT_STATE:-}" == active ]] && exit 0
    exit 3 ;;
  esac
fi
if [[ "$*" == *"--failed"* ]]; then
  printf '%s' "${FAKE_FAILED_UNITS:-}"
  exit 0
fi
if [[ "$1" == "reboot" ]]; then
  echo "reboot" >>"${TMP}/reboots"
fi
exit 0
FAKE

  cat >"$b/systemd-run" <<'FAKE'
#!/usr/bin/env bash
# Fake systemd-run: a detached worker survives a terminated waiting client.
echo "systemd-run $*" >>"${TMP}/log/calls"
[[ "${FAKE_SYSTEMD_RUN_EXIT:-0}" -eq 0 ]] || exit "$FAKE_SYSTEMD_RUN_EXIT"
unit=""
wait_for_unit=0
cmd=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --wait=*) exit 2 ;;
  --wait) wait_for_unit=1 ;;
  --unit=*) unit="${1#--unit=}" ;;
  --* | -*) ;;
  *) cmd+=("$1") ;;
  esac
  shift
done
if [[ "${FAKE_SYSTEMD_RUN_MODE:-foreground}" == "background" ]]; then
  ( "${cmd[@]}" >>"${TMP}/log/unit.out" 2>&1 ) &
  worker=$!
  if [[ "$wait_for_unit" -eq 1 ]]; then
    wait "$worker"
    exit $?
  fi
  disown 2>/dev/null || true
  exit 0
fi
"${cmd[@]}" >>"${TMP}/log/unit.out" 2>&1
FAKE

  cat >"$b/journalctl" <<'FAKE'
#!/usr/bin/env bash
# Fake `journalctl`. Answers the one question ns-maint asks it: was a session
# accepted from this peer SINCE the switch was armed?
echo "journalctl $*" >>"${TMP}/log/calls"
since=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--since" ]]; then since="${a#@}"; fi
  prev="$a"
done
[[ -f "${FAKE_SSHD_LOG:-}" ]] || exit 0
while read -r ts line; do
  [[ -n "$ts" ]] || continue
  if [[ -z "$since" || "$ts" -ge "$since" ]]; then
    echo "$(date -u -d "@$ts" '+%b %e %H:%M:%S') host sshd[$RANDOM]: $line"
  fi
done <"${FAKE_SSHD_LOG:-}"
exit 0
FAKE

  cat >"$b/df" <<'FAKE'
#!/usr/bin/env bash
# Fake `df`. Answers only the question ns-maint's ESP preflight asks: how many
# MiB are free on the ESP. FAKE_ESP_FREE_MIB sets it; the default is a
# comfortable partition, so a test that is not about space does not have to care.
echo "df $*" >>"${TMP}/log/calls"
if [[ "${1:-}" == "-P" ]]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  # Column order must match `df -P -k` exactly: fs, blocks, used, AVAILABLE,
  # capacity, mount. ns-maint reads the fourth field, so a stray extra column
  # here silently turns the preflight into "0 MiB free" and every staging test
  # fails for a reason that has nothing to do with the code under test.
  printf '%s %s %s %s 40%%%% %s\n' "${TMP}/esp" "$((1024 * 1024))" "$((1024 * 1024 - ${FAKE_ESP_FREE_MIB:-4096} * 1024))" "$(( ${FAKE_ESP_FREE_MIB:-4096} * 1024 ))" "${TMP}/esp"
fi
FAKE

  cat >"$b/switch-to-configuration" <<'FAKE'
#!/usr/bin/env bash
# Fake activation. This is the injection point for every activation outcome the
# contract has to survive:
#
#   FAKE_SWITCH_CANDIDATE_EXIT   exit code when switching TO the candidate
#   FAKE_SWITCH_OLD_EXIT         exit code when switching back to the old closure
#   FAKE_SWITCH_OLD_BOOT_EXIT    exit code for the old closure's `boot` fallback
#   FAKE_SWITCH_SLEEP            seconds the candidate takes before returning
#
# Note what it does NOT do on a failed activation: it does not move the
# profile. That is the whole point — "profile unchanged" must not be the thing
# ns-maint concludes safety from.
closure="$1"
mode="$2"
echo "switch $mode $closure" >>"${FAKE_SWITCH_LOG}"
echo "switch $mode $closure" >>"${TMP}/log/calls"
case "$closure" in
*"candidate")
  echo "profile-at-activation $(readlink -f "$NM_PROFILE")" >>"${TMP}/log/calls"
  [[ "${FAKE_SWITCH_IGNORE_TERM:-0}" -eq 1 ]] && trap '' TERM
  [[ "${FAKE_SWITCH_SLEEP:-0}" -gt 0 ]] && sleep "${FAKE_SWITCH_SLEEP}"
  rc="${FAKE_SWITCH_CANDIDATE_EXIT:-0}"
  # ns-maint selects the profile before invoking activation. A successful
  # activation updates the running system for the confirmation health check.
  if [[ "$rc" -eq 0 && "$mode" != "boot" && "${FAKE_SWITCH_MOVES_PROFILE:-1}" -eq 1 ]]; then
    ln -sfn "$closure" "${TMP}/run/current-system"
    echo "profile-moved-to $closure" >>"${TMP}/log/calls"
  fi
  exit "$rc"
  ;;
esac
if [[ -n "${FAKE_STOP_DEADLINE_PID_FILE:-}" ]]; then
  sleep 1
  if [[ -r "$FAKE_STOP_DEADLINE_PID_FILE" ]]; then
    kill "$(cat "$FAKE_STOP_DEADLINE_PID_FILE")" 2>/dev/null || true
  fi
fi
[[ "${FAKE_SWITCH_OLD_SLEEP:-0}" -eq 0 ]] || sleep "$FAKE_SWITCH_OLD_SLEEP"
if [[ "$mode" == "boot" ]]; then
  exit "${FAKE_SWITCH_OLD_BOOT_EXIT:-0}"
fi
if [[ "${FAKE_SWITCH_OLD_EXIT:-0}" -eq 0 ]]; then
  ln -sfn "$closure" "${TMP}/run/current-system"
fi
exit "${FAKE_SWITCH_OLD_EXIT:-0}"
FAKE

  cat >"$b/reboot-cmd" <<'FAKE'
#!/usr/bin/env bash
# The ONLY thing that may ever record a reboot. Every test asserts this file is
# empty afterwards; see assert_no_reboot.
echo "REBOOT $*" >>"${TMP}/reboots"
echo "reboot-cmd $*" >>"${TMP}/log/calls"
exit 0
FAKE

  chmod +x "$b"/*
  local f
  for f in "$b"/*; do
    sed -i "1s|^#!.*|$shebang|" "$f"
  done
}

# ── scenario helpers ────────────────────────────────────────────────────────

# sshd_accepts PID TIME — record that sshd accepted a session from a peer at TIME.
sshd_accepts() {
  printf '%s Accepted publickey for sonny from 100.64.1.2 port %s ssh2: ED25519\n' \
    "$1" "$2" >>"$TMP/log/sshd"
}

# export SSH_CONNECTION for the confirm tests. A live SSH session sets this to
# "peer_ip peer_port local_ip local_port"; ns-maint reads the peer out of it
# rather than trusting anything the operator typed.
as_ssh_session() {
  export SSH_CONNECTION="${1:-100.64.1.2 51234 100.64.1.9 22}"
}

# wait_for_pending — block until the DETACHED activation has finished.
#
# `ns_maint activate` returns as soon as it has armed the deadline and handed the
# work to a transient system unit, so for a moment the record is `activating`.
# Any test that then races the deadline — as the watchdog and a confirmation do
# — needs the record to have settled first, or it is testing the timing of the
# fixture instead of the tool. Bounded, so a broken activation fails the test
# rather than hanging it.
wait_for_pending() {
  local until=$(( $(date +%s) + ${1:-30} ))
  while [[ "$(phase)" == "armed" || "$(phase)" == "activating" ]] && [[ "$(date +%s)" -lt "$until" ]]; do
    sleep 0.2
  done
}

# prepare_and_activate — the common path up to "awaiting confirmation".
# Candidate/old switch outcomes are whatever the caller set beforehand.
prepare_and_activate() {
  ns_maint prepare >"$TMP/log/prepare.out" 2>&1
  ns_maint activate --timeout "${1:-300}" >"$TMP/log/activate.out" 2>&1
}

t_done() {
  if [[ -n "${TMP:-}" && "$CURRENT_TEST" != "reboot invariant" && -s "$TMP/reboots" ]]; then
    _fail "reboot invariant" "$(cat "$TMP/reboots")"
  fi
  CURRENT_TEST=""
}

suite_summary() {
  local name="$1"
  printf '\n\033[1m%s: %d checks group(s), %d failure(s)\033[0m\n' "$name" "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]] || return 1
  return 0
}