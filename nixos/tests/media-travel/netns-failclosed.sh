#!/usr/bin/env bash
# No live network operations: execute production scripts against stateful tools.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIA_ROOT="$(cd "$HERE/../.." && pwd)"
export MEDIA_ROOT
python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(os.environ['MEDIA_ROOT'])
scripts = root / 'config/system/media/scripts'
with tempfile.TemporaryDirectory() as directory:
    temp = pathlib.Path(directory)
    tool = temp / 'tool'
    tool.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
statefile = pathlib.Path(os.environ['STATE'])
state = json.loads(statefile.read_text()) if statefile.exists() else {'iptables': [], 'ip6tables': []}
with open(os.environ['LOG'], 'a') as log: log.write(json.dumps([name] + args) + '\\n')
if name == 'ip':
    if args[:2] == ['netns', 'exec']:
        os.execvp(args[3], args[3:])
    if 'show' in args and 'default' in args: print(state.get('route', ''))
    if 'replace' in args and 'default' in args: state['route'] = 'default dev customwg scope link'
if name in ('iptables', 'ip6tables'):
    args = [a for a in args if a != '-w']
    if args == ['-S']:
        policies = state[name][:3]
        rules = state[name][3:]
        print('\\n'.join(policies + sorted(rules, key=lambda r: 0 if r.startswith('-A INPUT') else 1)))
    if args[0] == '-P':
        state[name].append(' '.join(args))
        state[name][:3] = sorted(state[name][:3], key=lambda r: ['INPUT','FORWARD','OUTPUT'].index(r.split()[1]))
    if args[0] == '-A':
        # Canonical iptables -S puts source/destination before interfaces.
        for flag in ('-s', '-d'):
            if flag in args:
                index = args.index(flag)
                pair = args[index:index+2]
                del args[index:index+2]
                args[2:2] = pair
        state[name].append(' '.join(args))
