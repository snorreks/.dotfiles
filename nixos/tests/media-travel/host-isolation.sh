#!/usr/bin/env bash
# nixos/tests/media-travel/host-isolation.sh
#
# Audit checklist: "Assert host management/playback and Collie443 survive every
# VPN failure", "unauthorised identity/LAN/admin access", "server-role settings
# absent on MSI".
#
# The VPN failure cannot touch the host at all, and the way to make that
# testable is to check the SHAPE of what the media lane contributes rather than
# trying to induce a tunnel failure on a machine that has no tunnel. Three
# facts carry it:
#
#   1. No media unit is installed unless it is asked for, and no media
#      directory is created unless it is asked for. An always-declared unit
#      would be a unit that starts with no configuration on a host that never
#      wanted it — which is the failure that hides.
#   2. Collie keeps tailnet HTTPS 443, and nothing else claims it.
#   3. The media lane adds no global firewall port and no firewall interface.
#      (Its only host firewall rule, when enabled, is an interface-scoped INPUT
#      port inside the namespace module — an INPUT rule, and never OUTPUT.
#      There is no host OUTPUT policy to change, which is the point.)
#
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

printf '=== host-isolation ===\n'

if ! command -v nix >/dev/null 2>&1; then
  printf 'no nix on PATH — cannot evaluate the hosts.\n' >&2
  exit 1
fi

# `nix eval` writes a bare "trace: " line to stderr on success as well as
# failure, so the two are kept apart and only stdout is parsed. Filtering the
# marker explicitly is clearer than relying on the reader noticing it.
facts() {
  timeout 900 nix eval --raw --impure \
    --expr "builtins.toJSON ((import $HERE/lib/host-facts.nix) \"$1\")" \
    2>"$FIXTURE_TMP/facts-$1.err" |
    grep -v '^trace:$'
}

LEGION="$(facts legion)"
GS65="$(facts gs65)"

# Validated with jq rather than a bash glob: the payload is a single line of
# JSON, and asking the JSON parser whether it parsed is a better signal than a
# pattern match that can silently pass on truncated output.
if ! printf '%s' "$LEGION" | jq -e 'has("collieServeUnit")' >/dev/null 2>&1; then
  printf 'could not evaluate the Legion configuration:\n' >&2
  tail -20 "$FIXTURE_TMP/facts-legion.err" >&2
  exit 1
fi

# -c (compact): the default pretty-printer emits arrays across several lines,
# which then fail every `== "[...]"` comparison below in a way that looks like a
# policy violation rather than a formatting difference.
json() { printf '%s' "$2" | jq -c -r "$1"; }

# ── 1. Nothing media-related exists until it is asked for ──────────────────
# Two explicit checks rather than a `for host:$json` loop: a colon-separated
# loop SPLITS the payload on every colon inside the JSON, which silently
# produces garbage and reports it as a policy violation.
for host in legion gs65; do
  case "$host" in
    legion) f="$LEGION" ;;
    *) f="$GS65" ;;
  esac
  if [[ "$(json '.mediaUnitsPresent' "$f")" == "[]" ]]; then
    ok "$host: no media units installed"
  else
    bad "$host: media units present with everything off" "$(json '.mediaUnitsPresent' "$f")"
  fi
  if [[ "$(json '.mediaTmpfiles' "$f")" == "[]" ]]; then
    ok "$host: no media directories created"
  else
    bad "$host: media tmpfiles rules created with everything off" "$(json '.mediaTmpfiles' "$f")"
  fi
done

# ── 2. Collie keeps HTTPS 443 ──────────────────────────────────────────────
if [[ "$(json '.collieServeUnit' "$LEGION")" == "true" ]]; then
  ok "Collie's Serve unit is installed on the Legion"
else
  bad "Collie's Serve unit is missing" "443 belongs to Collie and must survive this lane"
fi
collie_exec="$(json '.collieServeExec' "$LEGION")"
if [[ "$collie_exec" == *"--https=443"* && "$collie_exec" == *"127.0.0.1:8787"* ]]; then
  ok "Collie still maps HTTPS 443 to its loopback port"
else
  bad "Collie's Serve mapping changed" "$collie_exec"
fi
# `tailscale serve reset` erases every mapping on the node. It must appear
# nowhere: not in Collie's unit, not in any unit this lane added.
if printf '%s' "$LEGION" | grep -q "serve reset"; then
  bad "'tailscale serve reset' appears in the evaluated configuration" "it erases Collie's 443 too"
