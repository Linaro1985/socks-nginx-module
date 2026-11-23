# Changelog

## Unreleased

### Security

- Fixed an integer underflow when parsing the `charset` parameter of the upstream `Content-Type` header: a response with `charset="` made the charset length `SIZE_MAX` and led to an out-of-bounds write in `ngx_http_header_filter` (nginx commit `06c30ec2`).
- Added buffer overrun protection to request header generation: `proxy_set_header` values are now written with `ngx_http_script_check_length()` checks and scripts are bounded by their computed lengths (nginx commit `326b17b0`).

### Bugfixes

- Fixed a segmentation fault when the request URI became shorter than the location prefix, e.g. after a `try_files` rewrite (nginx commit `bcb41c91`).
- Fixed parsing of a response status line that is split across reads: the already processed part is no longer lost when the parser falls back to the HTTP/0.9 handling (nginx commit `39d7d0ba`).
- Fixed mixed responses when the read event handler runs before the write event handler and the first response triggers a next upstream: `ngx_http_upstream_reinit()` is now called when a response has been received as well (nginx commit `d7a24947`).
- A plain text response received before the TLS handshake on an https upstream is no longer parsed as an upstream response (nginx commit `a59f5f09`).
- Fixed "request count is zero" alerts and possible segmentation faults when `X-Accel-Redirect` is served from a cache file and the header was ignored by `proxy_ignore_headers` during caching (nginx commit `7fd14d52`).
- Overflow of `Cache-Control` delta-seconds values is now clamped to the greatest positive integer instead of wrapping around (nginx commit `8255bd29`).
- An empty path produced by `proxy_store` variables is no longer passed to `ngx_ext_rename_file()` (nginx commit `a448dd52`).
- `u->peer.local` is reset when the local address complex value evaluates to an empty or invalid string (nginx commit `364a94ec`).
- The chunked response terminator length is now 5 (`"0\r\n\r\n"`) instead of 3.

### Compatibility

- `proxy_http_version 2` and `proxy_pass_trailers on` are now rejected at configuration time where `socks_pass` is in effect: the module's copied proxy code does not support HTTP/2 to upstreams or trailer forwarding. Both directives keep working as in nginx where `socks_pass` is not used.
- Dropped support for nginx < 1.30. The module now uses the proxy module structures and helpers that nginx exports since 1.29.4 (`ngx_http_proxy_module.h`) instead of its own copy, whose layout had drifted (`host_set` was added to `ngx_http_proxy_loc_conf_t`), causing a segfault in `ngx_http_proxy_create_request` on nginx 1.30.
- `ngx_http_proxy_ctx_t.legacy` is set so that the default `Host` header (`$proxy_internal_host`) is populated.

## 2.1 - 2026-07-29

### Compatibility

- Added support for nginx stable branches 1.28.x and 1.30.x while retaining compatibility with 1.26.x ([#22](https://github.com/dannote/socks-nginx-module/pull/22)).
