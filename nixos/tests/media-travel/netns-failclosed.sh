#!/usr/bin/env bash
# nixos/tests/media-travel/netns-failclosed.sh
#
# The torrent namespace must FAIL CLOSED. This suite runs the shipped
# netns-up.sh against stubbed privileged tools and asserts the netfilter calls
# it actually makes.
#
# Covered (audit checklist: "no tunnel, endpoint/DNS failure, IPv4/IPv6/direct
# DNS attempts"):
#
#   * a hostname endpoint is REFUSED, and no namespace is built at all
#   * OUTPUT and INPUT policies are DROP, on both stacks
#   * the tunnel is allowed by interface NAME, so an absent tunnel matches
#     nothing and falls through to DROP
#   * the ONLY non-tunnel egress is one UDP flow to one numeric endpoint
#   * no DNS can leave over the veth
#   * the namespace has a host route but NO default route via the veth
#
# What is NOT covered here, and is covered by netns-audit.sh against a REAL
# namespace: whether the kernel honours these rules at runtime, and whether a
# live process in the namespace can actually escape them. This suite proves the
# rules are correct; the audit proves they took effect. Both are needed and
# neither substitutes for the other.
#
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

printf '=== netns-failclosed ===\n'

# NOT `STUBS="$(fake_root_bin ...)"`. Command substitution runs in a subshell,
# so the `export FAKE_LOG` inside fake_root_bin would never reach this shell and
# every later assertion would fail on an unbound variable under `set -u` — which
# reads as a broken suite rather than as a fixture mistake.
STUBS="$FIXTURE_TMP/stubs"
fake_root_bin "$STUBS"

# ── 1. A hostname endpoint is refused before anything is created ────────────
#
# The single most important case: this is the bootstrap DNS leak. If a hostname
# were accepted, the namespace would have to resolve it through the veth before
# the tunnel exists, and the whole design would be circular.
run_netns_up "$STUBS" "vpn.example.invalid:51820"
status=$?
if [[ "$status" -ne 0 ]]; then
  ok "hostname endpoint refused (exit $status)"
else
  bad "hostname endpoint was ACCEPTED" "a hostname needs DNS to leave through the veth before the tunnel exists"
fi

if log_has "netns add"; then
  bad "a namespace was created despite the bad endpoint" "netns-up.sh must validate before creating anything"
else
  ok "no namespace was created"
fi
if log_has "iptables -w -A OUTPUT"; then
  bad "netfilter rules were installed despite the bad endpoint" "validation must happen first"
else
  ok "no netfilter rules were installed"
fi

# ── 2. A numeric endpoint is accepted ───────────────────────────────────────
: >"$FAKE_LOG"
run_netns_up "$STUBS" "203.0.113.7:51820"
status=$?
if [[ "$status" -eq 0 ]]; then
  ok "numeric endpoint accepted"
else
  bad "numeric endpoint refused" "$(tail -3 "$STUBS/stderr")"
fi

if log_has "netns add medtns"; then
  ok "namespace medtns created"
else
  bad "namespace not created"
fi
if log_has "ip link add mthost type veth peer name mtns0"; then
  ok "veth pair created"
else
  bad "veth pair not created"
fi

# ── 3. Both policies are DROP, on both stacks ──────────────────────────────
for tool in iptables ip6tables; do
  if grep -qE "^$tool -w -A OUTPUT -j DROP$" "$FAKE_LOG"; then
    ok "$tool OUTPUT policy is DROP"
  else
    bad "$tool OUTPUT policy is not DROP" "the policy IS the kill switch; binding is only extra"
  fi
done
grep -qE "^iptables -w -A INPUT -j DROP$" "$FAKE_LOG" \
  && ok "iptables INPUT policy is DROP" \
  || bad "iptables INPUT policy is not DROP" "a closed egress with open ingress is only half isolated"

# ── 4. The tunnel is allowed BY NAME ────────────────────────────────────────
#
# Unconditional: the rule must be installed whether or not wg0 currently
# exists. An absent wg0 is what makes the rule match nothing, which is the
# fail-closed property.
if log_has "iptables -w -A OUTPUT -o wg0 -j ACCEPT"; then
  ok "tunnel allowed via '-o wg0', installed unconditionally"
else
  bad "no unconditional '-o wg0' ACCEPT rule" "the fail-closed behaviour depends on it matching nothing while absent"
fi

# ── 5. The ONLY non-tunnel egress is one UDP flow ───────────────────────────
endpoint_rules="$(grep -E "^iptables -w -A OUTPUT -o mtns0" "$FAKE_LOG" | grep -v -- "--dport 53" || true)"
count="$(printf '%s\n' "$endpoint_rules" | grep -c . || true)"
if [[ "$count" == "1" ]]; then
  ok "exactly one non-DNS rule scoped to the veth"
