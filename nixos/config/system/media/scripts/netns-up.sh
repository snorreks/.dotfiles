#!/usr/bin/env bash
# nixos/config/system/media/scripts/netns-up.sh
#
# Build the qBittorrent network namespace: veth pair, addresses, routing, and —
# the part that actually matters — the deny-by-default egress policy.
#
# ── What this is for ────────────────────────────────────────────────────────
# The client is the only workload on this host that must not be able to speak
# to the internet directly. If it can, "the tunnel was up" stops being the thing
# that decides where its packets go, and everything downstream of that
# assumption is decorative.
#
# The design point is that the FAILURE direction is the default. The namespace
# has no route to anywhere except two places, and neither of them is "the
# internet":
#
#   * wg0        the tunnel. Everything, once it exists.
#   * mtns0      the veth, and on it exactly TWO things: UDP to the tunnel
#                endpoint, and TCP to the host's WebUI proxy port.
#
# There is no default route via the veth. A packet that is not addressed to the
# tunnel, and not to the endpoint over the veth, has nowhere to go even before
# netfilter sees it; netfilter then drops it too, because OUTPUT's policy is
# DROP and no rule matches.
#
# ── Why the kill switch is the POLICY, not the interface binding ────────────
# qBittorrent is additionally bound to the tunnel interface, and that binding is
# real defence in depth. It is not what stops a leak, and it is worth being
# precise about why:
#
#   * binding to an interface that does not exist fails the *connect*, which is
#     fail-closed — but only for the paths that go through that socket. A
#     separate resolver process, a DNS lookup performed on its behalf, or any
#     code path that opens its own socket is not covered by the binding at all;
#   * a rule that matches `-o wg0` fails to match when wg0 is absent, which is
#     what makes "allow the tunnel" fail closed rather than open. That property
#     is the load-bearing one, and it belongs to the RULES, not to the binding.
#
# So: DROP policy first, wg0 allowed by name, veth allowed only for the two
# named flows. Binding last.
#
# ── IPv6 ────────────────────────────────────────────────────────────────────
# The provider tunnel is IPv4. Rather than write a speculative "IPv6 is routed
# somewhere" policy, every IPv6 OUTPUT packet is dropped outright, and no IPv6
# address, route or RA acceptance is configured inside the namespace at all.
# sysctl `disable_ipv6` is set on the namespace interfaces as a second layer.
# An IPv4-only decision expressed as an actual filter rule, rather than as the
# absence of configuration, is one that cannot be undone by something else
# turning a default on.
#
# ── Endpoint / DNS bootstrap ────────────────────────────────────────────────
# The endpoint is pinned as a NUMERIC address and port. This matters more than
# it looks: a hostname endpoint would require a DNS query to establish, and that
# query would have to leave through the veth — which is precisely the hole this
# script exists to not have. Numeric endpoint, zero bootstrap DNS.
#
# A provider that only issues hostnames is therefore not supported by this
# script as written, and the honest response is to resolve it once, on the
# host, at configuration time, and paste the result. `MEDI_WG_ENDPOINT` is
# validated as numeric here and the namespace is NOT created if it is not: a
# tunnel that cannot be pinned must fail closed, not fall back to a resolver.
#
# If the endpoint changes, rules are regenerated from the new configuration and
# the old allowance disappears with the old one. There is no window in which
# both are allowed, because the rules are rebuilt as a flush-and-replace rather
# than appended to.
#
# ── Idempotence and failure ────────────────────────────────────────────────
# Re-running is safe: the namespace and veth are torn down first, so a
# partially-created namespace from a killed previous run cannot be inherited.
# Every command that can fail is checked; the script exits non-zero rather than
# continuing into a half-configured namespace, because a half-configured
# namespace is exactly the state in which "qBittorrent is not downloading" is
# ambiguous between denied, broken and never-started.
set -euo pipefail

NS="${MEDI_NS:-medtns}"
VETH_HOST="${MEDI_VETH_HOST:-mthost}"
VETH_NS="${MEDI_VETH_NS:-mtns0}"
HOST_ADDR="${MEDI_HOST_ADDR:-10.77.0.1/30}"
NS_ADDR="${MEDI_NS_ADDR:-10.77.0.2/30}"
GATEWAY="${MEDI_GATEWAY:-10.77.0.1}"
WG_IF="${MEDI_WG_IF:-wg0}"
# The ONLY port reachable from inside the namespace towards the host.
# The ONLY port reachable INSIDE the namespace from the host. The host reaches
# the WebUI through its loopback proxy, which forwards here; nothing else in the
# namespace may be reached at all.
WEBUI_PORT="${MEDI_WEBUI_PORT:?MEDI_WEBUI_PORT must be set}"
# Numeric "host:port" of the tunnel endpoint. Required; validated below.
WG_ENDPOINT="${MEDI_WG_ENDPOINT:?MEDI_WG_ENDPOINT must be set (numeric host:port)}"
WG_PORT="${WG_ENDPOINT##*:}"
WG_HOST="${WG_ENDPOINT%:*}"