else
  ok "no unit runs 'tailscale serve reset'"
fi
if [[ "$(json '.collieServeUnit' "$GS65")" == "false" ]]; then
  ok "the travel laptop has no Collie mapping (it is a server-side service)"
else
  bad "Collie's Serve unit leaked onto the travel laptop" "server-role settings must not appear on the MSI"
fi

# ── 3. The media lane adds no global firewall surface ──────────────────────
# The Legion's pre-existing allow list is 22 + the gaming ports, and the
# firewall interfaces are the pre-existing podman0. Neither may gain an entry.
if [[ "$(json '.allowedTCPPorts' "$LEGION")" == '["22","27015","27036","27037","27040"]' ]]; then
  ok "Legion global allowed TCP ports are unchanged"
else
  bad "Legion's global firewall allow list changed" "$(json '.allowedTCPPorts' "$LEGION")"
fi
if [[ "$(json '.firewallInterfaces' "$LEGION")" == '["podman0"]' ]]; then
  ok "no media firewall interface was added"
else
  bad "a media firewall interface exists with everything off" "$(json '.firewallInterfaces' "$LEGION")"
fi

# ── 4. The travel builder is pinned to 2222 / ssh-ng ──────────────────────
machines="$(json '.buildMachines' "$GS65")"
if [[ "$machines" == *"legion -p 2222"* ]]; then
  ok "the remote builder is pinned to port 2222, not 22"
else
  bad "the builder is not pinned to 2222" "$machines — port 22 is Tailscale SSH and ignores authorized_keys"
fi
if [[ "$machines" == *'"ssh-ng"'* ]]; then
  ok "the builder protocol is ssh-ng (not builtin, which would ignore the port)"
else
  bad "unexpected builder protocol" "$machines"
fi
# The builder logs in as a trusted user on the server. Stating the privilege
# accurately matters: this is root-equivalent, and the test asserts it is the
# operator, not a silently-widened sudo.
if [[ "$(json '.trustedUsers' "$LEGION")" == *'"sonny"'* ]]; then
  ok "the builder's account is in the Legion's trusted-users (root-equivalent, as documented)"
else
  bad "the builder's account is not in trusted-users" "$(json '.trustedUsers' "$LEGION")"
fi

# ── 5. Travel SSH aliases are present, pinned-state honestly reported ──────
sshcfg="$(json '.sshExtraConfig' "$GS65")"
if grep -q "Host legion$" <<<"$sshcfg"; then
  ok "the 'legion' alias exists on the travel laptop"
else
  bad "the 'legion' SSH alias is missing"
fi
if grep -q "Host legion-tailscale" <<<"$sshcfg"; then
  ok "the 'legion-tailscale' alias exists (the Tailscale SSH path)"
else
  bad "the 'legion-tailscale' alias is missing"
fi
# The builder must point at 2222; the Tailscale alias at 22, and must NOT offer
# a key file (Tailscale SSH authenticates by identity, not by key).
if awk '/^Host legion$/{f=1;next} /^Host /{f=0} f&&/Port 2222/{found=1} END{exit !found}' <<<"$sshcfg"; then
  ok "the 'legion' alias uses port 2222"
else
  bad "the 'legion' alias does not use port 2222"
fi
# The Tailscale SSH alias must not offer a key file: Tailscale SSH
# authenticates with a TAILSCALE IDENTITY, so a client that offers a key waits
# for a handshake that will not authenticate it, and then reports a misleading
# error. Split the block out with awk (it prints only the matching range) and
# then grep it, rather than trying to express "absent" as an awk exit status.
ts_block="$(awk '/^Host legion-tailscale$/{f=1} f&&/^Host /&&!/legion-tailscale/{exit} f' <<<"$sshcfg")"
# Comment lines are stripped first: the generated config explains WHY there is
# no IdentityFile, and grepping the raw block would match that explanation and
# report the opposite of what is true.
if grep -v '^[[:space:]]*#' <<<"$ts_block" | grep -q "IdentityFile"; then
  bad "the Tailscale alias offers a key file" "$ts_block"
else
  ok "the Tailscale alias offers no key file (a key cannot authenticate there)"
fi
# The host key is not provisioned yet, and the generated config says so
# loudly rather than presenting an unpinned alias as a working one.
if grep -q "NOT PINNED" <<<"$sshcfg"; then
  ok "the missing host-key pin is reported in the generated config"
else
  bad "no visible warning about the missing host-key pin" "an unpinned alias looks identical to a pinned one"
fi

summary "host-isolation"