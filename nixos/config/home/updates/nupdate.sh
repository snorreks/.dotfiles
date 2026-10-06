#!/usr/bin/env bash
# nupdate/nconfirm: local upgrades and explicit Legion updates over Tailscale.
set -euo pipefail

action=update
target=local
target_given=0
expected_txid=
on_legion=0
report=0
capture=
trap '[[ -z "$capture" ]] || rm -f -- "$capture"' EXIT

fail() { printf 'nupdate: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: nupdate [local|legion|both]
       nconfirm [local|legion]

Update only nixpkgs, build, then apply. Kernel changes are staged for a
planned reboot. Run both on Stealth: confirm Legion over a fresh connection
before updating Stealth. Each host uses its existing dotfiles checkout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) action=confirm ;;
    --on-legion) on_legion=1 ;;
    --report) report=1 ;;
    --txid)
      [[ $# -ge 2 ]] || fail '--txid needs a transaction ID'
      expected_txid="$2"; shift
      ;;
    --help|-h) usage; exit 0 ;;
    local|legion|both|gs65)
      [[ "$target_given" -eq 0 ]] || fail 'give exactly one target'
      target="$1"; target_given=1
      ;;
    *) fail "unknown target or option '$1' (use nupdate --help)" ;;
  esac
  shift
done

: "${NU_HOST:?}" "${NU_IS_SERVER:?}" "${NU_FLAKE:?}"
: "${NU_REMOTE_ALIAS:?}" "${NU_REMOTE_UPDATE:?}"
NU_MAINT="${NU_MAINT:-/run/current-system/sw/bin/ns-maint}"
NU_BOOTED_SYSTEM="${NU_BOOTED_SYSTEM:-/run/booted-system}"
[[ "$(hostname -s)" == "$NU_HOST" ]] || fail 'this updater was built for a different host'
if [[ "$on_legion" -eq 1 ]]; then
  [[ "$NU_HOST" == legion && "$NU_IS_SERVER" == 1 ]] || fail 'remote command must run on Legion in server mode'
  target=local
fi
if [[ "$target" == both ]]; then
  [[ "$action" == update && "$NU_HOST" == gs65 ]] || fail 'run nupdate both from Stealth (gs65)'
fi
if [[ "$target" == gs65 ]]; then
  [[ "$NU_HOST" == gs65 ]] || fail 'run the Stealth update from its own terminal'
  target=local
fi
if [[ "$target" == legion && "$NU_HOST" == legion ]]; then target=local; fi

