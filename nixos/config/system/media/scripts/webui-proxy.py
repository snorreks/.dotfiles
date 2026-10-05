#!/usr/bin/env python3
"""Bounded, token-gated loopback reverse proxy. No forwarding or upgrades."""
import hmac
import http.client
import http.server
import os
import socket
import socketserver
import threading
import urllib.parse

BACKEND_HOST = os.environ['MEDI_PROXY_BACKEND_HOST']
BACKEND_PORT = int(os.environ['MEDI_PROXY_BACKEND_PORT'])
LISTEN_HOST = os.environ.get('MEDI_PROXY_LISTEN_HOST', '127.0.0.1')
LISTEN_PORT = int(os.environ['MEDI_PROXY_LISTEN_PORT'])
TIMEOUT = float(os.environ.get('MEDI_PROXY_TIMEOUT', '10'))
MAX_BODY = 32 * 1024 * 1024
MAX_RESPONSE = 32 * 1024 * 1024
TOKEN_HEADER = 'x-media-proxy-token'
with open(os.environ['MEDI_PROXY_TOKEN_FILE'], 'rb') as credential:
    TOKEN = credential.read(4096).strip()
if not TOKEN:
    raise SystemExit('empty proxy credential')
HOP = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
       'te', 'trailer', 'transfer-encoding', 'upgrade'}


def close_socket(connection):
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    connection.close()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        self.request.settimeout(TIMEOUT)
        # Absolute lifetime, not just idle timeout: trickling headers/bodies
        # cannot retain a worker indefinitely. No keepalive on this proxy.
        self.deadline = threading.Timer(TIMEOUT, close_socket, (self.request,))
        self.deadline.daemon = True
        self.deadline.start()
        super().setup()

    def finish(self):
        try:
            super().finish()
        finally:
            self.deadline.cancel()

    def refuse(self, status, message):
        self.close_connection = True
        body = message.encode()
        self.send_response(status)
        self.send_header('Connection', 'close')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_expect_100(self):
        # Never invite a body before checking the token.
        if not self.authorised():
            self.refuse(401, 'unauthorised\n')
            return False
        return super().handle_expect_100()

    def authorised(self):
        presented = self.headers.get(TOKEN_HEADER, '').encode('utf-8')
        return hmac.compare_digest(presented, TOKEN)

    def proxy(self):
        self.close_connection = True
        # Check BEFORE reading even one byte of an unauthorised body.
        if not self.authorised():
            self.refuse(401, 'unauthorised\n')
            return
        if self.headers.get('Upgrade') or self.headers.get('Transfer-Encoding'):
            self.refuse(501, 'unsupported framing\n')
            return
        lengths = self.headers.get_all('Content-Length', [])
        try:
            if len(lengths) > 1:
                raise ValueError()
            length = int(lengths[0]) if lengths else 0
            if not 0 <= length <= MAX_BODY:
                raise ValueError()
        except ValueError:
            self.refuse(413, 'invalid body length\n')
            return
        body = self.rfile.read(length) if length else None
        if length and len(body) != length:
            self.refuse(400, 'incomplete body\n')
            return
        parsed = urllib.parse.urlsplit(self.path)
        target = parsed.path or '/'
        if parsed.query:
            target += '?' + parsed.query
        connection_headers = {part.strip().lower() for part in self.headers.get('Connection', '').split(',')}
        excluded = HOP | connection_headers | {TOKEN_HEADER, 'host', 'content-length', 'x-forwarded-host'}
        headers = {key: value for key, value in self.headers.items() if key.lower() not in excluded}
        headers['Host'] = '%s:%s' % (BACKEND_HOST, BACKEND_PORT)
        if self.headers.get('Host'):
            headers['X-Forwarded-Host'] = self.headers['Host']
        connection = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=TIMEOUT)
        # Bound upstream's total lifetime as well as each socket operation.
        timer = threading.Timer(TIMEOUT, lambda: close_socket(connection.sock) if connection.sock else None)
        timer.daemon = True
        timer.start()
        try:
            connection.request(self.command, target, body=body, headers=headers)
            upstream = connection.getresponse()
            payload = upstream.read(MAX_RESPONSE + 1)
            if len(payload) > MAX_RESPONSE:
                raise OSError('response exceeds limit')
            self.send_response(upstream.status)
            excluded_response = HOP | {'content-length'} | {
                part.strip().lower() for part in upstream.getheader('Connection', '').split(',')}
            for key, value in upstream.getheaders():
                if key.lower() not in excluded_response:
                    self.send_header(key, value)
            self.send_header('Connection', 'close')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(payload)
        except (OSError, http.client.HTTPException):
            self.refuse(502, 'backend unavailable\n')
        finally:
            timer.cancel()
            connection.close()

    do_GET = proxy
    do_HEAD = proxy
    do_POST = proxy
    do_PUT = proxy
    do_DELETE = proxy


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, handler):
        if address[0] != '127.0.0.1':
            raise SystemExit('proxy must bind loopback')
        self.workers = threading.BoundedSemaphore(16)
        super().__init__(address, handler)

    def process_request(self, request, address):
        if not self.workers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.workers.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.workers.release()


if __name__ == '__main__':
    with Server((LISTEN_HOST, LISTEN_PORT), Handler) as server:
        server.serve_forever()
