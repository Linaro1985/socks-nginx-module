#!/usr/bin/env python3
"""Controllable HTTP/1.1 backend used by the local socks nginx test harness.

Listeners (all on 127.0.0.1 by default):

  * 18080 -- plain HTTP for the normal proxy tests
  * 18443 -- TLS HTTP, only when --cert and --key are supplied
  * 18444 -- raw TCP that speaks plaintext HTTP immediately after reading
             bytes.  Used to exercise "premature plaintext response from
             an SSL backend" (nginx must reject it, normally with 502).

The HTTP server is intentionally imperfect in a few endpoints so that
edge cases in nginx's upstream parser can be exercised.  Normal request
logging is disabled; only startup errors and unexpected handler failures
are written to stderr.  Exactly one "ready" line is written to stdout.
"""

from __future__ import annotations

import argparse
import socket
import socketserver
import ssl
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

DEFAULT_HTTP_PORT = 18080
DEFAULT_TLS_PORT = 18443
DEFAULT_PLAIN_PORT = 18444

BIG_BODY = b"x" * 200_000
PLAIN_ON_TLS_PORT_RESPONSE = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"


class BackendHandler(BaseHTTPRequestHandler):
    """Threaded handler for all of the edge-case endpoints."""

    protocol_version = "HTTP/1.1"
    server_version = "socks-test-backend"
    sys_version = ""

    # Keep the test output clean.  The harness only needs "ready" on stdout.
    def log_message(self, fmt: str, *args: object) -> None:  # noqa: A003
        return

    def log_error(self, fmt: str, *args: object) -> None:  # noqa: A003
        return

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        self._dispatch(head=False)

    def do_HEAD(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        self._dispatch(head=True)

    def _dispatch(self, head: bool) -> None:
        try:
            path = urlsplit(self.path).path
        except ValueError:
            self._send(400, b"bad request\n", head=head)
            return

        if path == "/ok":
            self._send(200, b"hello", "text/plain", head=head)

        elif path == "/charset-bad":
            # Deliberately malformed charset (opening quote, nothing after
            # it) plus a duplicate Content-Type without parameters.  This is
            # a robustness check for the nginx 06c30ec2 underflow: with this
            # nginx version the first header wins, so the saved charset is
            # not appended and the harness only asserts that the worker
            # survives the malformed header.
            self._send(
                200,
                b"bad",
                'text/html; charset="',
                extra_headers=(("Content-Type", "text/plain"),),
                head=head,
            )

        elif path == "/charset-good":
            self._send(200, b"good", 'text/html; charset="utf-8"', head=head)

        elif path == "/big":
            self._send(200, BIG_BODY, "text/plain", head=head)

        elif path == "/chunked":
            self._send_chunked(head=head)

        elif path == "/xaccel":
            self._send(
                200,
                b"cached",
                "text/plain",
                extra_headers=(("X-Accel-Redirect", "/internal-target"),),
                head=head,
            )

        elif path == "/cache-control-huge":
            self._send(
                200,
                b"cached",
                "text/plain",
                extra_headers=((
                    "Cache-Control",
                    "public, max-age=99999999999999999999999",
                ),),
                head=head,
            )

        elif path == "/split-status-bad":
            self._send_split_bad()

        elif path == "/split-status-good":
            self._send_split_good()

        elif path == "/store-empty":
            self._send(200, b"stored", "text/plain", head=head)

        elif path == "/echo":
            # Echo the request target so tests can verify what the module
            # actually sent upstream (used by the loc_len regression check).
            body = self.path.encode("latin-1", "replace") + b"\n"
            self._send(200, body, "text/plain", head=head)

        else:
            self._send(404, b"not found: " + path.encode("latin-1", "replace") + b"\n",
                      "text/plain", head=head)

    def _send(
        self,
        status: int,
        body: bytes,
        content_type: str = "text/plain",
        extra_headers: tuple[tuple[str, str], ...] = (),
        head: bool = False,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()

        if head or not body:
            return

        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def _send_chunked(self, head: bool) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        if head:
            return

        chunks = (b"aaa", b"bbb", b"ccc")
        try:
            self.wfile.flush()
            for chunk in chunks:
                # Raw socket writes so the three chunks really arrive
                # separately instead of being coalesced by wfile buffering.
                self.connection.sendall(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                time.sleep(0.05)
            self.connection.sendall(b"0\r\n\r\n")
        except OSError:
            self.close_connection = True

    def _send_split_bad(self) -> None:
        # A malformed status line split in the middle of the line, followed by
        # a body.  The first write ends inside the status line, so nginx's
        # status parser returns NGX_AGAIN with r->state != 0; the following
        # write makes it fail and forces the HTTP/0.9 fallback.  With the
        # nginx 39d7d0ba fix the whole first chunk is preserved in the body;
        # without it the already parsed prefix is lost and the body starts
        # with "XYZ".
        self.close_connection = True
        try:
            self.connection.sendall(b"HTTP/1.1 ")
            time.sleep(0.3)
            self.connection.sendall(b"XYZ\r\n")
            time.sleep(0.3)
            self.connection.sendall(b"\r\nBODY")
        except OSError:
            pass

    def _send_split_good(self) -> None:
        # A valid response split across writes with delays.  nginx must
        # reassemble it and return 200 with body "OK!!".
        self.close_connection = True
        try:
            self.connection.sendall(b"HTTP/1.1 200 OK\r\n")
            time.sleep(0.3)
            self.connection.sendall(b"Content-Length: 4\r\n")
            time.sleep(0.3)
            self.connection.sendall(b"\r\nOK!!")
        except OSError:
            pass


class _ThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request: object, client_address: object) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionError, TimeoutError, ssl.SSLError)):
            return
        print(f"backend: error handling {client_address}: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)


class TLSHTTPServer(_ThreadingHTTPServer):
    """HTTP server that performs a TLS handshake for every accepted socket."""

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        ssl_context: ssl.SSLContext,
    ) -> None:
        self.ssl_context = ssl_context
        super().__init__(server_address, handler_class)

    def get_request(self) -> tuple[socket.socket, tuple]:
        sock, addr = super().get_request()
        try:
            sock.settimeout(10.0)
            tls_sock = self.ssl_context.wrap_socket(sock, server_side=True)
            tls_sock.settimeout(None)
            return tls_sock, addr
        except OSError:
            try:
                sock.close()
            except OSError:
                pass
            raise