valid_txid() { [[ "$1" =~ ^tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]; }
[[ -z "$expected_txid" ]] || valid_txid "$expected_txid" || fail 'invalid expected transaction ID'
read_state() { sudo "$NU_MAINT" status --json; }
kernel_changed() {
  local candidate="$1" candidate_modules booted_modules
  candidate_modules="$(readlink -e "$candidate/kernel-modules")" || fail 'cannot inspect the candidate kernel; nothing activated'
  booted_modules="$(readlink -e "$NU_BOOTED_SYSTEM/kernel-modules")" || fail 'cannot inspect the booted kernel; nothing activated'
  [[ -d "$candidate_modules/lib/modules" && -d "$booted_modules/lib/modules" ]] || fail 'kernel module metadata is missing; nothing activated'
  [[ "$candidate_modules" != "$booted_modules" ]]
}

confirm_local() {
  [[ "$NU_IS_SERVER" == 1 ]] || fail 'use nconfirm legion from Stealth'
  local state phase txid
  state="$(read_state)"
  phase="$(jq -er '.phase' <<<"$state")"
  [[ "$phase" == awaiting-confirm || "$phase" == reconciled-booted ]] || fail "nothing awaits confirmation (phase $phase)"
  txid="$(jq -er '.txid' <<<"$state")"
  valid_txid "$txid" || fail 'invalid transaction ID in maintenance state'
  [[ -z "$expected_txid" || "$expected_txid" == "$txid" ]] || fail 'transaction changed since the update; inspect sudo ns-maint status'
  sudo "$NU_MAINT" confirm "$txid"
}

update_local() {
  printf 'Updating %s: nixpkgs, using %s\n' "$NU_HOST" "$NU_FLAKE"
  local candidate state txid armed_txid='' line
  if [[ "$NU_IS_SERVER" == 1 ]]; then
    sudo "$NU_MAINT" prepare --update-input nixpkgs
    state="$(read_state)"
    candidate="$(jq -er '.candidate' <<<"$state")"
    if kernel_changed "$candidate"; then
      sudo "$NU_MAINT" stage
      printf 'Legion update staged. Choose a reboot window, then run sudo ns-maint reboot --yes.\n'
      [[ "$report" -eq 0 ]] || printf 'nupdate-result: staged\n'
      return 0
    fi
    capture="$(mktemp)"
    sudo "$NU_MAINT" activate --timeout 20m | tee "$capture"
    while IFS= read -r line; do
      line="${line%$'\r'}"
      case "$line" in 'activate: armed txid '*) armed_txid="${line#activate: armed txid }" ;; esac
    done <"$capture"
    valid_txid "$armed_txid" || fail 'activation returned no valid transaction ID'
    state="$(read_state)"
    [[ "$(jq -er '.phase' <<<"$state")" == awaiting-confirm ]] || fail 'activation is not awaiting confirmation; inspect sudo ns-maint status'
    txid="$(jq -er '.txid' <<<"$state")"
    [[ "$txid" == "$armed_txid" && "$(jq -er '.candidate' <<<"$state")" == "$candidate" ]] || fail 'transaction changed during activation; inspect sudo ns-maint status'
    printf 'Check access from a new session, then run nconfirm legion.\n'
    [[ "$report" -eq 0 ]] || printf 'nupdate-txid: %s\n' "$txid"
  else
    nix --extra-experimental-features 'nix-command flakes' flake update --flake "$NU_FLAKE" nixpkgs
    candidate="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths "$NU_FLAKE#nixosConfigurations.$NU_HOST.config.system.build.toplevel")"
    if kernel_changed "$candidate"; then
      nh os boot "$candidate"
      printf '%s update staged. Choose a reboot window to load the new kernel.\n' "$NU_HOST"
    else
      nh os switch "$candidate"
    fi
  fi
}

remote_confirm() {
  local -a args=(--confirm --on-legion)
  [[ -z "$expected_txid" ]] || args+=(--txid "$expected_txid")
  ssh -t -o ControlPath=none -o ControlMaster=no "$NU_REMOTE_ALIAS" "$NU_REMOTE_UPDATE" "${args[@]}"
}

update_both() {
  local line result='' txid
  capture="$(mktemp)"
  # Stream the remote build and sudo prompt. Capture only to recover its exact
  # transaction ID; the fresh confirmation must never bless a newer update.
  ssh -t "$NU_REMOTE_ALIAS" "$NU_REMOTE_UPDATE" --on-legion --report | tee "$capture"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      'nupdate-txid: '*|'nupdate-result: staged') result="$line" ;;
    esac
  done <"$capture"
  if [[ "$result" == 'nupdate-result: staged' ]]; then
    printf 'Legion is staged for its planned reboot. Updating Stealth now.\n'
  else
    txid="${result#nupdate-txid: }"
    valid_txid "$txid" || fail 'Legion returned no valid transaction; Stealth has not been updated'
    expected_txid="$txid"
    remote_confirm
  fi
  update_local
}

case "$target:$action" in
  local:confirm) confirm_local ;;
  legion:confirm) remote_confirm ;;
  local:update) update_local ;;
  legion:update) ssh -t "$NU_REMOTE_ALIAS" "$NU_REMOTE_UPDATE" --on-legion ;;
  both:update) update_both ;;
  *) fail 'unsupported action; use nupdate --help' ;;
esac
