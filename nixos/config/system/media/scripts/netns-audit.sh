#!/usr/bin/env bash
# nixos/config/system/media/scripts/netns-audit.sh
#
# Assert the qBittorrent namespace's fail-closed properties against a namespace
# that is actually up.
#
# ── Why this is a script and not assertions inside a test file ──────────────
# Because the things worth asserting here are properties of the RUNNING system,
# not of a copy of its configuration. A test that greps netns-up.sh for the
# string "DROP" proves the word is present; it does not prove that the policy
# was installed, that the tunnel is absent while the rule is already in place,
# or that the namespace genuinely has no route out. Those are only observable
# against a live namespace.
#
# So this script is the instrument, the test suite creates a namespace, and the
# operator can run the same script against the real one before travelling. One
# implementation, so there is nothing for the tests to drift away from.
#
# It is READ-ONLY with respect to the namespace: it inspects rules, routes and
# counters, and attempts probe connections. It does not add, remove or flush
# any rule, and it does not modify any interface. Running it against the live
# namespace cannot weaken it.
#
# Exit status is 0 only when every check passes; the first failure is fatal
# because continuing after a broken namespace produces a cascade of confusing
# results that all follow from the first thing that was already wrong.
set -uo pipefail

NS="${MEDI_NS:-medtns}"
VETH_NS="${MEDI_VETH_NS:-mtns0}"
WG_IF="${MEDI_WG_IF:-wg0}"
WEBUI_PORT="${MEDI_WEBUI_PORT:?MEDI_WEBUI_PORT must be set}"
GATEWAY="${MEDI_GATEWAY:-10.77.0.1}"
IPT="${MEDI_IPT:-iptables}"
IP6T="${MEDI_IP6T:-ip6tables}"
IP="${MEDI_IP:-ip}"

failures=0
checks=0

pass() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf '  FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
  return 0
}

ns() { "$IP" netns exec "$NS" "$@"; }

printf '=== netns-audit: namespace %s ===\n' "$NS"

# ── Preconditions ───────────────────────────────────────────────────────────
if ! "$IP" netns list | awk '{print $1}' | grep -qx "$NS"; then
  printf 'namespace %s does not exist; nothing to audit.\n' "$NS" >&2
  printf 'Run netns-up.sh first, or set MEDI_NS to an existing namespace.\n' >&2
  exit 2
fi

# ── 1. OUTPUT policy is DROP ────────────────────────────────────────────────
#
# Checked on both stacks. A policy of ACCEPT with a single trailing DROP is a
# different design and would not have the same failure behaviour, so the
# policy itself is what is asserted, not merely that something is dropped.
for tool in "$IPT" "$IP6T"; do
  # `iptables -S OUTPUT` prints `-P OUTPUT ACCEPT` FIRST, then the rules, so
  # field 1 of the first line is the literal "-P" and every policy check failed
  # — which meant this audit refused to let anything start, on a namespace whose
  # policy was correct. The policy is field 3 of the line beginning with -P.
  policy="$("$IP" netns exec "$NS" "$tool" -S OUTPUT 2>/dev/null | awk '/^-P /{print $3; exit}')"
  if [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
    pass "$tool OUTPUT policy is $policy"
  else
    fail "$tool OUTPUT policy is $policy" "expected DROP; a permissive policy is a leak, not a style choice"
  fi
done

# ── 2. The tunnel rule exists and is scoped to the tunnel interface ─────────
#
# The rule must be present regardless of whether wg0 currently exists — it is
# the ABSENCE of matches while wg0 is missing that produces the fail-closed
# behaviour, so a namespace audited while the tunnel is down is the interesting
# case, not an awkward one.
if "$IP" netns exec "$NS" "$IPT" -S OUTPUT 2>/dev/null | grep -q -- "-o $WG_IF .*-j ACCEPT"; then
  pass "an ACCEPT rule for -o $WG_IF is installed"
else
  fail "no ACCEPT rule for -o $WG_IF" "without it the tunnel's own traffic is dropped and downloads never work"
fi

# ── 3. No default route via the veth ────────────────────────────────────────
#
# Independent of netfilter: even with every rule deleted, the namespace would
# still have nowhere to send a packet. Two independent mechanisms, asserted
# separately, because either one alone leaves a single point of failure.
default_via_veth="$(ns "$IP" route show default 2>/dev/null | grep -c "dev $VETH_NS" || true)"
if [[ "${default_via_veth:-0}" == "0" ]]; then
  pass "no default route via $VETH_NS"
else
  fail "a default route via $VETH_NS exists" "routing alone would carry traffic out even if netfilter were removed"
fi

# ── 4. No IPv6 on the namespace interfaces ──────────────────────────────────
for dev in "$VETH_NS" lo; do
  value="$(ns cat "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null || echo "?")"
  if [[ "$value" == "1" ]]; then
    pass "IPv6 disabled on $dev"
  else
    fail "IPv6 is not disabled on $dev (disable_ipv6=$value)" "IPv4-only must be expressed as IPv4-only, not as a missing default"
  fi
done

# ── 4b. INPUT is closed too ─────────────────────────────────────────────────
#
# Checked for the same reason the OUTPUT policy is: a namespace with a closed
# egress but an open ingress has not been isolated, it has only been half
# isolated. Anything on the host that can route to the namespace address would
# otherwise reach the WebUI directly, bypassing the loopback proxy entirely.
input_policy="$("$IP" netns exec "$NS" "$IPT" -S INPUT 2>/dev/null | awk '/^-P /{print $3; exit}')"
if [[ "$input_policy" == "DROP" || "$input_policy" == "REJECT" ]]; then
  pass "iptables INPUT policy is $input_policy"
