#!/usr/bin/env bash
# Exercise the real updater against isolated Nix, SSH and maintenance commands.
set -o nounset -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-operations/lib/fixture.sh
source "$HERE/agent-operations/lib/fixture.sh"
SUITE_NAME=nupdate-workflow
UPDATER="$LANE_SRC/config/home/updates/nupdate.sh"
export UPDATER

new_fixture() {
  local host
  fixture_new
  unset NU_FAIL_PREPARE NU_FAIL_CONFIRM NU_REPLACE_TRANSACTION NU_FAIL_BUILD NU_ACTUAL_HOST NU_REPLACE_AFTER_ACTIVATE
  export NU_HOST=gs65 NU_IS_SERVER=0 NU_SERVER_HOST=legion
  export NU_FLAKE="$TMP/gs65" NU_REMOTE_ALIAS=legion-tailscale
  export NU_REMOTE_UPDATE="$UPDATER" NU_MAINT="$TMP/bin/ns-maint"
  export NU_BOOTED_SYSTEM="$TMP/booted-gs65"
  mkdir -p "$TMP/gs65" "$TMP/legion" "$TMP/modules-a/lib/modules/kernel" "$TMP/modules-b/lib/modules/kernel"
  for host in gs65 legion; do
    mkdir -p "$TMP/candidate-$host" "$TMP/running-$host"
    ln -s "$TMP/modules-a" "$TMP/candidate-$host/kernel-modules"
    ln -s "$TMP/modules-a" "$TMP/running-$host/kernel-modules"
    ln -s "$TMP/running-$host" "$TMP/booted-$host"
  done
  printf 'idle' >"$TMP/phase"
  printf 'tx-20261006T180000Z-abcdef' >"$TMP/txid"
  : >"$TMP/log/calls"
  fake hostname <<'FAKE'
printf '%s\n' "${NU_ACTUAL_HOST:-$NU_HOST}"
FAKE
  fake sudo <<'FAKE'
printf '%s sudo %s\n' "$NU_HOST" "$*" >>"$TMP/log/calls"
exec "$@"
FAKE
  fake nix <<'FAKE'
printf '%s nix %s\n' "$NU_HOST" "$*" >>"$TMP/log/calls"
case "$*" in
  *'flake update'*) exit 0 ;;
  *build*) [[ "${NU_FAIL_BUILD:-0}" == 0 ]] || exit 9; printf '%s\n' "$TMP/candidate-$NU_HOST" ;;
  *) exit 2 ;;
esac
FAKE
  fake nh <<'FAKE'
printf '%s nh %s\n' "$NU_HOST" "$*" >>"$TMP/log/calls"
FAKE
  fake ns-maint <<'FAKE'
printf '%s ns-maint %s\n' "$NU_HOST" "$*" >>"$TMP/log/calls"
case "$1" in
  prepare) [[ "${NU_FAIL_PREPARE:-0}" == 0 ]] || exit 7; printf prepared >"$TMP/phase" ;;
  activate)
    printf 'activate: armed txid %s\n' "$(cat "$TMP/txid")"
    printf awaiting-confirm >"$TMP/phase"
    [[ "${NU_REPLACE_AFTER_ACTIVATE:-0}" == 0 ]] || printf 'tx-20261006T190000Z-fedcba' >"$TMP/txid"
    ;;
  stage) printf staged >"$TMP/phase" ;;
  status) jq -n --arg phase "$(cat "$TMP/phase")" --arg txid "$(cat "$TMP/txid")" --arg candidate "$TMP/candidate-legion" '{phase:$phase,txid:$txid,candidate:$candidate}' ;;
  confirm) [[ "$2" == "$(cat "$TMP/txid")" ]] || exit 8; printf confirmed >"$TMP/phase" ;;
  *) exit 2 ;;
esac
FAKE
fake ssh <<'FAKE'
printf '%s ssh %s\n' "$NU_HOST" "$*" >>"$TMP/log/calls"
[[ "$1" == -t ]] || exit 20
shift
while [[ "${1:-}" == -o ]]; do shift 2; done
[[ "$1" == legion-tailscale ]] || exit 21
shift 2
if [[ "$*" == *--confirm* ]]; then
  [[ "${NU_FAIL_CONFIRM:-0}" == 0 ]] || exit 255
  if [[ "${NU_REPLACE_TRANSACTION:-0}" == 1 ]]; then
    printf 'tx-20261006T190000Z-fedcba' >"$TMP/txid"
  fi
fi
NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion" \
  bash "$UPDATER" "$@"
FAKE
}

run_update() {
  bash "$UPDATER" "$@" >"$TMP/log/output" 2>&1 && rc=0 || rc=$?
  out="$(cat "$TMP/log/output")"
  calls="$(cat "$TMP/log/calls")"
}

