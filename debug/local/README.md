# Local end-to-end harness (no docker)

This directory contains a self-contained test stand for the module, for
environments where the docker-based `make ci`/`make test` flow is not
available.  It uses only python3 (standard library), curl and openssl.

## Components

| File | Purpose |
|---|---|
| `socks5_proxy.py` | Minimal SOCKS5 server: no-auth on `127.0.0.1:11080`, RFC 1929 user/pass (`testuser`/`testpass`) on `127.0.0.1:11081` |
| `backend.py` | Controllable HTTP backend on `127.0.0.1:18080`, TLS on `:18443`, plaintext-on-TLS-port on `:18444`; endpoints for every regression |
| `nginx-local.conf.template` | nginx config template; `run.sh` replaces `__RUNTIME__` and writes the module loader |
| `run.sh` | Starts everything, runs the checks, prints `PASS`/`FAIL` lines and a summary |

## Usage

```bash
# Build the module first (see the Makefile targets), e.g. against .ref/build:
cd src/debug/local
BUILD_DIR=/workspace/nginx-mod-socks/.ref/build bash run.sh

# Or run against an ASan/UBSan build:
BUILD_DIR=/workspace/nginx-mod-socks/.ref/build-asan bash run.sh
```

`BUILD_DIR` must contain `nginx` and `ngx_http_socks_module.so`.
`RUNTIME_DIR` (default `/tmp/socks-local`) holds the rendered config, the
generated certificate and the logs.  `./run.sh --render-only` only renders the
config and runs `nginx -t` when the binary is available.

Exit status is non-zero if any check fails.

## Checks

| Check | What it verifies |
|---|---|
| `basic`, `auth`, `auth-bad`, `ssl` | SOCKS5 proxying, RFC 1929 auth, TLS through the tunnel |
| `premature` | plaintext response from an SSL backend is rejected (502) |
| `charset-bad`, `charset-good` | malformed/valid `charset` handling, worker survives |
| `big`, `chunked` | large bodies and chunked responses (terminator length) |
| `split-bad`, `split-good` | status line split across reads, including the HTTP/0.9 fallback |
| `loc-len` | `try_files` shrinks `r->uri` below the location prefix, upstream still gets `/echo` |
| `sequential`, `concurrent` | keepalive and parallel requests |
| `cache`, `xaccel-cache` | `proxy_cache`, `Cache-Control` overflow, X-Accel-Redirect served from a cache file |
| `store` | `proxy_store` |
| `guard-v2`, `guard-trailers` | `nginx -t` rejects `proxy_http_version 2` / `proxy_pass_trailers on` together with `socks_pass`, and accepts them without it |
| `asan-log` | no AddressSanitizer report in the nginx log when the binary is instrumented |

## Harness accommodations

- **Non-default target ports.** The module sends the proxy `Host` header as
  the SOCKS target, and that header contains `:port` for non-default ports.
  Since the harness backends listen on unprivileged ports, `socks5_proxy.py`
  strips the duplicated `:port` suffix from DOMAINNAME targets.  This is a
  test-only workaround for a pre-existing module limitation (the same request
  fails against a real SOCKS server); it is not a module fix.
- **ASan dynamic modules.** `ASAN_OPTIONS` disables `detect_odr_violation`
  because `ngx_module_names` is defined both in the binary and in the module
  `.so`, matching the project's `test-asan` target.
- **UBSan.** Reports outside the module (nginx core) are reported as `SKIP`,
  not `FAIL`; reports that mention `ngx_http_socks` fail the run.