class RawPlainServer(socketserver.ThreadingTCPServer):
    """Small threaded server used for the 18444 plaintext-on-TLS-port test."""

    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request: object, client_address: object) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionError, TimeoutError, OSError)):
            return
        print(f"backend: raw listener error for {client_address}: {exc}",
              file=sys.stderr)


class RawPlainHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.settimeout(5.0)
        try:
            # Read *some* request bytes (a TLS ClientHello in the premature
            # test) and then answer with plaintext HTTP without any TLS.
            self.request.recv(4096)
        except OSError:
            pass

        try:
            self.request.sendall(PLAIN_ON_TLS_PORT_RESPONSE)
        except OSError:
            pass


def port_number(value: str) -> int:
    try:
        port = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid port: {value!r}") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError(f"port out of range: {port}")
    return port


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Controllable HTTP/1.1 backend for socks nginx tests",
    )
    parser.add_argument("--http-port", type=port_number, default=DEFAULT_HTTP_PORT,
                        help=f"plain HTTP port (default: {DEFAULT_HTTP_PORT})")
    parser.add_argument("--tls-port", type=port_number, default=DEFAULT_TLS_PORT,
                        help=f"TLS HTTP port (default: {DEFAULT_TLS_PORT})")
    parser.add_argument("--plain-port", type=port_number, default=DEFAULT_PLAIN_PORT,
                        help=f"plaintext-on-TLS-port listener (default: {DEFAULT_PLAIN_PORT})")
    parser.add_argument("--cert", help="TLS certificate file; needs --key")
    parser.add_argument("--key", help="TLS private key file; needs --cert")
    args = parser.parse_args(argv)

    if bool(args.cert) != bool(args.key):
        parser.error("--cert and --key must be supplied together")
    return args


def make_ssl_context(cert: str, key: str) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    servers: list[socketserver.BaseServer] = []
    stop = threading.Event()

    def request_stop(_signum: int, _frame: object) -> None:
        stop.set()

    import signal

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    try:
        http_server = _ThreadingHTTPServer(
            ("127.0.0.1", args.http_port), BackendHandler
        )
        servers.append(http_server)

        if args.cert and args.key:
            try:
                ssl_context = make_ssl_context(args.cert, args.key)
            except (OSError, ssl.SSLError) as exc:
                print(f"backend: cannot load TLS cert/key: {exc}",
                      file=sys.stderr, flush=True)
                return 2
            tls_server = TLSHTTPServer(
                ("127.0.0.1", args.tls_port), BackendHandler, ssl_context
            )
            servers.append(tls_server)
        else:
            print("backend: --cert/--key not supplied; TLS listener disabled",
                  file=sys.stderr, flush=True)

        raw_server = RawPlainServer(
            ("127.0.0.1", args.plain_port), RawPlainHandler
        )
        servers.append(raw_server)
    except OSError as exc:
        print(f"backend: cannot bind listener: {exc}", file=sys.stderr, flush=True)
        for server in servers:
            server.server_close()
        return 1

    threads: list[threading.Thread] = []
    for server in servers:
        thread = threading.Thread(
            target=server.serve_forever,
            kwargs={"poll_interval": 0.2},
            daemon=True,
            name=f"backend-{server.server_address[1]}",
        )
        thread.start()
        threads.append(thread)

    print("ready", flush=True)

    try:
        while not stop.wait(0.2):
            pass
    except KeyboardInterrupt:
        stop.set()

    for server in servers:
        try:
            server.shutdown()
        except Exception:  # noqa: BLE001 - best effort during shutdown
            pass
        try:
            server.server_close()
        except Exception:  # noqa: BLE001
            pass

    for thread in threads:
        thread.join(timeout=2.0)

    return 0


if __name__ == "__main__":
    sys.exit(main())