_t_start "Stealth updates only nixpkgs and switches the exact built closure"
new_fixture
run_update
assert_eq 0 "$rc" 'local update succeeds'
assert_contains "$calls" "flake update --flake $TMP/gs65 nixpkgs" 'only nixpkgs is updated'
assert_contains "$calls" "gs65 nh os switch $TMP/candidate-gs65" 'the checked closure is activated'
assert_not_contains "$calls" 'ssh ' 'local update stays local'
assert_not_contains "$calls" 'ns-maint activate' 'desktop uses its normal activation path'

_t_start "Legion local update keeps guarded activation and explicit confirmation"
new_fixture
export NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion"
run_update
assert_eq 0 "$rc" 'server update succeeds'
assert_contains "$calls" 'ns-maint prepare --update-input nixpkgs' 'build happens through maintenance'
assert_contains "$calls" 'ns-maint activate --timeout 20m' 'activation retains the deadline'
assert_not_contains "$calls" 'ns-maint confirm' 'local server update awaits operator confirmation'

_t_start "remote Legion update uses Tailscale and never upgrades Stealth"
new_fixture
run_update legion
assert_eq 0 "$rc" 'remote update succeeds'
assert_contains "$calls" 'ssh -t legion-tailscale' 'the usable tailnet alias is selected'
assert_contains "$calls" 'legion ns-maint activate' 'Legion activates'
assert_not_contains "$calls" 'gs65 nix ' 'Stealth input stays unchanged'

_t_start "both confirms the exact Legion transaction over a fresh connection before Stealth"
new_fixture
run_update both
assert_eq 0 "$rc" 'both updates succeed'
assert_eq confirmed "$(cat "$TMP/phase")" 'Legion is confirmed'
assert_eq 2 "$(grep -c 'gs65 ssh ' "$TMP/log/calls")" 'update and confirm use separate connections'
assert_contains "$calls" 'ns-maint confirm tx-20261006T180000Z-abcdef' 'confirmation is bound to the created transaction'
confirm_line="$(grep -n 'legion ns-maint confirm' "$TMP/log/calls" | cut -d: -f1)"
local_line="$(grep -n 'gs65 nix .*flake update' "$TMP/log/calls" | cut -d: -f1)"
[[ -n "$confirm_line" && -n "$local_line" && "$confirm_line" -lt "$local_line" ]] && order=ok || order=wrong
assert_eq ok "$order" 'confirmation precedes the local update'

_t_start "a failed Legion prepare leaves Stealth untouched"
new_fixture
export NU_FAIL_PREPARE=1
run_update both
assert_ne 0 "$rc" 'remote failure is propagated'
assert_not_contains "$calls" 'gs65 nix ' 'local update is not attempted'
assert_not_contains "$calls" 'ns-maint activate' 'a failed prepare never activates'

_t_start "a failed fresh connection leaves Legion pending and Stealth untouched"
new_fixture
export NU_FAIL_CONFIRM=1
run_update both
assert_ne 0 "$rc" 'connection failure is propagated'
assert_eq awaiting-confirm "$(cat "$TMP/phase")" 'rollback remains armed'
assert_not_contains "$calls" 'gs65 nix ' 'the local update does not consume the confirmation window'

_t_start "a superseding transaction cannot be accidentally confirmed"
new_fixture
export NU_REPLACE_TRANSACTION=1
run_update both
assert_ne 0 "$rc" 'transaction replacement is refused'
assert_not_contains "$calls" 'ns-maint confirm ' 'a newer transaction is not blessed'
assert_not_contains "$calls" 'gs65 nix ' 'local update is not attempted'

_t_start "explicit nconfirm routes through a fresh connection"
new_fixture
printf awaiting-confirm >"$TMP/phase"
run_update --confirm legion
assert_eq 0 "$rc" 'remote confirmation succeeds'
assert_eq confirmed "$(cat "$TMP/phase")" 'pending transaction becomes permanent'
assert_contains "$calls" 'gs65 ssh -t -o ControlPath=none -o ControlMaster=no legion-tailscale' 'confirmation checks a new connection'

_t_start "confirmation forces a new transport even with SSH multiplexing configured"
new_fixture
printf awaiting-confirm >"$TMP/phase"
run_update --confirm legion
assert_eq 0 "$rc" 'remote confirmation works with explicit transport options'
assert_contains "$calls" '-o ControlPath=none' 'existing shared connections are not reused'
assert_contains "$calls" '-o ControlMaster=no' 'confirmation is not a multiplexing client'

_t_start "the reported transaction must be the one activation actually created"
new_fixture
export NU_REPLACE_AFTER_ACTIVATE=1
run_update both
assert_ne 0 "$rc" 'replacement before reporting is refused'
assert_not_contains "$calls" 'ns-maint confirm ' 'a superseding activation is not confirmed'
assert_not_contains "$calls" 'gs65 nix ' 'Stealth stays untouched'

