#!/usr/bin/env bash
# nixos/tests/server-foundation/boot-health.sh — the LOCAL gate in front of
# systemd-boot's boot blessing.
#
# The property that matters most here is a negative one and cannot be tested by
# making the script succeed: it must PASS on a machine with no network at all.
# So this suite does not stub "the network is up" — it makes every network tool
# on PATH record that it was called, and then asserts none of them ever was.
#
# Fakes are disposable (a mktemp tree), nothing here touches /sys, /boot, a real
# systemd, a real bootloader or a real machine, and nothing here reboots.
#
# Run directly:  bash nixos/tests/server-foundation/boot-health.sh
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HEALTH="$ROOT/config/system/boot/health.sh"

printf '\n\033[1mserver-foundation — local boot health (offline-capable)\033[0m\n'

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

t_start() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %s\n' "$1"
}
_fail() {
  printf '    FAIL %s: %s\n' "${CURRENT_TEST:-<none>}" "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}
t_done() {
  [[ "$TESTS_FAILED" -gt 0 ]] && return 0
  printf '    ok   %s\n' "$CURRENT_TEST"
  CURRENT_TEST=""
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then return 0; fi
  _fail "$1: expected '$2', got '$3'"
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then return 0; fi
  _fail "$1: expected the output to contain '$3' — got: $(printf '%s' "$2" | tr '\n' '|')"
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then return 0; fi
  _fail "$1: did NOT expect '$3' — got: $(printf '%s' "$2" | tr '\n' '|')"
}
assert_file() {
  if [[ -e "$2" ]]; then return 0; fi
  _fail "$1: expected $2 to exist"
}

# ── the fixture ──────────────────────────────────────────────────────────────
# $TMP/bin holds the fakes the script calls BY NAME (findmnt, bootctl, …) and a
# tripwire directory whose every command records the fact that it was called.
TMP=""
setup() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/boot-health-test.XXXXXX")"
  mkdir -p "$TMP/bin" "$TMP/net" "$TMP/run"
  # Every fake is written with a hardcoded interpreter path rather than
  # `#!/usr/bin/env bash`. A nix build sandbox has a coreutils-only root: /bin/sh
  # exists, /usr/bin/env does not, and a fake that cannot find its interpreter
  # fails with "bad interpreter" — which then looks like the tool under test
  # being broken rather than the harness. (Same reason, same fix, as the fakes in
  # tests/lib/harness.sh.)
  : >"$TMP/touched"

  # ── The tripwires ──────────────────────────────────────────────────────────
  # Every command this script has NO business running: the network (which would
  # couple the blessing to an uplink) and the destructive/local-state ones
  # (reboot, remount). Each SUCCEEDS, so a check that used one would still pass
  # — and is caught only by the assertion that the tripwire file is empty. That
  # is the property worth protecting: a passing test here must mean "it decided
  # using local facts", not "it decided and nobody looked".
  for c in ping ping6 getent curl wget dig host nslookup resolvectl tailscale \
    ip systemctl-networkd systemctl-networkd-wait-online reboot \
    systemctl-reboot shutdown mount umount fsck swapon bootctl-reboot; do
    cat >"$TMP/bin/$c" <<'FAKE'
#!/usr/bin/env bash
echo "$0 $*" >>"${TMP}/touched"
exit 0
FAKE
    chmod +x "$TMP/bin/$c"
  done

  # ── findmnt ────────────────────────────────────────────────────────────────
  cat >"$TMP/bin/findmnt" <<'FAKE'
#!/usr/bin/env bash
echo "findmnt $*" >>"${TMP}/calls"
printf '%s\n' "${FAKE_ROOT_OPTIONS:-rw,relatime,errors=remount-ro,subvol=/,subvol=/@}"
FAKE

  # ── bootctl ────────────────────────────────────────────────────────────────
  cat >"$TMP/bin/bootctl" <<'FAKE'
#!/usr/bin/env bash
echo "bootctl $*" >>"${TMP}/calls"
case "${1:-}" in
  --print-boot-path)
    if [[ "${FAKE_BOOTCTL_FOUND:-1}" == "1" ]]; then
      printf '/boot\n'
      exit 0
    fi
    printf 'Failed to open /boot/loader/loader.conf: Permission denied\n' >&2
    exit 1
    ;;
  *)
    printf 'unexpected bootctl invocation\n' >&2
    exit 1
    ;;
esac
FAKE

  # ── systemctl ──────────────────────────────────────────────────────────────
  # `is-active <unit>` answers from a fixture map, so a test can make ONE unit
  # failed — or merely still activating — without touching the others.
  # FAKE_UNIT_STATES is a space-separated list of unit=state pairs.
  cat >"$TMP/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >>"${TMP}/calls"
unit="${2:-}"
if [[ "${1:-}" != "is-active" ]]; then exit 0; fi
for pair in ${FAKE_UNIT_STATES:-local-fs.target=active systemd-modules-load.service=active}; do
  if [[ "${pair%%=*}" == "$unit" ]]; then
    printf '%s\n' "${pair#*=}"
    [[ "${pair#*=}" == "active" ]] && exit 0
    exit 3
  fi