statefile.write_text(json.dumps(state))
''')
    tool.chmod(0o755)
    for name in ('ip', 'iptables', 'ip6tables', 'sysctl', 'wg'):
        (temp / name).symlink_to(tool)
    env = dict(os.environ, PATH=str(temp)+':'+os.environ['PATH'], STATE=str(temp/'state'), LOG=str(temp/'log'),
        MEDI_NS='testns', MEDI_VETH_HOST='testhost', MEDI_VETH_NS='testveth',
        MEDI_HOST_ADDR='10.77.0.1/30', MEDI_NS_ADDR='10.77.0.2/30', MEDI_GATEWAY='10.77.0.1',
        MEDI_WG_IF='customwg', MEDI_WEBUI_PORT='18080', MEDI_WG_ENDPOINT='203.0.113.7:51820',
        MEDI_TUNNEL_ADDRESS='10.8.0.2/32', MEDI_RESOLVER='10.8.0.1', MEDI_NETNS_ETC=str(temp/'etc'),
        CREDENTIALS_DIRECTORY=str(temp))
    def run(script, *args, success=True, changes=None):
        result = subprocess.run(['bash', str(scripts/script), *args], env=env | (changes or {}), capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stderr + result.stdout
    for endpoint in ('vpn.invalid:51820', '999.1.1.1:51820', '203.0.113.7:0'):
        run('netns-up.sh', success=False, changes={'MEDI_WG_ENDPOINT': endpoint})
        assert not (temp/'log').exists()
    run('netns-up.sh')
    run('netns-audit.sh')
    original = json.loads((temp/'state').read_text())
    assert '-P OUTPUT DROP' in original['iptables']
    assert not any(rule in ('-A INPUT -j DROP', '-A OUTPUT -j DROP', '-A FORWARD -j DROP') for rule in original['iptables'][3:])
    # Evaluate the installed rule arguments against packet tuples, rather than
    # calling a terminal DROP a policy. Models this intentionally small filter.
    import shlex
    def verdict(chain, **packet):
        for text in original['iptables'][3:]:
            rule = shlex.split(text)
            if rule[1] != chain:
                continue
            fields = {'-i': 'incoming', '-o': 'outgoing', '-s': 'source', '-d': 'destination',
                      '-p': 'protocol', '--sport': 'sport', '--dport': 'dport'}
            matches = True
            for flag, field in fields.items():
                if flag in rule:
                    expected = rule[rule.index(flag)+1].removesuffix('/32')
                    matches &= str(packet.get(field, '')) == expected
            if '--ctstate' in rule:
                matches &= packet.get('state') in rule[rule.index('--ctstate')+1].split(',')
            if matches:
                return rule[rule.index('-j')+1]
        return next(text.split()[2] for text in original['iptables'][:3] if text.split()[1] == chain)
    assert verdict('INPUT', incoming='testveth', source='10.77.0.1', protocol='tcp', dport=18080, state='NEW') == 'ACCEPT'
    assert verdict('OUTPUT', outgoing='testveth', destination='10.77.0.1', protocol='tcp', sport=18080, state='ESTABLISHED') == 'ACCEPT'
    assert verdict('OUTPUT', outgoing='testveth', destination='10.77.0.1', protocol='tcp', sport=18080, state='NEW') == 'DROP'
    for port in (53, 51820, 443):
        assert verdict('OUTPUT', outgoing='testveth', destination='203.0.113.7', protocol='udp', dport=port, state='NEW') == 'DROP'
    assert verdict('INPUT', incoming='customwg', protocol='tcp', dport=6881, state='ESTABLISHED') == 'ACCEPT'
    for state in ('NEW', 'ESTABLISHED'):
        assert verdict('INPUT', incoming='customwg', destination='10.77.0.2', protocol='tcp', dport=18080, state=state) == 'DROP'
    assert verdict('OUTPUT', outgoing='customwg', protocol='udp', dport=53, state='NEW') == 'ACCEPT'
    assert verdict('OUTPUT', outgoing='missingwg', protocol='udp', dport=53, state='NEW') == 'DROP'
    assert verdict('FORWARD', incoming='testveth', outgoing='customwg') == 'DROP'
    # Exact allowlist rejects canonical extra/widened rules, including previously
    # invisible broad veth, DNS, tunnel-name substring and terminal-DROP tricks.
    mutations = [
        lambda s: s['iptables'].append('-A OUTPUT -o testveth -j ACCEPT'),
        lambda s: s['iptables'].append('-A INPUT -i testveth -j ACCEPT'),
        lambda s: s['iptables'].append('-A OUTPUT -o testveth -p udp -m udp --dport 53 -j ACCEPT'),
        lambda s: s['ip6tables'].append('-A OUTPUT -o customwg -j ACCEPT'),
        lambda s: s['iptables'].__setitem__(2, '-P OUTPUT ACCEPT'),
        lambda s: s['iptables'].append('-A OUTPUT -o customwg-extra -j ACCEPT'),
        lambda s: s.__setitem__('route', 'default via 10.77.0.1 dev testveth'),
    ]
    for mutate in mutations:
        state = json.loads(json.dumps(original)); mutate(state)
        (temp/'state').write_text(json.dumps(state))
        run('netns-audit.sh', success=False)
    (temp/'state').write_text(json.dumps(original))
    config = '[Interface]\nPrivateKey = dummy\n[Peer]\nPublicKey = dummy\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.7:51820\n'
    for bad in (config.replace('203.0.113.7', 'vpn.invalid'), config + 'PostUp = touch /tmp/unsafe\n', config.replace('0.0.0.0/0', '10.0.0.0/8')):
        (temp/'wg.conf').write_text(bad)
        run('netns-up.sh', 'tunnel-up', success=False)
    (temp/'wg.conf').write_text(config)
    run('netns-up.sh', 'tunnel-up')
    run('netns-audit.sh')
    calls = [json.loads(line) for line in (temp/'log').read_text().splitlines()]
    create = calls.index(['ip','link','add','customwg','type','wireguard'])
    move = calls.index(['ip','link','set','customwg','netns','testns'])
    assert create < move
    assert ['wg','setconf','customwg',str(temp/'wg.conf')] in calls[create:move]
    assert not any(c[0] == 'wg-quick' for c in calls)
    # Every firewall/sysctl call must be dispatched by netns exec immediately
    # before it; no host forwarding exception is permitted.
    for index, call in enumerate(calls):
        if call[0] in ('iptables','ip6tables','sysctl'):
            assert calls[index-1][:4] == ['ip','netns','exec','testns']
    assert (temp/'etc/testns/resolv.conf').read_text() == 'nameserver 10.8.0.1\n'
module = (root/'config/system/media/torrents.nix').read_text()
assert 'pkgs.qbittorrent-nox' in module and '"--interface"' not in module
assert 'BindReadOnlyPaths' in module and 'XDG_CONFIG_HOME' in module and 'XDG_DATA_HOME' in module
assert 'NetworkNamespacePath' not in module.split('systemd.services.media-tunnel =')[1].split('systemd.services.qbittorrent =')[0]
assert '"owner" "!" "--uid-owner" "media-webui-proxy"' in module
assert 'systemd.timers.media-netns-watchdog' in module
assert 'systemctl stop qbittorrent.service media-tunnel.service' in module
# The Nix indented string must contain Qt subgroup separators, not doubled
# literal backslashes which Python preserves as different INI keys.
assert 'WebUI\\Address=' in module and 'Session\\Interface=' in module
assert 'WebUI\\ReverseProxySupportEnabled=true' in module
assert 'WebUI\\TrustedReverseProxiesList=${cfg.gateway}' in module
assert 'hosts: files dns' in module
assert '"${nsswitch}:/etc/nsswitch.conf"' in module
assert 'InaccessiblePaths = ["-/run/nscd" "-/run/systemd/resolve"]' in module
assert 'WebUI\\\\Address=' not in module and 'Session\\\\Interface=' not in module
assert 'allowedTCPPorts' not in module and 'ip_forward' not in module
print('PASS: namespace rules, canonical mutations, host scope, runtime credential and headless settings (mock tools; not packet proof)')
PY
# Keep the socket-free proxy regression in the registered suite, not a manual
# one-off worker command that CI never runs.
python3 "$HERE/torrent-proxy.py"
