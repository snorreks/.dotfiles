#!/usr/bin/env bash
# Host-born WireGuard socket: encrypted UDP uses host routing; the veth is
# management ONLY. Never change host sysctls, NAT, forwarding or policies.
set -euo pipefail
NS="${MEDI_NS:?}"; VETH_HOST="${MEDI_VETH_HOST:?}"; VETH_NS="${MEDI_VETH_NS:?}"
WG_IF="${MEDI_WG_IF:?}"; IP="${MEDI_IP:-ip}"
IPT="${MEDI_IPT:-iptables}"; IP6T="${MEDI_IP6T:-ip6tables}"
nsx() { "$IP" netns exec "$NS" "$@"; }
case "${1:-namespace}" in
  tunnel-down) "$IP" -n "$NS" link del "$WG_IF"; exit ;;
  tunnel-up)
    # Validate before wg consumes the credential. Only native wg keys are
    # accepted; wg-quick hooks, DNS, Address and hostname endpoints fail closed.
    python3 - "$CREDENTIALS_DIRECTORY/wg.conf" <<'PY'
import ipaddress, os, re, sys
endpoint = os.environ['MEDI_WG_ENDPOINT']
host, port = endpoint.split(':')
ipaddress.IPv4Address(host)
assert port.isdecimal() and 1 <= int(port) <= 65535
ipaddress.IPv4Interface(os.environ['MEDI_TUNNEL_ADDRESS'])
resolver = ipaddress.IPv4Address(os.environ['MEDI_RESOLVER'])
assert not resolver.is_loopback and not resolver.is_unspecified
allowed = {'Interface': {'PrivateKey', 'ListenPort', 'FwMark'},
           'Peer': {'PublicKey', 'PresharedKey', 'AllowedIPs', 'Endpoint', 'PersistentKeepalive'}}
section = None
seen = set()
sections = []
values = {}
for raw in open(sys.argv[1]):
    line = raw.split('#', 1)[0].strip()
    if not line:
        continue
    if line in ('[Interface]', '[Peer]'):
        section = line[1:-1]
        assert section not in sections
        sections.append(section)
        continue
    key, value = [part.strip() for part in line.split('=', 1)]
    assert section in allowed and key in allowed[section]
    assert (section, key) not in seen
    seen.add((section, key))
    values[section, key] = value
assert sections == ['Interface', 'Peer']
assert values['Peer', 'Endpoint'] == endpoint
assert values['Peer', 'AllowedIPs'] == '0.0.0.0/0'
assert ('Interface', 'PrivateKey') in seen and ('Peer', 'PublicKey') in seen
PY
    "$IP" link add "$WG_IF" type wireguard
    trap '"$IP" link del "$WG_IF" 2>/dev/null || "$IP" -n "$NS" link del "$WG_IF" 2>/dev/null || true' ERR
    wg setconf "$WG_IF" "$CREDENTIALS_DIRECTORY/wg.conf"
    "$IP" link set "$WG_IF" netns "$NS"
    "$IP" -n "$NS" addr add "$MEDI_TUNNEL_ADDRESS" dev "$WG_IF"
    "$IP" -n "$NS" link set "$WG_IF" up
    "$IP" -n "$NS" route replace default dev "$WG_IF"
    exit ;;
  namespace) ;;
  *) exit 2 ;;
esac
# Validate public values before creating a namespace or writing resolver files.
python3 - <<'PY'
import ipaddress, os, re
for name in ('MEDI_NS', 'MEDI_VETH_HOST', 'MEDI_VETH_NS', 'MEDI_WG_IF'):
    assert re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}', os.environ[name])
assert len({os.environ[name] for name in ('MEDI_VETH_HOST', 'MEDI_VETH_NS', 'MEDI_WG_IF')}) == 3
host, port = os.environ['MEDI_WG_ENDPOINT'].split(':')
ipaddress.IPv4Address(host)
assert port.isdecimal() and 1 <= int(port) <= 65535
ipaddress.IPv4Interface(os.environ['MEDI_TUNNEL_ADDRESS'])
resolver = ipaddress.IPv4Address(os.environ['MEDI_RESOLVER'])
assert not resolver.is_loopback and not resolver.is_unspecified
host_link = ipaddress.IPv4Interface(os.environ['MEDI_HOST_ADDR'])
client_link = ipaddress.IPv4Interface(os.environ['MEDI_NS_ADDR'])
assert host_link.network == client_link.network and host_link.ip != client_link.ip
assert ipaddress.IPv4Address(os.environ['MEDI_GATEWAY']) == host_link.ip
assert 1 <= int(os.environ['MEDI_WEBUI_PORT']) <= 65535
PY
# Removing a namespace while clients still hold it is unsafe: systemd stops
# bound dependents first on restart. A failed construction never starts clients.
"$IP" netns del "$NS" 2>/dev/null || true
"$IP" link del "$VETH_HOST" 2>/dev/null || true
"$IP" netns add "$NS"
# Install real policies BEFORE bringing up any link.
for tool in "$IPT" "$IP6T"; do
  for chain in INPUT OUTPUT FORWARD; do nsx "$tool" -w -P "$chain" DROP; done
  nsx "$tool" -w -F
  nsx "$tool" -w -X
done
nsx "$IPT" -w -A INPUT -i lo -j ACCEPT
# Binding the WebUI to the veth address does not restrict its ingress device.
# A VPN peer must never bypass the host owner guard and token proxy.
nsx "$IPT" -w -A INPUT -i "$WG_IF" -p tcp -m tcp --dport "$MEDI_WEBUI_PORT" -j DROP
nsx "$IPT" -w -A INPUT -i "$WG_IF" -j ACCEPT
nsx "$IPT" -w -A INPUT -i "$VETH_NS" -s "$MEDI_GATEWAY/32" -p tcp -m tcp --dport "$MEDI_WEBUI_PORT" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
nsx "$IPT" -w -A OUTPUT -o lo -j ACCEPT
nsx "$IPT" -w -A OUTPUT -o "$WG_IF" -j ACCEPT
nsx "$IPT" -w -A OUTPUT -o "$VETH_NS" -d "$MEDI_GATEWAY/32" -p tcp -m tcp --sport "$MEDI_WEBUI_PORT" -m conntrack --ctstate ESTABLISHED -j ACCEPT
nsx sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
"$IP" link add "$VETH_HOST" type veth peer name "$VETH_NS"
"$IP" link set "$VETH_NS" netns "$NS"
"$IP" addr add "$MEDI_HOST_ADDR" dev "$VETH_HOST"
"$IP" -n "$NS" addr add "$MEDI_NS_ADDR" dev "$VETH_NS"
"$IP" -n "$NS" link set lo up
"$IP" -n "$NS" link set "$VETH_NS" up
"$IP" link set "$VETH_HOST" up
# ip netns exec uses this resolver; systemd clients explicitly bind it too.
resolver_dir="${MEDI_NETNS_ETC:-/etc/netns}/$NS"
install -d -m 0755 "$resolver_dir"
printf 'nameserver %s\n' "$MEDI_RESOLVER" >"$resolver_dir/resolv.conf"
