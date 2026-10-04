#!/usr/bin/env python3
# nixos/config/system/media/scripts/webui-proxy.py
#
# The one deliberate, narrow path from the host into the qBittorrent namespace.
#
# ── Why a proxy rather than a routable service ───────────────────────────────
# The namespace's WebUI has to be reachable from a browser, and browsers cannot
# be taught to speak WireGuard. The obvious alternative — putting a port
# forward on the tunnel, or binding qBittorrent to the veth address and opening
# a firewall port — makes the admin surface reachable by anything that can
# route to that address. That includes the LAN the server sits on, which is a
# family network full of devices nobody here controls.
#
# So the WebUI stays inside the namespace, bound to the tunnel or to loopback
# THERE, and this process is the only thing that crosses the boundary. It binds
# 127.0.0.1 on the host. Not 0.0.0.0, not the tailscale address, not the veth
# address — loopback only, which means the LAN cannot reach it by construction
# rather than by a firewall rule that might be reordered later.
#
# A service bound to loopback is still reachable by everything on this host,
# including anything a compromised agent session runs as this user. Hence:
#
# ── Why there is a token ────────────────────────────────────────────────────
# qBittorrent authenticates its own WebUI, and that is necessary but not
# sufficient here. If qBittorrent's password is unset — which is exactly what a
# freshly-provisioned instance looks like, and what a restore of an old config
# can bring back — the WebUI is unauthenticated, and every process on the host
# could drive it.
#
# The token closes that gap from OUTSIDE qBittorrent: it lives in a systemd
# credential, so it is readable only by this service, it is never in the Nix
# store, and it cannot be read out of a unit file or a process listing. A
# request without it is refused before any byte reaches the namespace.
#
# The token is compared with hmac.compare_digest rather than `==`. That is not
# paranoia about who is calling — it is about what a wrong token reveals: a
# byte-at-a-time comparison oracle is a slower way to brute-force a secret than
# a rejected connection, and the cost of the constant-time version is zero.
#
# ── Scope ───────────────────────────────────────────────────────────────────
# It is a REVERSE PROXY, not a forward proxy, and not a general HTTP relay:
#
#   * it only ever connects to one configured backend address, which lives
#     inside the namespace;
#   * it only ever serves the WebUI's own origin;
#   * hop-by-hop headers are stripped, so the client cannot smuggle a
#     Connection/Upgrade through to the backend;
#   * the token header is stripped before forwarding, so the backend never sees
#     a credential this proxy is responsible for;
#   * requests that do not arrive on loopback are refused at the socket, not
#     merely by policy.
#
# WebSockets are NOT proxied. qBittorrent's WebUI does not require them, and
# a CONNECT/Upgrade tunnel is a materially larger surface than the admin UI
# needs. Refusing it is a smaller thing to keep correct than proxying it.
import hmac
import http.client
import http.server
import os
import socket
import socketserver
import sys
import urllib.parse

BACKEND_HOST = os.environ.get("MEDI_PROXY_BACKEND_HOST", "10.77.0.2")
BACKEND_PORT = int(os.environ.get("MEDI_PROXY_BACKEND_PORT", "8080"))
LISTEN_HOST = os.environ.get("MEDI_PROXY_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("MEDI_PROXY_LISTEN_PORT", "8081"))
TOKEN_FILE = os.environ.get("MEDI_PROXY_TOKEN_FILE", "")
TOKEN_HEADER = "x-media-proxy-token"
# Seconds. Short on purpose: this is a LAN-scale tailnet hop, and a hung
# connection is a hung browser tab.
TIMEOUT = float(os.environ.get("MEDI_PROXY_TIMEOUT", "30"))

# Hop-by-hop headers (RFC 9110 7.6.1) plus the two that carry the token.
# Stripped in both directions: a client cannot smuggle Connection through to
# the backend, and the backend cannot smuggle one back to influence our next
# hop.
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)
# Refused rather than forwarded. See the module header.
REFUSED_REQUEST_HEADERS = frozenset({"upgrade", "connect"})

# Distinct from None, which means "a request with no body".
BODY_REFUSED = object()


def log(message):
    """stderr, flushed. stdout is not used; systemd journald owns the stream."""
    sys.stderr.write("[webui-proxy] %s\n" % message)
    sys.stderr.flush()


def load_token():
    """Read the token from the systemd credential directory.

    The file is read as bytes and compared as bytes, so a token containing
    non-UTF-8 bytes is still handled exactly rather than raising on decode.
    """
    if not TOKEN_FILE:
        log("FATAL: MEDI_PROXY_TOKEN_FILE is unset — refusing to start unauthenticated")
        sys.exit(1)
    try:
        with open(TOKEN_FILE, "rb") as handle:
            token = handle.read().strip()
    except OSError as exc:
        # A MISSING credential is the expected state before the operator has
        # provisioned one, so it says how to fix it rather than just failing.
        log("FATAL: cannot read the proxy token credential %s: %s" % (TOKEN_FILE, exc))
        log("       provision it and restart; this proxy never runs without one")
        sys.exit(1)
    if not token:
        log("FATAL: proxy token credential %s is empty" % TOKEN_FILE)
        sys.exit(1)
    return token