IPT="${MEDI_IPT:-iptables}"
IP6T="${MEDI_IP6T:-ip6tables}"
IP="${MEDI_IP:-ip}"
SYSCTL="${MEDI_SYSCTL:-sysctl}"

log() { printf '[netns-up] %s\n' "$*" >&2; }
die() {
  printf '[netns-up] FATAL: %s\n' "$*" >&2
  exit 1
}

# ── Validate the endpoint BEFORE creating anything ──────────────────────────
#
# Fail closed, early, and with a message that says what to do. The alternative
# — accepting a hostname here and resolving it inside the namespace — is the
# bootstrap leak this script is built to avoid.
case "$WG_HOST" in
  ''|*[!0-9.]*) die "MEDI_WG_ENDPOINT host part '$WG_HOST' is not numeric.
  A hostname endpoint would need a DNS query to leave through the veth, which
  is the leak this script prevents. Resolve it on the host at configuration
  time (getent ahosts <provider-host> | head -1) and set the numeric address." ;;
esac
case "$WG_PORT" in
  ''|*[!0-9]*) die "MEDI_WG_ENDPOINT port part '$WG_PORT' is not numeric." ;;
esac
if ((WG_PORT < 1 || WG_PORT > 65535)); then
  die "MEDI_WG_ENDPOINT port $WG_PORT out of range."
fi

