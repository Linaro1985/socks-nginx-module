# Changelog

## Unreleased

### Compatibility

- Dropped support for nginx < 1.30. The module now uses the proxy module structures and helpers that nginx exports since 1.29.4 (`ngx_http_proxy_module.h`) instead of its own copy, whose layout had drifted (`host_set` was added to `ngx_http_proxy_loc_conf_t`), causing a segfault in `ngx_http_proxy_create_request` on nginx 1.30.
- `ngx_http_proxy_ctx_t.legacy` is set so that the default `Host` header (`$proxy_internal_host`) is populated.

## 2.1 - 2026-07-29

### Compatibility

- Added support for nginx stable branches 1.28.x and 1.30.x while retaining compatibility with 1.26.x ([#22](https://github.com/dannote/socks-nginx-module/pull/22)).