TOKEN = load_token()


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1 so keep-alive works; the browser is talking to a local proxy and
    # a new connection per asset is a needless tax.
    protocol_version = "HTTP/1.1"
    server_version = "media-webui-proxy"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: A003 - base class API
        log("%s %s" % (self.client_address[0], fmt % args))

    def _refuse(self, status, reason):
        """Answer without contacting the namespace.

        Used for every rejection path, so a refused request never produces a
        packet inside the namespace at all.
        """
        body = reason.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        presented = self.headers.get(TOKEN_HEADER)
        if presented is None:
            log("refusing %s: no %s header" % (self.client_address[0], TOKEN_HEADER))
            return False
        # Encode the presented value the same way the stored token was encoded,
        # so a client cannot exploit a decode asymmetry between the two.
        if not hmac.compare_digest(presented.encode("utf-8", "surrogateescape"), TOKEN):
            log("refusing %s: bad token" % self.client_address[0])
            return False
        return True

    def _refuse_unsupported(self):
        for header in REFUSED_REQUEST_HEADERS:
            if self.headers.get(header) is not None:
                self._refuse(501, "this proxy does not forward %s\n" % header)
                return True
        return False

    def _proxy(self, body):
        if not self._authorised():
            self._refuse(401, "unauthorised\n")
            return
        if self._refuse_unsupported():
            return

        # Rebuild the path from the request line. `self.path` is attacker-
        # controlled and is passed straight to http.client, which decides what
        # to do with an absolute-form or authority-form request line; normalise
        # it to an origin-form path so the backend always sees the same shape.
        parsed = urllib.parse.urlsplit(self.path)
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query

        forward = {}
        for key, value in self.headers.items():
            lowered = key.lower()
            if lowered in HOP_BY_HOP or lowered == TOKEN_HEADER:
                # The token is ours; the backend has no business seeing it.
                continue
            forward[key] = value
        if "Host" not in {k.lower() for k in forward}:
            forward["Host"] = "%s:%d" % (BACKEND_HOST, BACKEND_PORT)

        try:
            conn = http.client.HTTPConnection(
                BACKEND_HOST, BACKEND_PORT, timeout=TIMEOUT
            )
            conn.request(self.command, target, body=body, headers=forward)
            upstream = conn.getresponse()
            payload = upstream.read()
        except (OSError, http.client.HTTPException) as exc:
            # The namespace being unreachable is the EXPECTED outcome when the
            # tunnel is down, so it is a 502 and not a crash.
            log("backend %s:%d unreachable: %s" % (BACKEND_HOST, BACKEND_PORT, exc))
            self._refuse(502, "the torrent namespace is not reachable\n")
            return

        self.send_response(upstream.status)
        for key, value in upstream.getheaders():
            if key.lower() in HOP_BY_HOP:
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        conn.close()

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy(None)

    def do_HEAD(self):  # noqa: N802
        self._proxy(None)

    def do_POST(self):  # noqa: N802
        body = self._read_body()
        if body is BODY_REFUSED:
            return
        self._proxy(body)

    def _read_body(self):
        """Return the body, or BODY_REFUSED after having answered 413.

        The sentinel exists because the caller must NOT then go on to proxy the
        request. Returning None is indistinguishable from "empty body", and the
        caller would forward a request whose body was never read: two responses
        on one connection, and the unread bytes parsed as the next request.
        """
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0:
            return None
        # Bound it. This proxy exists to reach one admin UI; an unbounded body
        # read is a way to use it as a memory-pressure lever on the host.
        if length > 32 * 1024 * 1024:
            self._refuse(413, "body too large for the admin proxy\n")
            # The body is still in the socket, so the connection cannot be
            # reused: the next request would begin mid-body.
            self.close_connection = True
            return BODY_REFUSED
        return self.rfile.read(length)

    def do_PUT(self):  # noqa: N802
        body = self._read_body()
        if body is BODY_REFUSED:
            return
        self._proxy(body)

    def do_DELETE(self):  # noqa: N802
        self._proxy(None)


class Server(socketserver.ThreadingTCPServer):
    # Loopback only. This is asserted here rather than trusted from the
    # environment: a proxy that can be re-pointed at 0.0.0.0 by an environment
    # edit is a proxy whose safety depends on the edit having been reviewed.
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler):
        if address[0] != "127.0.0.1":
            raise SystemExit(
                "[webui-proxy] refusing to listen on %s: this proxy is loopback-only"
                % address[0]
            )
        super().__init__(address, handler)


def main():
    server = Server((LISTEN_HOST, LISTEN_PORT), Handler)
    log(
        "listening on %s:%d -> http://%s:%d (private namespace WebUI, token-gated)"
        % (LISTEN_HOST, LISTEN_PORT, BACKEND_HOST, BACKEND_PORT)
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()