else
  bad "expected 1 non-DNS veth rule, found $count" "$endpoint_rules"
fi

if log_has "iptables -w -A OUTPUT -o mtns0 -p udp -d 203.0.113.7 --dport 51820 -j ACCEPT"; then
  ok "the single veth egress is UDP to the pinned numeric endpoint"
else
  bad "the endpoint bootstrap rule is not the expected single UDP flow" "$endpoint_rules"
fi

# No rule may carry a subnet, a range, or a wildcard destination.
if printf '%s\n' "$endpoint_rules" | grep -qE -- "-d [0-9.]+/|-m multiport|--dport [0-9]+:[0-9]+"; then
  bad "a veth rule widens the destination" "$endpoint_rules"
else
  ok "the endpoint rule names one address and one port"
fi

# ── 6. DNS cannot leave over the veth ───────────────────────────────────────
grep -qE "^iptables -w -A OUTPUT -o mtns0 -p udp --dport 53 -j DROP$" "$FAKE_LOG" \
  && ok "UDP/53 over the veth is dropped" || bad "UDP/53 over the veth is not dropped"
grep -qE "^iptables -w -A OUTPUT -o mtns0 -p tcp --dport 53 -j DROP$" "$FAKE_LOG" \
  && ok "TCP/53 over the veth is dropped" || bad "TCP/53 over the veth is not dropped"

if printf '%s\n' "$endpoint_rules" | grep -q -- "--dport 53"; then
  bad "a DNS rule is not a DROP" "an ACCEPT of DNS on the veth is a working leak"
else
  ok "no DNS rule permits anything"
fi

# ── 7. IPv4-mapped traffic and IPv6 are both dropped ────────────────────────
grep -qE "^ip6tables -w -A OUTPUT -j DROP$" "$FAKE_LOG" \
  && ok "all IPv6 OUTPUT is dropped" || bad "IPv6 OUTPUT is not dropped"

# ── 8. The namespace has a host route but NO default route ─────────────────
if log_has "ip -n medtns route add 10.77.0.1/32 dev mtns0"; then
  ok "a /32 host route to the veth peer exists"
else
  bad "no host route in the namespace" "the permitted flows need somewhere to go"
fi
if log_has "route add default"; then
  bad "a DEFAULT route was added inside the namespace" "routing alone would carry traffic out if netfilter were removed"
else
  ok "no default route inside the namespace"
fi

# ── 9. IPv6 is disabled on the interfaces, not merely unrouted ─────────────
grep -q "sysctl -q -w net.ipv6.conf.mtns0.disable_ipv6=1" "$FAKE_LOG" \
  && ok "IPv6 disabled on mtns0" || bad "IPv6 not disabled on mtns0"
grep -q "sysctl -q -w net.ipv6.conf.all.disable_ipv6=1" "$FAKE_LOG" \
  && ok "IPv6 disabled across the namespace" || bad "IPv6 not disabled namespace-wide"

# ── 10. INPUT permits only loopback and the host proxy ─────────────────────
input_allow="$(grep -E "^iptables -w -A INPUT" "$FAKE_LOG" | grep -v -- "-j DROP" || true)"
if printf '%s\n' "$input_allow" | grep -q -- "-i lo -j ACCEPT"; then
  ok "loopback INPUT accepted"
else
  bad "loopback INPUT not accepted"
fi
if printf '%s\n' "$input_allow" | grep -qE -- "-i mtns0 -s 10.77.0.1 -p tcp --dport 18080 -j ACCEPT"; then
  ok "the WebUI port is reachable only from the host side of the veth"
else
  bad "the WebUI INPUT rule is wrong" "$input_allow"
fi
if printf '%s\n' "$input_allow" | grep -vE -- "-i lo|-i mtns0 -s 10.77.0.1" | grep -q .; then
  bad "an unexpected INPUT rule is permitted" "$input_allow"
else
  ok "no other INPUT rule is permitted"
fi

# ── 11. Re-running is idempotent (flush before rebuild) ────────────────────
: >"$FAKE_LOG"
run_netns_up "$STUBS" "203.0.113.7:51820"
if grep -q "iptables -w -F" "$FAKE_LOG" && grep -q "iptables -w -X" "$FAKE_LOG"; then
  ok "rules are flushed before being rebuilt"
else
  bad "rules are not flushed" "appending to a previous run's rules is how an allowance outlives its justification"
fi
if grep -q "netns del medtns" "$FAKE_LOG"; then
  ok "the namespace is torn down before being recreated"
else
  bad "no teardown before rebuild" "a killed previous run leaves a namespace that is silently inherited"
fi

summary "netns-failclosed"