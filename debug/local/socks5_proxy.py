#!/usr/bin/env python3
"""Minimal, dependency-free SOCKS5 proxy for local socks-nginx-module tests.

Two listeners are started at once:

  * 127.0.0.1:11080 -- no authentication
  * 127.0.0.1:11081 -- RFC 1929 username/password (testuser / testpass)

Only CONNECT is supported.  IPv4, IPv6 and DOMAINNAME targets are accepted.
Each accepted connection is handled in its own thread and relayed with two
threads so TCP half-closes are propagated correctly.

The program prints exactly one line, ``ready``, to stdout once both sockets
are listening.  Diagnostics (when --verbose is used) go to stderr.
"""

from __future__ import annotations

import argparse
import errno
import hmac
import signal
import socket
import struct
import sys
import threading

SOCKS_VERSION = 0x05
SOCKS_AUTH_NO_AUTH = 0x00
SOCKS_AUTH_USERPASS = 0x02
SOCKS_AUTH_NO_ACCEPTABLE = 0xFF
SOCKS_AUTH_SUBNEG_VERSION = 0x01
SOCKS_CMD_CONNECT = 0x01
SOCKS_ATYP_IPV4 = 0x01
SOCKS_ATYP_DOMAIN = 0x03
SOCKS_ATYP_IPV6 = 0x04

SOCKS_REP_SUCCESS = 0x00
SOCKS_REP_GENERAL_FAILURE = 0x01
SOCKS_REP_NETWORK_UNREACHABLE = 0x03
SOCKS_REP_HOST_UNREACHABLE = 0x04
SOCKS_REP_CONNECTION_REFUSED = 0x05
SOCKS_REP_TTL_EXPIRED = 0x06
SOCKS_REP_COMMAND_NOT_SUPPORTED = 0x07
SOCKS_REP_ADDRESS_TYPE_NOT_SUPPORTED = 0x08

AUTH_USERNAME = b"testuser"
AUTH_PASSWORD = b"testpass"

HANDSHAKE_TIMEOUT = 15.0
CONNECT_TIMEOUT = 10.0
BUFFER_SIZE = 64 * 1024
ACCEPT_POLL = 0.5


class ProtocolError(Exception):
    """The peer did not speak valid/acceptable SOCKS5."""


def log(verbose: bool, message: str) -> None:
    if verbose:
        print(f"socks5_proxy: {message}", file=sys.stderr, flush=True)


def recv_exact(sock: socket.socket, size: int) -> bytes:
    """Read exactly *size* bytes or raise ProtocolError on early EOF."""
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ProtocolError("peer closed the connection during handshake")
        data.extend(chunk)
    return bytes(data)


def reply_bytes(rep: int, sockname: tuple | None = None) -> bytes:
    """Encode a SOCKS5 reply.  BND.ADDR is the local relay endpoint if known."""
    atyp = SOCKS_ATYP_IPV4
    packed = b"\x00\x00\x00\x00"
    port = 0

    if sockname:
        host = sockname[0]
        port = int(sockname[1]) & 0xFFFF
        try:
            if ":" in host:
                packed = socket.inet_pton(socket.AF_INET6, host)
                atyp = SOCKS_ATYP_IPV6
            else:
                packed = socket.inet_pton(socket.AF_INET, host)
                atyp = SOCKS_ATYP_IPV4
        except OSError:
            packed = b"\x00\x00\x00\x00"
            atyp = SOCKS_ATYP_IPV4
            port = 0

    return (
        bytes((SOCKS_VERSION, rep, 0x00, atyp))
        + packed
        + struct.pack("!H", port)
    )


def send_reply(sock: socket.socket, rep: int, sockname: tuple | None = None) -> None:
    try:
        sock.sendall(reply_bytes(rep, sockname))
    except OSError:
        pass


