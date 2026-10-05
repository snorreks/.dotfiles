#!/usr/bin/env python3
"""Socket-free proxy rejection and worker-cap regression checks."""
import email.message
import importlib.util
import os
import pathlib
import tempfile
from unittest import mock

script = pathlib.Path(__file__).parents[2] / 'config/system/media/scripts/webui-proxy.py'
with tempfile.TemporaryDirectory() as directory:
    token = pathlib.Path(directory) / 'token'
    token.write_text('fixture-token')
    os.environ.update(MEDI_PROXY_TOKEN_FILE=str(token), MEDI_PROXY_BACKEND_HOST='10.77.0.2',
                      MEDI_PROXY_BACKEND_PORT='18080', MEDI_PROXY_LISTEN_PORT='18081')
    spec = importlib.util.spec_from_file_location('proxy', script)
    proxy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proxy)
    handler = object.__new__(proxy.Handler)
    handler.headers = email.message.Message()
    handler.headers['Content-Length'] = '10000000'
    handler.rfile = mock.Mock()
    handler.refuse = mock.Mock()
    # Unauthorized POST/PUT with an untransmitted body must never read it.
    for method in (handler.do_POST, handler.do_PUT):
        method()
        handler.rfile.read.assert_not_called()
        handler.refuse.assert_called_with(401, 'unauthorised\n')
    assert handler.handle_expect_100() is False
    handler.headers[proxy.TOKEN_HEADER] = 'fixture-token'
    handler.headers['Transfer-Encoding'] = 'chunked'
    handler.proxy()
    handler.refuse.assert_called_with(501, 'unsupported framing\n')
    handler.rfile.read.assert_not_called()
    # Browser authority and CSRF headers survive, while untrusted forwarded
    # host values are replaced and the backend still gets its own Host.
    handler.headers = email.message.Message()
    for name, value in ((proxy.TOKEN_HEADER, 'fixture-token'), ('Host', 'media.example:8443'),
                        ('Origin', 'https://media.example:8443'), ('Referer', 'https://media.example:8443/ui'),
                        ('x-forwarded-host', 'forged.example')):
        handler.headers[name] = value
    handler.path = '/api/v2/app/version'
    handler.command = 'GET'
    handler.send_response = handler.send_header = handler.end_headers = mock.Mock()
    handler.wfile = mock.Mock()
    with mock.patch.object(proxy.http.client, 'HTTPConnection') as connect:
        upstream = connect.return_value.getresponse.return_value
        upstream.read.return_value = b'ok'
        upstream.getheader.return_value = ''
        upstream.getheaders.return_value = []
        handler.proxy()
        headers = connect.return_value.request.call_args.kwargs['headers']
        assert headers['Host'] == '10.77.0.2:18080'
        assert headers['X-Forwarded-Host'] == 'media.example:8443'
        assert 'x-forwarded-host' not in headers
        assert headers['Origin'] == 'https://media.example:8443'
        assert headers['Referer'] == 'https://media.example:8443/ui'
    # Construct without binding; mock thread creation and check the 17th
    # request is refused rather than spawning another worker.
    with mock.patch.object(proxy.socketserver.ThreadingTCPServer, '__init__'):
        server = proxy.Server(('127.0.0.1', 1), proxy.Handler)
    server.shutdown_request = mock.Mock()
    with mock.patch.object(proxy.socketserver.ThreadingTCPServer, 'process_request') as spawn:
        for _ in range(17):
            server.process_request(mock.Mock(), ('127.0.0.1', 1))
        assert spawn.call_count == 16
        assert server.shutdown_request.call_count == 1
    # Both client and backend have absolute deadlines, not idle timeout only.
    assert 'threading.Timer(TIMEOUT, close_socket' in script.read_text()
    assert 'threading.Timer(TIMEOUT, lambda:' in script.read_text()
print('PASS: unauthorized bodies/Expect rejected before read; bounded workers; deadline hooks')
