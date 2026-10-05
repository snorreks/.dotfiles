#!/usr/bin/env bash
# Dummy XML only. Executes the shipped Python heredoc, not a Jellyfin server.
# Static upstream binding proof is cited in jellyfin.nix; this is not a socket test.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${MEDI_PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON="$(find /nix/store -maxdepth 3 -path '*-python3-*/bin/python3' -type f 2>/dev/null | sort | tail -1)"
fi
[[ -n "$PYTHON" && -x "$(command -v "$PYTHON")" ]] || { echo 'python3 required' >&2; exit 1; }
"$PYTHON" - "$HERE/../../config/system/media/jellyfin.nix" <<'PY'
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
from xml.dom import minidom

source = pathlib.Path(sys.argv[1]).read_text()
code = textwrap.dedent(source.split("<<'PY'\n", 1)[1].split('\n      PY', 1)[0])
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    config = root / 'config'
    config.mkdir()
    helper = root / 'helper.py'
    helper.write_text(code)
    def run(mode, port='18096', good=True, path=config):
        result = subprocess.run([sys.executable, str(helper), mode, str(path), port], capture_output=True)
        assert (result.returncode == 0) == good, (mode, result.returncode)
        assert result.stdout == b''
        assert result.stderr in (b'', b'Jellyfin private configuration refused\n')
    system = config / 'system.xml'
    # Authentication-looking dummy data must never be touched or logged.
    auth = config / 'dummy-auth'
    auth.write_bytes(b'fixture-secret')
    network = config / 'network.xml'
    original = '''<?xml version="1.0"?><NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:custom="urn:fixture"><!--keep--><custom:Extra custom:attr="keep">fixture-secret</custom:Extra><BaseUrl>/movies</BaseUrl><CertificatePassword>fixture-secret</CertificatePassword><PublishedServerUriBySubnet><string>keep</string></PublishedServerUriBySubnet><VirtualInterfaceNames><string>lo</string></VirtualInterfaceNames><InternalHttpPort>8096</InternalHttpPort><LocalNetworkAddresses><string>0.0.0.0</string></LocalNetworkAddresses></NetworkConfiguration>'''
    network.write_text(original)
    system.write_text('<ServerConfiguration><IsStartupWizardCompleted>false</IsStartupWizardCompleted><Other>fixture-secret</Other></ServerConfiguration>')
    before = system.read_bytes()
    run('pin')
    assert system.read_bytes() == before and auth.read_bytes() == b'fixture-secret'
    doc = minidom.parse(str(network))
    def value(name):
        node = doc.getElementsByTagName(name)[0]
        return ''.join(n.data for n in node.childNodes if n.nodeType == n.TEXT_NODE)
    assert value('InternalHttpPort') == '18096'
    assert value('EnableIPv4') == 'true' and value('EnableIPv6') == 'false'
    assert value('IgnoreVirtualInterfaces') == 'false' and value('AutoDiscovery') == 'false'
    assert value('RequireHttps') == 'false'
    addresses = doc.getElementsByTagName('LocalNetworkAddresses')[0]
    assert addresses.getElementsByTagName('string')[0].firstChild.data == '127.0.0.1'
    assert len(addresses.getElementsByTagName('string')) == 1
    old = minidom.parseString(original)
    for name in ('custom:Extra', 'BaseUrl', 'CertificatePassword', 'PublishedServerUriBySubnet', 'VirtualInterfaceNames'):
        assert doc.getElementsByTagName(name)[0].toxml() == old.getElementsByTagName(name)[0].toxml()
    assert doc.documentElement.getAttribute('xmlns:custom') == 'urn:fixture'
    assert '<!--keep-->' in network.read_text()
    run('pin', '28096')
    assert '<InternalHttpPort>28096</InternalHttpPort>' in network.read_text()
    for flag in ('false', '0', 'True', 'TRUE', 'tRuE', '', 'fixture-secret', '<nested>true</nested>'):
        system.write_text('<ServerConfiguration><IsStartupWizardCompleted>' + flag + '</IsStartupWizardCompleted></ServerConfiguration>')
        before = system.read_bytes()
        run('check', good=False)
        assert system.read_bytes() == before
    for contents in ('<ServerConfiguration/>', '<broken', '<Wrong><IsStartupWizardCompleted>true</IsStartupWizardCompleted></Wrong>', '<ServerConfiguration><IsStartupWizardCompleted>true</IsStartupWizardCompleted><IsStartupWizardCompleted>true</IsStartupWizardCompleted></ServerConfiguration>'):
        system.write_text(contents)
        run('check', good=False)
    system.unlink()
    run('check', good=False)
    for flag in ('true', '1'):
        system.write_text('<ServerConfiguration><IsStartupWizardCompleted>' + flag + '</IsStartupWizardCompleted></ServerConfiguration>')
        run('check')
    # Execute the shipped shell wrapper with fake CLIs and the real checker.
    shell = source.split('name = "jellyfin-private-serve";', 1)[1].split("text = ''\n", 1)[1].split("\n    '';", 1)[0]
    shell = textwrap.dedent(shell).replace("''${", "${")
    shell = shell.replace('${toString cfg.serveHttpsPort}', '8443').replace('${toString cfg.port}', '28096')
    shell = shell.replace('${lib.getExe nativeConfig}', shlex.quote(sys.executable) + ' ' + shlex.quote(str(helper)))
    shell = shell.replace('${lib.escapeShellArg cfg.configDir}', shlex.quote(str(config)))
    cli = root / 'bin'
    cli.mkdir()
    log = root / 'calls'
    tailscale = cli / 'tailscale'
    tailscale.write_text('#!' + sys.executable + '\nimport os,sys\nwith open(os.environ["CALLS"], "a") as f: f.write(" ".join(sys.argv[1:]) + "\\n")\nif sys.argv[-1] == "off" and os.environ.get("CLEANUP_ERROR"):\n print(os.environ["CLEANUP_ERROR"], file=sys.stderr)\n sys.exit(1)\n')
    runuser = cli / 'runuser'
    runuser.write_text('#!' + sys.executable + '\nimport os,sys\nassert sys.argv[1:4] == ["-u", "jellyfin", "--"]\nos.execv(sys.argv[4], sys.argv[4:])\n')
    tailscale.chmod(0o755)
    runuser.chmod(0o755)
    for opted, flag, published in ((False, 'true', False), (True, 'false', False), (True, 'True', False), (True, 'true', True)):
        system.write_text('<ServerConfiguration><IsStartupWizardCompleted>' + flag + '</IsStartupWizardCompleted></ServerConfiguration>')
        log.write_text('')
        script = shell.replace('${if cfg.setupCompleted then "true" else "false"}', 'true' if opted else 'false')
        result = subprocess.run([shutil.which('bash'), '-e', '-u', '-o', 'pipefail', '-c', script], env={**os.environ, 'PATH': str(cli), 'CALLS': str(log)}, capture_output=True)
        assert (result.returncode == 0) == published
        calls = log.read_text().splitlines()
        assert calls[0] == 'serve --https=8443 off'
        assert len(calls) == (2 if published else 1)
        if published:
            assert calls[1] == 'serve --bg --https=8443 http://127.0.0.1:28096'
        assert b'fixture-secret' not in result.stdout + result.stderr
    for error, succeeds in (
        ('error: failed to remove web serve: handler does not exist', True),
        ('error: failed to remove web serve: handler does not exist\n\ntry `tailscale serve --help` for usage info', True),
        ('error: failed to remove web serve: cannot remove web handler; currently serving TCP', False),
        ('failed to connect to local tailscaled', False),
    ):
        log.write_text('')
        result = subprocess.run([shutil.which('bash'), '-e', '-u', '-o', 'pipefail', '-c', script],
                                env={**os.environ, 'PATH': str(cli), 'CALLS': str(log), 'CLEANUP_ERROR': error}, capture_output=True)
        assert (result.returncode == 0) == succeeds, result.stderr
        assert len(log.read_text().splitlines()) == (2 if succeeds else 1)
        if not succeeds:
            assert error.encode() in result.stderr
    # Refuse symlink reads both at the file and directory level.
    system.unlink()
    system.symlink_to(auth)
    run('check', good=False)
    network.unlink()
    network.symlink_to(auth)
    run('pin', good=False)
    assert auth.read_bytes() == b'fixture-secret'
    link = root / 'linked'
    link.symlink_to(config, target_is_directory=True)
    run('pin', good=False, path=link)
    network.unlink()
    run('pin')  # First boot creates only network.xml, never system.xml.
    network.write_text('<broken')
    run('pin', good=False)
    assert network.read_text() == '<broken'

# Publication wrapper order and privilege/dependency boundary, not live Serve.
wrapper = source.split('name = "jellyfin-private-serve";', 1)[1].split('in {', 1)[0]
assert wrapper.index(' off') < wrapper.index('if cfg.setupCompleted') < wrapper.index('runuser -u jellyfin') < wrapper.index('serve --bg')
assert 'runtimeInputs = [pkgs.python3]' in source
assert 'requires = ["jellyfin.service"]' in source
assert '"jellyfin.service"' in source.split('after = [', 1)[1].split('];', 1)[0]
assert 'TimeoutStartSec = "30s"' in source
assert 'lib.mkBefore' in source and 'nativeConfig} pin' in source
assert 'PublishedServerUrl' not in source
print('jellyfin-private: dummy XML and static unit boundaries passed (no live listener coverage)')
PY