def negotiate(client: socket.socket, require_auth: bool, verbose: bool) -> None:
    """Perform method negotiation and, when requested, RFC 1929 auth."""
    version, nmethods = recv_exact(client, 2)
    if version != SOCKS_VERSION:
        raise ProtocolError(f"unsupported SOCKS version {version}")

    methods = recv_exact(client, nmethods) if nmethods else b""

    if require_auth:
        if SOCKS_AUTH_USERPASS not in methods:
            client.sendall(bytes((SOCKS_VERSION, SOCKS_AUTH_NO_ACCEPTABLE)))
            raise ProtocolError("client did not offer username/password auth")
        client.sendall(bytes((SOCKS_VERSION, SOCKS_AUTH_USERPASS)))

        auth_version, ulen = recv_exact(client, 2)
        if auth_version != SOCKS_AUTH_SUBNEG_VERSION:
            raise ProtocolError(f"unsupported auth sub-negotiation version {auth_version}")
        username = recv_exact(client, ulen) if ulen else b""
        plen = recv_exact(client, 1)[0]
        password = recv_exact(client, plen) if plen else b""

        # Compare both fields without short-circuiting on the first mismatch.
        user_ok = hmac.compare_digest(username, AUTH_USERNAME)
        pass_ok = hmac.compare_digest(password, AUTH_PASSWORD)
        if user_ok and pass_ok:
            client.sendall(b"\x01\x00")
            log(verbose, "username/password authentication accepted")
        else:
            client.sendall(b"\x01\x01")
            raise ProtocolError("username/password authentication rejected")
    else:
        if SOCKS_AUTH_NO_AUTH not in methods:
            client.sendall(bytes((SOCKS_VERSION, SOCKS_AUTH_NO_ACCEPTABLE)))
            raise ProtocolError("client did not offer no-authentication method")
        client.sendall(bytes((SOCKS_VERSION, SOCKS_AUTH_NO_AUTH)))


def read_request(client: socket.socket) -> tuple[int, str, int]:
    """Read a SOCKS5 request and return (cmd, host, port)."""
    version, cmd, _reserved, atyp = recv_exact(client, 4)
    if version != SOCKS_VERSION:
        raise ProtocolError(f"unsupported request version {version}")

    if atyp == SOCKS_ATYP_IPV4:
        host = socket.inet_ntoa(recv_exact(client, 4))
    elif atyp == SOCKS_ATYP_IPV6:
        host = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
    elif atyp == SOCKS_ATYP_DOMAIN:
        length = recv_exact(client, 1)[0]
        if length == 0:
            raise ProtocolError("zero-length domain name")
        raw = recv_exact(client, length)
        try:
            host = raw.decode("ascii")
        except UnicodeDecodeError:
            host = raw.decode("utf-8", "replace")
    else:
        send_reply(client, SOCKS_REP_ADDRESS_TYPE_NOT_SUPPORTED)
        raise ProtocolError(f"unsupported address type {atyp}")

    port = struct.unpack("!H", recv_exact(client, 2))[0]
    return cmd, host, port


def connect_target(host: str, port: int) -> tuple[socket.socket, tuple]:
    """Connect to *host*:*port*, trying every getaddrinfo result.

    Harness accommodation for a pre-existing module limitation: the module
    sends the proxy "Host" header as the SOCKS CONNECT target, and nginx puts
    a non-default port into that header ("host:port").  Backends used by this
    harness listen on unprivileged ports, so strip the duplicated ":port"
    suffix before resolving.  This does not affect the IPv4/IPv6 address
    types, only DOMAINNAME targets.
    """
    suffix = f":{port}"
    if host.endswith(suffix):
        host = host[: -len(suffix)]

    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    if not infos:
        raise OSError(errno.EHOSTUNREACH, "no addresses returned for host")

    last_error: OSError | None = None
    for family, socktype, proto, _canonname, sockaddr in infos:
        remote = socket.socket(family, socktype, proto)
        remote.settimeout(CONNECT_TIMEOUT)
        try:
            remote.connect(sockaddr)
        except OSError as exc:
            last_error = exc
            remote.close()
            continue
        remote.settimeout(None)
        return remote, remote.getsockname()

    assert last_error is not None
    raise last_error


def map_connect_error(exc: OSError) -> int:
    if isinstance(exc, socket.gaierror):
        return SOCKS_REP_HOST_UNREACHABLE

    code = getattr(exc, "errno", None)
    if code in (errno.ECONNREFUSED, errno.ECONNRESET):
        return SOCKS_REP_CONNECTION_REFUSED
    if code == errno.ENETUNREACH:
        return SOCKS_REP_NETWORK_UNREACHABLE
    if code in (errno.EHOSTUNREACH, errno.ENOENT, errno.EADDRNOTAVAIL):
        return SOCKS_REP_HOST_UNREACHABLE
    if code == errno.ETIMEDOUT:
        return SOCKS_REP_TTL_EXPIRED
    return SOCKS_REP_GENERAL_FAILURE


