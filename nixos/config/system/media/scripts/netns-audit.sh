#!/usr/bin/env bash
# Read back the WHOLE filter table, not substrings or counts. Canonical -S
# output includes /32 masks and implicit tcp modules. Extra chains/rules fail.
set -euo pipefail
NS="${MEDI_NS:?}"; IP="${MEDI_IP:-ip}"
WG_IF="${MEDI_WG_IF:?}"; VETH_NS="${MEDI_VETH_NS:?}"
expected="$(printf '%s\n' \
  '-P INPUT DROP' '-P FORWARD DROP' '-P OUTPUT DROP' \
  '-A INPUT -i lo -j ACCEPT' \
  "-A INPUT -i $WG_IF -p tcp -m tcp --dport $MEDI_WEBUI_PORT -j DROP" \
  "-A INPUT -i $WG_IF -j ACCEPT" \
  "-A INPUT -s $MEDI_GATEWAY/32 -i $VETH_NS -p tcp -m tcp --dport $MEDI_WEBUI_PORT -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" \
  '-A OUTPUT -o lo -j ACCEPT' \
  "-A OUTPUT -o $WG_IF -j ACCEPT" \
  "-A OUTPUT -d $MEDI_GATEWAY/32 -o $VETH_NS -p tcp -m tcp --sport $MEDI_WEBUI_PORT -m conntrack --ctstate ESTABLISHED -j ACCEPT")"
actual="$("$IP" netns exec "$NS" "${MEDI_IPT:-iptables}" -w -S)"
if [[ "$actual" != "$expected" ]]; then
  printf 'IPv4 filter differs from exact allowlist:\n%s\n' "$actual" >&2
  exit 1
fi
actual6="$("$IP" netns exec "$NS" "${MEDI_IP6T:-ip6tables}" -w -S)"
[[ "$actual6" == $'-P INPUT DROP\n-P FORWARD DROP\n-P OUTPUT DROP' ]] || exit 1
# Every default, if present, must go through the configured tunnel, never veth.
routes="$("$IP" -n "$NS" route show default)"
while IFS= read -r route; do
  [[ -z "$route" || "$route" == "default dev $WG_IF" || "$route" == "default dev $WG_IF scope link" ]] || exit 1
done <<<"$routes"
printf 'Namespace exact allowlist verified.\n'