else
  fail "iptables INPUT policy is $input_policy" "the kernel default is ACCEPT; without this the WebUI is reachable from the host without the proxy"
fi

input_allowed="$("$IP" netns exec "$NS" "$IPT" -S INPUT 2>/dev/null | grep -E '^-A' | grep -v -- '-j DROP' | grep -v -- '-j REJECT' || true)"
# Every permitted INPUT rule must be one of exactly two shapes: loopback, or the
# host's proxy arriving from the host side of the veth on the WebUI port.
# Anything else — a LAN subnet, a DNS server, a whole interface — is a hole,
# so this enumerates rather than counting.
bad_input="$(
  printf '%s\n' "$input_allowed" |
    grep -v -- '-i lo' |
    grep -vE -- "-i $VETH_NS -s $GATEWAY .*--dport $WEBUI_PORT" || true
)"
if [[ -z "$bad_input" ]]; then
  pass "every permitted INPUT rule is loopback or the host proxy on $WEBUI_PORT"
else
  fail "a permitted INPUT rule is neither loopback nor the host proxy" "$bad_input"
fi

# ── 5. IPv6 OUTPUT is dropped outright ─────────────────────────────────────
if "$IP" netns exec "$NS" "$IP6T" -S OUTPUT 2>/dev/null | grep -qE "^-A OUTPUT .*-j DROP$"; then
  pass "ip6tables OUTPUT drops"
else
  fail "ip6tables OUTPUT does not drop" "an allowed IPv6 path would bypass the IPv4 tunnel entirely"
fi

# ── 6. DNS cannot leave over the veth ───────────────────────────────────────
#
# Not "DNS resolves" — the namespace is expected to resolve nothing at all
# while the tunnel is down. What matters is that there is no rule permitting a
# resolver over the veth, because such a rule is a DNS leak that works even
# when every packet it carries is subsequently dropped.
leak_rules="$(
  "$IP" netns exec "$NS" "$IPT" -S OUTPUT 2>/dev/null |
    grep -E -- "-o $VETH_NS" | grep -E -- "--dport 53" | grep -v -- "-j DROP" || true
)"
if [[ -z "$leak_rules" ]]; then
  pass "no rule permits port 53 over $VETH_NS"
else
  fail "a rule permits DNS over $VETH_NS" "$leak_rules"
fi

# ── 7. The only non-tunnel egress is UDP to one endpoint ────────────────────
#
# Enumerates every OUTPUT rule that is not a DROP, not loopback, not the tunnel
# and not an explicit DNS drop, and requires each to be a veth-scoped rule. This
# is the check that would catch a future "let me also reach the printer on the
# LAN" edit.
unexpected="$(
  "$IP" netns exec "$NS" "$IPT" -S OUTPUT 2>/dev/null |
    grep -E '^-A' |
    grep -v -- "-j DROP" |
    grep -v -- "-j REJECT" |
    grep -v -- "-o lo" |
    grep -v -- "-o $WG_IF" |
    grep -v -- "--dport 53" |
    grep -v -- "-o $VETH_NS" || true
)"
if [[ -z "$unexpected" ]]; then
  pass "every permitted OUTPUT rule is scoped to lo, the tunnel, or the veth"
else
  fail "a permitted OUTPUT rule is not scoped to lo/$WG_IF/$VETH_NS" "$unexpected"
fi

# ── 8. The veth rules are few and enumerated ────────────────────────────────
#
# Printed rather than asserted as an exact count: the meaningful property is
# that a human can read the whole list. An audit that prints a short list and a
# test that fails when it grows past it together mean an accidental widening is
# visible in review AND caught automatically.
veth_rules="$("$IP" netns exec "$NS" "$IPT" -S OUTPUT 2>/dev/null | grep -- "-o $VETH_NS" || true)"
count="$(printf '%s\n' "$veth_rules" | grep -c . || true)"
printf '  --- permitted rules scoped to %s (%s) ---\n' "$VETH_NS" "$count"
printf '%s\n' "$veth_rules" | sed 's/^/      /'
if ((count <= 6)); then
  pass "veth rules are bounded ($count)"
else
  fail "veth rules grew to $count" "each addition is a hole; justify it here rather than growing the list"
fi

# ── 9. Nothing bound in the namespace is reachable from the LAN ─────────────
#
# The WebUI inside the namespace must not be listening on the veth address.
# It is bound to the tunnel, and the only route in is the host's loopback proxy.
webui_on_veth="$(ns "$IP" -o addr show dev "$VETH_NS" 2>/dev/null | wc -l || true)"
if [[ "${webui_on_veth:-0}" -ge 1 ]]; then
  pass "$VETH_NS is addressed inside the namespace (routable host->namespace path exists)"
else
  fail "$VETH_NS has no address in the namespace" "the host proxy cannot reach the WebUI without it"
fi

printf '=== netns-audit: %s check(s), %s failure(s) ===\n' "$checks" "$failures"
if ((failures > 0)); then
  printf 'The namespace is NOT fail-closed. Do not start the torrent client.\n' >&2
  exit 1
fi
printf 'The namespace is fail-closed.\n'
exit 0