done
printf 'inactive\n'
exit 3
FAKE

  # Give every fake a real interpreter path. Written with a literal
  # `#!/usr/bin/env bash` above and patched here, because a nix build sandbox has
  # a coreutils-only root: /bin/sh exists, /usr/bin/env does not, and a fake that
  # cannot find its interpreter fails with "bad interpreter" — which reads as the
  # tool under test being broken rather than the harness. Same reason, same fix
  # as tests/lib/harness.sh.
  local fake
  for fake in "$TMP/bin"/*; do
    sed -i "1s|^#!.*|#!$(command -v bash)|" "$fake"
  done

  chmod +x "$TMP/bin"/*
  : >"$TMP/calls"
  export TMP

  # The two generation symlinks the script compares.
  mkdir -p "$TMP/run/generation-a"
  ln -sfn "$TMP/run/generation-a" "$TMP/run/current-system"
  ln -sfn "$TMP/run/generation-a" "$TMP/run/booted-system"
}

teardown() {
  [[ -n "$TMP" && -d "$TMP" && "${KEEP_TMP:-0}" != "1" ]] && rm -rf "$TMP"
  TMP=""
  return 0
}

run_health() {
  PATH="$TMP/bin:$PATH" \
    NM_FINDMNT="$TMP/bin/findmnt" \
    NM_SYSTEMCTL="$TMP/bin/systemctl" \
    NM_BOOTCTL="$TMP/bin/bootctl" \
    NM_CURRENT_SYSTEM="$TMP/run/current-system" \
    NM_BOOTED_SYSTEM="$TMP/run/booted-system" \
    NM_ROOT_DEVICE="/" \
    NM_BOOT_CRITICAL_UNITS="${CRITICAL_UNITS:-local-fs.target systemd-modules-load.service}" \
    NM_BOOT_READY_TIMEOUT="${READY_TIMEOUT:-0}" \
    bash "$HEALTH" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
t_start "a healthy offline boot passes, and never touches the network"
setup
out="$(run_health)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_contains "it says it can be blessed" "$out" "can be blessed"
assert_eq "no network tool was called" "" "$(cat "$TMP/touched")"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "every check still passes with an unreachable uplink"
setup
# Same fixture, and explicitly: there is no network device in this tree, no
# resolver, no tailscale — and the answer must be identical. If a check needed
# the internet this is where it would fail.
out="$(run_health)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_eq "still nothing reached the network" "" "$(cat "$TMP/touched")"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a read-only root is not blessed"
setup
export FAKE_ROOT_OPTIONS="ro,relatime,subvol=/"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero() { [[ "$2" != "0" ]] && return 0; _fail "$1: expected a non-zero exit, got $2"; }
assert_ne_zero "exit status" "$rc"
assert_contains "it names the reason" "$out" "read-only"
assert_contains "it says it is not blessing" "$out" "NOT blessed"
unset FAKE_ROOT_OPTIONS
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "an unreadable mount table is not blessed"
setup
cat >"$TMP/bin/findmnt" <<'FAKE'
#!/usr/bin/env bash
echo "findmnt $*" >>"${TMP}/calls"
exit 1
FAKE
sed -i "1s|^#!.*|#!$(command -v bash)|" "$TMP/bin/findmnt"
chmod +x "$TMP/bin/findmnt"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it says what it could not read" "$out" "mount options"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a machine switched under itself is not blessed"
setup
mkdir -p "$TMP/run/generation-b"
ln -sfn "$TMP/run/generation-b" "$TMP/run/booted-system"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it explains the mismatch" "$out" "switched under itself"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "an absent booted-system is not blessed"
setup
rm -f "$TMP/run/booted-system"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it says what is missing" "$out" "not running a NixOS generation"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "one failed critical unit fails the whole gate"
setup
export FAKE_UNIT_STATES="local-fs.target=active systemd-modules-load.service=failed"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it names the unit" "$out" "systemd-modules-load.service"
unset FAKE_UNIT_STATES
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "an indefinitely activating critical unit is not blessed"
setup
export FAKE_UNIT_STATES="local-fs.target=activating systemd-modules-load.service=active"
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "startup is not readiness" "$out" "not ready"
unset FAKE_UNIT_STATES
teardown
t_done

t_start "local SSH readiness is required even when the WAN is down"
setup
export CRITICAL_UNITS='local-fs.target sshd.service'
export FAKE_UNIT_STATES='local-fs.target=active sshd.service=failed'
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "failed listener" "$rc"
assert_contains "SSH failure is visible" "$out" 'sshd.service'
export FAKE_UNIT_STATES='local-fs.target=active sshd.service=active'
out="$(run_health)" && rc=0 || rc=$?
assert_eq "local listener works without WAN" 0 "$rc"
unset CRITICAL_UNITS FAKE_UNIT_STATES
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "no bootloader means no blessing, because there is nothing to fall back to"
setup
export FAKE_BOOTCTL_FOUND=0
out="$(run_health)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it explains the missing fallback" "$out" "no boot counting to fall back to"
unset FAKE_BOOTCTL_FOUND
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a healthy boot touches nothing but findmnt, systemctl and bootctl"
setup
out="$(run_health)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_eq "no network call, no reboot, no mount" "" "$(cat "$TMP/touched")"
# And the log shows it consulted exactly the three local things it should have.
for expected in "findmnt" "systemctl is-active local-fs.target" "bootctl --print-boot-path"; do
  assert_contains "it consulted $expected" "$(cat "$TMP/calls")" "$expected"
done
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf '\n\033[31mboot-health: %d assertion(s) failed\033[0m\n' "$TESTS_FAILED"
  exit 1
fi
printf '\n\033[32mboot-health: all %d checks passed\033[0m\n' "$TESTS_RUN"
