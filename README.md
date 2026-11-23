# socks-nginx-module

An nginx module that adds SOCKS5 proxy support to `proxy_pass`.

## Features

- Route upstream traffic through a SOCKS5 proxy
- Username/password authentication (RFC 1929)
- SSL to upstream through the SOCKS tunnel (`proxy_pass https://...`)
- IPv4, IPv6, and domain name address types

## Building

Requires nginx **1.30 or newer** (the module uses the proxy module structures that nginx exports since 1.29.4) and PCRE2.

```bash
git clone https://github.com/dannote/socks-nginx-module
wget https://nginx.org/download/nginx-1.30.4.tar.gz
tar -xzf nginx-1.30.4.tar.gz
cd nginx-1.30.4

./configure --add-dynamic-module=../socks-nginx-module
make
make install
```

## Directives

### `socks_pass`

Specifies the SOCKS5 proxy to route upstream traffic through. Must follow a `proxy_pass` directive.

```nginx
socks_pass socks5://proxy:1080;
```

Credentials can be provided inline:

```nginx
socks_pass socks5://user:password@proxy:1080;
```

### `socks_username` / `socks_password`

Set SOCKS5 authentication credentials separately from the URL.

```nginx
socks_pass socks5://proxy:1080;
socks_username myuser;
socks_password mypassword;
```

## Configuration examples

### HTTP through SOCKS

```nginx
location / {
    proxy_pass http://httpbin.org/get;
    socks_pass socks5://proxy:1080;
}
```

### HTTPS through SOCKS

```nginx
location / {
    proxy_pass https://httpbin.org/get;
    proxy_ssl_server_name on;
    socks_pass socks5://proxy:1080;
}
```

### With authentication

```nginx
location / {
    proxy_pass http://httpbin.org/get;
    socks_pass socks5://user:password@proxy:1080;
}
```

## Limitations

The module carries its own copies of the nginx proxy and upstream code, so a few
newer nginx features are not available where `socks_pass` is used:

- `proxy_http_version 2` is rejected at configuration time. Requests are sent
  to the upstream over HTTP/1.0 or HTTP/1.1.
- `proxy_pass_trailers on` is rejected at configuration time; upstream trailers
  are not forwarded.
- Early Hints (103) responses from an upstream are treated as final responses.
- Upstream retries (`proxy_next_upstream`) reconnect to the SOCKS proxy without
  repeating the SOCKS handshake, so they do not work through the tunnel; use
  `proxy_next_upstream off` for locations that use `socks_pass`.

Both rejected directives keep working exactly as in nginx in locations that do
not use `socks_pass`.

> **Known issue (pre-existing).** The target host is taken from the proxy `Host`
> header, which includes a non-default port (`host:port`). A `proxy_pass` URL
> with an explicit port other than 80/443 therefore sends an invalid SOCKS
> target and fails with "host unreachable". This is unrelated to the nginx
> 1.30 synchronization and is not fixed here.

## Development

### Running tests

```bash
make ci
```

Individual targets: `build`, `build-clang`, `build-asan`, `test`, `test-asan`, `lint`, `cppcheck`, `format`.

### Debugging

```bash
cd debug
docker compose run --service-ports nginx

(gdb) set follow-fork-mode child
(gdb) run
```