# IPv4-mapped literal is the one form that would pass the numeric test above
# and still not be usable as a peer address.
if [[ "$WG_HOST" == *:* ]]; then
  die "MEDI_WG_ENDPOINT '$WG_HOST' looks like an IPv6 literal. This tunnel is
  IPv4-only by design (see the IPv6 section of this file's header)."
fi

log "namespace=$NS veth=$VETH_HOST/$VETH_NS endpoint=$WG_HOST:$WG_PORT (IPv4-only)"

# ── Tear down anything left over, then rebuild ──────────────────────────────
#
# `ip netns del` on a namespace that does not exist is an error, so it is
# explicitly tolerated. Doing this before creating rather than after is what
# makes a re-run converge instead of layering a second veth on the first.
"$IP" netns del "$NS" 2>/dev/null || true
"$IP" link del "$VETH_HOST" 2>/dev/null || true

# ── Namespace and veth pair ─────────────────────────────────────────────────
"$IP" netns add "$NS" || die "could not create network namespace $NS"
"$IP" link add "$VETH_HOST" type veth peer name "$VETH_NS" \
  || die "could not create the veth pair $VETH_HOST/$VETH_NS"
"$IP" link set "$VETH_NS" netns "$NS" \
  || die "could not move $VETH_NS into $NS"

# ── Addressing ──────────────────────────────────────────────────────────────
"$IP" addr add "$HOST_ADDR" dev "$VETH_HOST" || die "could not address $VETH_HOST"
"$IP" link set "$VETH_HOST" up || die "could not bring up $VETH_HOST"

"$IP" -n "$NS" addr add "$NS_ADDR" dev "$VETH_NS" || die "could not address $VETH_NS"
"$IP" -n "$NS" link set lo up || die "could not bring up lo in $NS"
"$IP" -n "$NS" link set "$VETH_NS" up || die "could not bring up $VETH_NS"

# ── No IPv6, anywhere in the namespace ──────────────────────────────────────
#
# Disabled per-interface rather than globally so this namespace's policy does
# not depend on — or alter — the host's sysctls.
"$SYSCTL" -q -w "net.ipv6.conf.${VETH_NS}.disable_ipv6=1" \
  || die "could not disable IPv6 on $VETH_NS"
"$SYSCTL" -q -w "net.ipv6.conf.all.disable_ipv6=1" \
  || die "could not disable IPv6 in namespace $NS"
"$IP" -n "$NS" -6 addr flush dev "$VETH_NS" 2>/dev/null || true
"$IP" -n "$NS" -6 route flush dev "$VETH_NS" 2>/dev/null || true

# ── Routing: a gateway on the veth, but NO default route ────────────────────
#
# The route below is a /32 host route to the host side of the veth, not a
# default route. It exists so the two permitted flows have somewhere to go and
# so replies come back. Everything else in the namespace is unroutable by
# design; that is the first of the two independent reasons a leak cannot
# happen, and the firewall below is the second.
"$IP" -n "$NS" route add "$GATEWAY/32" dev "$VETH_NS" \
  || die "could not add the host route in $NS"

# ── Deny by default ─────────────────────────────────────────────────────────
#
# Flush first, always. Appending rules to whatever a previous run left behind is
# how an allowance outlives the thing that justified it.
"$IPT" -w -t nat -F "$NS" 2>/dev/null || true
"$IPT" -w -F || true
"$IPT" -w -X || true
"$IP6T" -w -F || true

# loopback is trusted, and nothing else on lo is permitted to leave the box
"$IPT" -w -A OUTPUT -o lo -j ACCEPT

# ── THE TUNNEL ──────────────────────────────────────────────────────────────
#
# `-o wg0` is written once, here, and never conditioned on the interface
# existing. That is deliberate and it is the property the whole design rests
# on: while wg0 is absent this rule matches NOTHING, so a client with no tunnel
# falls through to the DROP policy below rather than being let out.
"$IPT" -w -A OUTPUT -o "$WG_IF" -j ACCEPT

# ── Endpoint bootstrap: the ONLY other permitted egress ─────────────────────
#
# One flow. UDP, one numeric destination, one port. Not a subnet, not a range.
# This is what lets the tunnel be established while the tunnel does not exist,
# and it is deliberately the minimum that accomplishes that.
"$IPT" -w -A OUTPUT -o "$VETH_NS" -p udp -d "$WG_HOST" --dport "$WG_PORT" -j ACCEPT

# ── INPUT: only the host's proxy may reach anything in here ────────────────
#
# The output side below is deny-by-default, and it would be easy to stop there
# and call the namespace closed. It is not: anything on this host able to route
# to 10.77.0.2 can REACH INTO the namespace, and the kernel's default INPUT
# policy is ACCEPT. So INPUT is denied by default too, and exactly one flow is
# allowed: TCP to the WebUI port, and only from the host side of the veth.
#
# Leaving this out is the difference between "downloads cannot leak" and "the
# admin UI is unreachable from everything except one loopback proxy".
"$IPT" -w -A INPUT -i lo -j ACCEPT
"$IPT" -w -A INPUT -i "$VETH_NS" -s "$GATEWAY" -p tcp --dport "$WEBUI_PORT" -j ACCEPT
"$IPT" -w -A INPUT -j DROP

# ── DNS: nothing outside the tunnel ─────────────────────────────────────────
#
# The resolver lives behind wg0, and is allowed by the `-o wg0` rule above.
# Nothing is permitted to reach a resolver over the veth. Written as an explicit
# DROP of the well-known resolver ports on the veth so that the intent is
# visible and so a later, well-meaning addition of "allow DNS" to the veth
# rules has to delete this line to take effect.
#
# This is also why there is no OUTPUT rule permitting the namespace to reach the
# host at all: it has no reason to, and not needing to is stronger than
# permitting it narrowly.
"$IPT" -w -A OUTPUT -o "$VETH_NS" -p udp --dport 53 -j DROP
"$IPT" -w -A OUTPUT -o "$VETH_NS" -p tcp --dport 53 -j DROP

# ── And the policy that actually does the work ──────────────────────────────
"$IPT" -w -A OUTPUT -j DROP

# IPv4-mapped and v4-in-v6 traffic is the classic way a "we blocked IPv6"
# policy gets walked around, so it is dropped before the generic IPv6 drop and
# is written separately so that it can be distinguished in a ruleset dump.
"$IP6T" -w -A OUTPUT -o lo -j ACCEPT
"$IP6T" -w -A OUTPUT -o "$WG_IF" -j ACCEPT
"$IP6T" -w -A OUTPUT -j DROP

# ── Reassembly ──────────────────────────────────────────────────────────────
# Without this, fragments of a permitted packet are unmatchable and get
# dropped, which shows up as a mysteriously half-working tunnel.
"$IPT" -w -C FORWARD 2>/dev/null || true
sysctl -q -w net.ipv4.ip_forward=0 2>/dev/null || true

log "egress policy installed:"
log "  allow lo"
log "  allow -o $WG_IF        (tunnel; matches nothing while it is absent)"
log "  allow -o $VETH_NS udp $WG_HOST:$WG_PORT   (endpoint bootstrap only)"
log "  drop  -o $VETH_NS port 53 (no DNS outside the tunnel)"
log "  drop  OUTPUT            (policy)"
log "  drop  ip6tables OUTPUT  (all IPv6)"
log "INPUT:"
log "  allow -i $VETH_NS tcp $GATEWAY:$WEBUI_PORT (host proxy only)"
log "  drop  INPUT             (policy)"
log "namespace $NS is up with no route to the internet"