_t_start "invalid transaction text cannot reach the remote shell"
new_fixture
# shellcheck disable=SC2016
run_update --confirm --txid '$(touch unwanted)' legion
assert_ne 0 "$rc" 'invalid ID is rejected'
assert_not_contains "$calls" 'ssh ' 'invalid ID never goes over SSH'

_t_start "kernel updates stage a boot generation on each host without rebooting"
for host in gs65 legion; do
  new_fixture
  ln -sfn "$TMP/modules-b" "$TMP/candidate-$host/kernel-modules"
  if [[ "$host" == legion ]]; then
    export NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion"
  fi
  run_update
  assert_eq 0 "$rc" "$host stages successfully"
  assert_contains "$out" 'reboot' "$host explains that a planned reboot is needed"
  assert_not_contains "$calls" 'reboot ' "$host never reboots automatically"
  assert_not_contains "$calls" 'os switch' "$host does not switch mismatched userspace"
  assert_not_contains "$calls" 'ns-maint activate' "$host does not arm an incompatible activation"
  if [[ "$host" == legion ]]; then
    assert_contains "$calls" 'ns-maint stage' 'server stages through maintenance'
  else
    assert_contains "$calls" "nh os boot $TMP/candidate-gs65" 'desktop stages the checked closure'
  fi
done

_t_start "both handles a staged Legion update without trying to confirm it"
new_fixture
ln -sfn "$TMP/modules-b" "$TMP/candidate-legion/kernel-modules"
run_update both
assert_eq 0 "$rc" 'both succeeds with a staged server generation'
assert_eq staged "$(cat "$TMP/phase")" 'Legion stays staged for its planned reboot'
assert_not_contains "$calls" 'ns-maint confirm' 'no live transaction is confirmed'
assert_contains "$calls" 'gs65 nh os switch' 'Stealth still updates'

_t_start "invalid targets and wrong-host use fail before any mutation"
new_fixture
run_update wrong-host
assert_ne 0 "$rc" 'unknown target is rejected'
assert_eq '' "$calls" 'unknown target runs no tools'
run_update --on-legion
assert_ne 0 "$rc" 'remote command cannot run on Stealth accidentally'
assert_eq '' "$calls" 'host mismatch runs no tools'
export NU_HOST=legion NU_IS_SERVER=1
run_update both
assert_ne 0 "$rc" 'both must be launched on Stealth'
assert_eq '' "$calls" 'both never updates Legion twice'

_t_start "an uninspectable kernel is refused before activation"
new_fixture
rm "$TMP/candidate-gs65/kernel-modules"
run_update
assert_ne 0 "$rc" 'missing kernel metadata is an error'
assert_not_contains "$calls" 'nh os ' 'unknown kernel never activates'

_t_start "Legion applies existing dotfiles without updating inputs"
new_fixture
export NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion"
run_update --apply --offline
assert_eq 0 "$rc" 'offline apply succeeds'
assert_contains "$calls" 'ns-maint prepare --offline' 'offline build uses maintenance'
assert_not_contains "$calls" 'update-input' 'applying config keeps the lock file unchanged'
assert_contains "$calls" 'ns-maint activate --timeout 20m' 'apply keeps guarded activation'

_t_start "Legion config apply stages kernel changes instead of attempting a live switch"
new_fixture
export NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion"
ln -sfn "$TMP/modules-b" "$TMP/candidate-legion/kernel-modules"
run_update --apply
assert_eq 0 "$rc" 'kernel-changing apply stages successfully'
assert_contains "$calls" 'ns-maint stage' 'the candidate is staged'
assert_not_contains "$calls" 'ns-maint activate' 'no incompatible live activation'

_t_start "Legion can deliberately update one named input"
new_fixture
export NU_HOST=legion NU_IS_SERVER=1 NU_FLAKE="$TMP/legion" NU_BOOTED_SYSTEM="$TMP/booted-legion"
run_update --input herdr
assert_eq 0 "$rc" 'named input update succeeds'
assert_contains "$calls" 'ns-maint prepare --update-input herdr' 'only the requested input changes'

_t_start "new server options reject ambiguous or desktop use before mutation"
new_fixture
for args in '--apply' '--offline' '--input herdr'; do
  read -r -a options <<<"$args"
  run_update "${options[@]}"
  assert_ne 0 "$rc" 'server options are not applied to Stealth'
  assert_eq '' "$calls" 'invalid use makes no changes'
done
export NU_HOST=legion NU_IS_SERVER=1
run_update --apply --input herdr
assert_ne 0 "$rc" 'apply cannot also update an input'
assert_eq '' "$calls" 'ambiguous request makes no changes'
run_update --offline
assert_ne 0 "$rc" 'offline requires apply'
assert_eq '' "$calls" 'offline cannot update inputs'

fixture_free
summary