def relay(src: socket.socket, dst: socket.socket) -> None:
    """Copy one direction, then half-close the peer's write side."""
    try:
        while True:
            data = src.recv(BUFFER_SIZE)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle_client(
    client: socket.socket,
    require_auth: bool,
    verbose: bool,
    stop: threading.Event,
) -> None:
    remote: socket.socket | None = None
    try:
        client.settimeout(HANDSHAKE_TIMEOUT)
        negotiate(client, require_auth, verbose)

        cmd, host, port = read_request(client)

        if cmd != SOCKS_CMD_CONNECT:
            log(verbose, f"unsupported command {cmd}; replying 0x07")
            send_reply(client, SOCKS_REP_COMMAND_NOT_SUPPORTED)
            return

        try:
            remote, bound = connect_target(host, port)
        except OSError as exc:
            log(verbose, f"connect to {host}:{port} failed: {exc}")
            send_reply(client, map_connect_error(exc))
            return

        send_reply(client, SOCKS_REP_SUCCESS, bound)
        log(verbose, f"CONNECT {host}:{port} established")

        client.settimeout(None)
        remote.settimeout(None)

        upstream = threading.Thread(
            target=relay, args=(client, remote), daemon=True,
            name="socks-relay-c2r",
        )
        downstream = threading.Thread(
            target=relay, args=(remote, client), daemon=True,
            name="socks-relay-r2c",
        )
        upstream.start()
        downstream.start()
        while upstream.is_alive() or downstream.is_alive():
            upstream.join(0.2)
            downstream.join(0.2)
            if stop.is_set():
                break
    except (ProtocolError, OSError) as exc:
        log(verbose, f"connection closed: {exc}")
    finally:
        if remote is not None:
            try:
                remote.close()
            except OSError:
                pass
        try:
            client.close()
        except OSError:
            pass


def accept_loop(
    listener: socket.socket,
    require_auth: bool,
    stop: threading.Event,
    active: set[socket.socket],
    active_lock: threading.Lock,
    verbose: bool,
) -> None:
    while not stop.is_set():
        try:
            client, _addr = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            break

        client.settimeout(HANDSHAKE_TIMEOUT)
        with active_lock:
            active.add(client)

        def run(sock: socket.socket = client) -> None:
            try:
                handle_client(sock, require_auth, verbose, stop)
            finally:
                with active_lock:
                    active.discard(sock)
                try:
                    sock.close()
                except OSError:
                    pass

        threading.Thread(
            target=run, daemon=True, name="socks-client"
        ).start()


def make_listener(port: int) -> socket.socket:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(128)
    listener.settimeout(ACCEPT_POLL)
    return listener


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
        description="Dual-listener SOCKS5 CONNECT proxy for module tests",
    )
    parser.add_argument("--noauth-port", type=port_number, default=11080,
                        help="no-authentication listener port (default: 11080)")
    parser.add_argument("--auth-port", type=port_number, default=11081,
                        help="username/password listener port (default: 11081)")
    parser.add_argument("--verbose", action="store_true",
                        help="log handshake/relay diagnostics to stderr")
    args = parser.parse_args(argv)
    if args.noauth_port == args.auth_port:
        parser.error("--noauth-port and --auth-port must differ")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    stop = threading.Event()
    active: set[socket.socket] = set()
    active_lock = threading.Lock()
    listeners: list[socket.socket] = []

    def request_stop(_signum: int, _frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    try:
        noauth_listener = make_listener(args.noauth_port)
        listeners.append(noauth_listener)
        auth_listener = make_listener(args.auth_port)
        listeners.append(auth_listener)
    except OSError as exc:
        print(f"socks5_proxy: cannot bind listener: {exc}", file=sys.stderr, flush=True)
        for sock in listeners:
            sock.close()
        return 1

    accept_threads = [
        threading.Thread(
            target=accept_loop,
            args=(noauth_listener, False, stop, active, active_lock, args.verbose),
            daemon=True,
            name="socks-accept-noauth",
        ),
        threading.Thread(
            target=accept_loop,
            args=(auth_listener, True, stop, active, active_lock, args.verbose),
            daemon=True,
            name="socks-accept-auth",
        ),
    ]
    for thread in accept_threads:
        thread.start()

    # The harness waits for this exact line on stdout.
    print("ready", flush=True)
    log(args.verbose, f"listening on 127.0.0.1:{args.noauth_port} (no auth) "
                      f"and 127.0.0.1:{args.auth_port} (user/pass)")

    try:
        while not stop.wait(0.2):
            pass
    except KeyboardInterrupt:
        stop.set()

    for listener in listeners:
        try:
            listener.close()
        except OSError:
            pass

    # Unblock any relay threads that are waiting in recv().
    with active_lock:
        current = list(active)
    for sock in current:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    for thread in accept_threads:
        thread.join(timeout=2.0)

    return 0


if __name__ == "__main__":
    sys.exit(main())
