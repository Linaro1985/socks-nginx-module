#!/usr/bin/env bash
#
# Local end-to-end harness for socks-nginx-module.
#
#   ./run.sh                 start everything and run all checks
#   ./run.sh --render-only   render nginx-local.conf; run nginx -t if possible
#
# Environment:
#   BUILD_DIR    directory containing nginx and ngx_http_socks_module.so
#                (default: /workspace/nginx-mod-socks/.ref/build)
#   RUNTIME_DIR  disposable runtime directory (default: /tmp/socks-local)
#   NGINX_SRC    nginx source tree (informational only; default:
#                /workspace/nginx-mod-socks/.ref/nginx-1.30.7)
#   WITH_GUARD_LOCATIONS=1  put /version2 and /trailers into guard.conf.
#                With a correctly guarded module this makes nginx -t fail,
#                which is the point; use --render-only to inspect it.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-/workspace/nginx-mod-socks/.ref/build}"
RUNTIME_DIR="${RUNTIME_DIR:-/tmp/socks-local}"
NGINX_SRC="${NGINX_SRC:-/workspace/nginx-mod-socks/.ref/nginx-1.30.7}"
WITH_GUARD_LOCATIONS="${WITH_GUARD_LOCATIONS:-}"

if [[ -d "$BUILD_DIR" ]]; then
    BUILD_DIR="$(cd -- "$BUILD_DIR" && pwd)"
fi

RENDER_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --render-only)
            RENDER_ONLY=1
            ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

NGINX_BIN="$BUILD_DIR/nginx"
MODULE_SO="$BUILD_DIR/ngx_http_socks_module.so"

NOAUTH_PORT=11080
AUTH_PORT=11081
HTTP_PORT=18080
TLS_PORT=18443
PLAIN_PORT=18444
NGINX_PORT=18081
XACCEL_PORT=18082
GUARD_PORT=18083

RUNTIME_CONF="$RUNTIME_DIR/nginx-local.conf"
LOAD_MODULE_CONF="$RUNTIME_DIR/load_module.conf"
GUARD_CONF="$RUNTIME_DIR/guard.conf"
NGINX_ERROR_LOG="$RUNTIME_DIR/nginx-error.log"
SOCKS_LOG="$RUNTIME_DIR/socks5.log"
BACKEND_LOG="$RUNTIME_DIR/backend.log"
CERT="$RUNTIME_DIR/test-ssl.crt"
KEY="$RUNTIME_DIR/test-ssl.key"
CHECK_TMP="$RUNTIME_DIR/check-tmp"

PASS=0
FAIL=0
SKIP=0
FAILED_CHECKS=()
NGINX_STARTED=0
NGINX_PID=""
SOCKS_PID=""
BACKEND_PID=""
RUNTIME_VERSION2=0
VERSION2_SKIP_REASON=""

GUARD_V2_SUPPORTED=0
GUARD_V2_REJECTS=0
GUARD_V2_STATUS=""
GUARD_V2_DETAIL=""
GUARD_TRAILERS_REJECTS=0
GUARD_TRAILERS_STATUS=""
GUARD_TRAILERS_DETAIL=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
    return 0
}

fail() {
    local name="$1"
    local detail="$2"
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$name")
    printf 'FAIL: %s: %s\n' "$name" "$detail"
    if [[ ${NGINX_STARTED:-0} -eq 1 && -s "$NGINX_ERROR_LOG" ]]; then
        printf '  --- nginx-error.log (last 20 lines) ---\n' >&2
        tail -n 20 "$NGINX_ERROR_LOG" | sed 's/^/  /' >&2 || true
    fi
    return 0
}

skip() {
    SKIP=$((SKIP + 1))
    printf 'SKIP: %s: %s\n' "$1" "$2"
    return 0
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e

    if [[ -n "${NGINX_PID:-}" ]]; then
        if kill -0 "$NGINX_PID" 2>/dev/null; then
            kill -QUIT "$NGINX_PID" 2>/dev/null
            local i
            for ((i = 0; i < 50; i++)); do
                kill -0 "$NGINX_PID" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$NGINX_PID" 2>/dev/null; then
                kill -TERM "$NGINX_PID" 2>/dev/null
                sleep 0.5
            fi
            if kill -0 "$NGINX_PID" 2>/dev/null; then
                kill -KILL "$NGINX_PID" 2>/dev/null
            fi
        fi
        wait "$NGINX_PID" 2>/dev/null || true
    fi

    local pid
    for pid in "${BACKEND_PID:-}" "${SOCKS_PID:-}"; do
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            local i
            for ((i = 0; i < 30; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null
            fi
        fi
        wait "$pid" 2>/dev/null || true
    done

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_tools() {
    local tool
    for tool in python3 curl openssl; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "required tool not found in PATH: $tool"
    done
}

prepare_runtime() {
    [[ -n "$RUNTIME_DIR" ]] || die "RUNTIME_DIR must not be empty"
    [[ "$RUNTIME_DIR" != "/" ]] || die "refusing to use / as RUNTIME_DIR"
    case "$RUNTIME_DIR" in
        /tmp|/var|/usr|/home|"$HOME")
            die "refusing to use unsafe RUNTIME_DIR: $RUNTIME_DIR"
            ;;
    esac

    if [[ "$RUNTIME_DIR" != /* ]]; then
        RUNTIME_DIR="$PWD/$RUNTIME_DIR"
    fi
    mkdir -p -- "$RUNTIME_DIR"
    RUNTIME_DIR="$(cd -- "$RUNTIME_DIR" && pwd)"

    # Re-check after canonicalisation so that relative ".." style paths
    # cannot turn into the current/project directory behind our back.
    case "$RUNTIME_DIR" in
        /|/tmp|/var|/usr|/home|"$HOME"|"$PWD"|"$SCRIPT_DIR")
            die "refusing to use unsafe RUNTIME_DIR: $RUNTIME_DIR"
            ;;
    esac

    # Configuration and log paths are derived after canonicalisation.
    RUNTIME_CONF="$RUNTIME_DIR/nginx-local.conf"
    LOAD_MODULE_CONF="$RUNTIME_DIR/load_module.conf"
    GUARD_CONF="$RUNTIME_DIR/guard.conf"
    NGINX_ERROR_LOG="$RUNTIME_DIR/nginx-error.log"
    SOCKS_LOG="$RUNTIME_DIR/socks5.log"
    BACKEND_LOG="$RUNTIME_DIR/backend.log"
    CERT="$RUNTIME_DIR/test-ssl.crt"
    KEY="$RUNTIME_DIR/test-ssl.key"
    CHECK_TMP="$RUNTIME_DIR/check-tmp"

    log "runtime directory: $RUNTIME_DIR"
    log "build directory:   $BUILD_DIR"
    log "nginx source:      $NGINX_SRC"

    # Remove only well-known harness artifacts, never the whole runtime dir.
    rm -rf -- "$RUNTIME_DIR/cache" "$RUNTIME_DIR/store" "$RUNTIME_DIR/tmp" \
              "$CHECK_TMP"
    mkdir -p -- "$RUNTIME_DIR/cache" \
                "$RUNTIME_DIR/store" \
                "$RUNTIME_DIR/logs" \
                "$RUNTIME_DIR/www" \
                "$RUNTIME_DIR/tmp/client_body" \
                "$RUNTIME_DIR/tmp/proxy" \
                "$RUNTIME_DIR/tmp/fastcgi" \
                "$RUNTIME_DIR/tmp/uwsgi" \
                "$RUNTIME_DIR/tmp/scgi" \
                "$CHECK_TMP"

    # Existing file used by the loc_len regression: try_files replaces
    # r->uri with "/abc", which is shorter than the "/ttll/" prefix.
    printf 'x\n' > "$RUNTIME_DIR/www/abc"

    rm -f -- "$RUNTIME_CONF" "$LOAD_MODULE_CONF" "$GUARD_CONF" \
             "$NGINX_ERROR_LOG" "$SOCKS_LOG" "$BACKEND_LOG" \
             "$RUNTIME_DIR/nginx.pid" "$RUNTIME_DIR/guard-probe.pid" \
             "$RUNTIME_DIR"/guard-*.conf
}

write_load_module_conf() {
    printf 'load_module "%s";\n' "$MODULE_SO" > "$LOAD_MODULE_CONF"
}

write_guard_conf() {
    local mode="$1"
    : > "$GUARD_CONF"

    if [[ "$mode" == "empty" ]]; then
        return 0
    fi

    {
        printf 'server {\n'
        printf '    listen 127.0.0.1:%s;\n' "$GUARD_PORT"
        printf '    server_name localhost;\n'

        if [[ "$mode" == "both" || "$mode" == "version2" ]]; then
            cat <<'EOF'
    location = /version2 {
        proxy_next_upstream off;
        proxy_connect_timeout 3s;
        proxy_send_timeout 3s;
        proxy_read_timeout 3s;
        proxy_pass http://127.0.0.1:18080/ok;
        proxy_http_version 2;
        socks_pass socks5://127.0.0.1:11080;
    }
EOF
        fi

        if [[ "$mode" == "both" || "$mode" == "trailers" ]]; then
            cat <<'EOF'
    location = /trailers {
        proxy_next_upstream off;
        proxy_connect_timeout 3s;
        proxy_send_timeout 3s;
        proxy_read_timeout 3s;
        proxy_pass http://127.0.0.1:18080/ok;
        proxy_pass_trailers on;
        socks_pass socks5://127.0.0.1:11080;
    }
EOF
        fi

        printf '}\n'
    } > "$GUARD_CONF"
}

render_config() {
    local runtime_escaped="$RUNTIME_DIR"
    runtime_escaped="${runtime_escaped//\\/\\\\}"
    runtime_escaped="${runtime_escaped//&/\\&}"
    runtime_escaped="${runtime_escaped//|/\\|}"

    sed "s|__RUNTIME__|$runtime_escaped|g" \
        "$SCRIPT_DIR/nginx-local.conf.template" > "$RUNTIME_CONF"
}

nginx_test_capture() {
    local conf="$1"
    NGINX_TEST_RC=0
    NGINX_TEST_OUTPUT="$(
        ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1:detect_odr_violation=0}" \
        UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=0}" \
            "$NGINX_BIN" -t -p "$RUNTIME_DIR" -c "$conf" 2>&1
    )" || NGINX_TEST_RC=$?
}

summarize_nginx_output() {
    local text
    text="$(printf '%s\n' "${NGINX_TEST_OUTPUT:-}" \
        | { grep -E '\[emerg\]|\[error\]|invalid value|unknown directive' || true; } \
        | tail -n 3)"
    if [[ -z "$text" ]]; then
        text="$(printf '%s\n' "${NGINX_TEST_OUTPUT:-}" | tail -n 2)"
    fi
    printf '%s' "$text" | tr '\n' ' ' | cut -c1-600
}

write_probe_config() {
    local path="$1"
    shift

    {
        printf 'include "%s";\n' "$LOAD_MODULE_CONF"
        printf 'pid "%s/guard-probe.pid";\n' "$RUNTIME_DIR"
        printf 'error_log stderr warn;\n'
        printf 'events { worker_connections 32; }\n'
        printf 'http {\n'
        printf '    access_log off;\n'
        printf '    server {\n'
        printf '        listen 127.0.0.1:18099;\n'
        printf '        location = /probe {\n'
        printf '            proxy_next_upstream off;\n'
        printf '            proxy_connect_timeout 3s;\n'
        printf '            proxy_send_timeout 3s;\n'
        printf '            proxy_read_timeout 3s;\n'
        printf '            proxy_pass http://127.0.0.1:18080/ok;\n'
        for line in "$@"; do
            printf '            %s\n' "$line"
        done
        printf '        }\n'
        printf '    }\n'
        printf '}\n'
    } > "$path"
}

# Run nginx -t probes for the two guards.  Results are reported later, in the
# normal q/r slots of the check battery, so that the PASS/FAIL output follows
# the documented order.
run_guard_probes() {
    local v2_base="$RUNTIME_DIR/guard-v2-baseline.conf"
    local v2_with="$RUNTIME_DIR/guard-v2-with.conf"
    local tr_base="$RUNTIME_DIR/guard-trailers-baseline.conf"
    local tr_with="$RUNTIME_DIR/guard-trailers-with.conf"

    log "probing guard semantics with nginx -t"

    # ---- proxy_http_version 2 ----------------------------------------
    write_probe_config "$v2_base" "proxy_http_version 2;"
    nginx_test_capture "$v2_base"

    if [[ $NGINX_TEST_RC -eq 0 ]]; then
        GUARD_V2_SUPPORTED=1
    else
        case "$NGINX_TEST_OUTPUT" in
            *'invalid value "2"'*|*'unknown directive "proxy_http_version"'*)
                GUARD_V2_STATUS="skip"
                GUARD_V2_DETAIL="nginx build has no proxy_http_version 2 support ($(summarize_nginx_output))"
                ;;
            *)
                GUARD_V2_STATUS="fail"
                GUARD_V2_DETAIL="baseline without socks_pass failed unexpectedly: $(summarize_nginx_output)"
                ;;
        esac
    fi

    if [[ $GUARD_V2_SUPPORTED -eq 1 ]]; then
        write_probe_config "$v2_with" \
            "proxy_http_version 2;" \
            "socks_pass socks5://127.0.0.1:11080;"
        nginx_test_capture "$v2_with"

        if [[ $NGINX_TEST_RC -ne 0 ]]; then
            GUARD_V2_REJECTS=1
            case "$NGINX_TEST_OUTPUT" in
                *'[emerg]'*)
                    GUARD_V2_STATUS="pass"
                    GUARD_V2_DETAIL="nginx -t rejected proxy_http_version 2 + socks_pass (baseline without socks_pass succeeded)"
                    ;;
                *)
                    GUARD_V2_STATUS="fail"
                    GUARD_V2_DETAIL="with socks_pass failed without an emerg diagnostic: $(summarize_nginx_output)"
                    ;;
            esac
        else
            GUARD_V2_STATUS="fail"
            GUARD_V2_DETAIL="module accepted proxy_http_version 2 with socks_pass; expected an [emerg] rejection (baseline without socks_pass succeeded)"
        fi
    fi

    # ---- proxy_pass_trailers ----------------------------------------
    write_probe_config "$tr_base" "proxy_pass_trailers on;"
    nginx_test_capture "$tr_base"

    if [[ $NGINX_TEST_RC -ne 0 ]]; then
        case "$NGINX_TEST_OUTPUT" in
            *'unknown directive "proxy_pass_trailers"'*)
                GUARD_TRAILERS_STATUS="skip"
                GUARD_TRAILERS_DETAIL="nginx build has no proxy_pass_trailers support ($(summarize_nginx_output))"
                ;;
            *)
                GUARD_TRAILERS_STATUS="fail"
                GUARD_TRAILERS_DETAIL="baseline without socks_pass failed unexpectedly: $(summarize_nginx_output)"
                ;;
        esac
    else
        write_probe_config "$tr_with" \
            "proxy_pass_trailers on;" \
            "socks_pass socks5://127.0.0.1:11080;"
        nginx_test_capture "$tr_with"

        if [[ $NGINX_TEST_RC -ne 0 ]]; then
            GUARD_TRAILERS_REJECTS=1
            case "$NGINX_TEST_OUTPUT" in
                *'[emerg]'*)
                    GUARD_TRAILERS_STATUS="pass"
                    GUARD_TRAILERS_DETAIL="nginx -t rejected proxy_pass_trailers + socks_pass (baseline without socks_pass succeeded)"
                    ;;
                *)
                    GUARD_TRAILERS_STATUS="fail"
                    GUARD_TRAILERS_DETAIL="with socks_pass failed without an emerg diagnostic: $(summarize_nginx_output)"
                    ;;
            esac
        else
            GUARD_TRAILERS_STATUS="fail"
            GUARD_TRAILERS_DETAIL="module accepted proxy_pass_trailers with socks_pass; expected an [emerg] rejection (baseline without socks_pass succeeded)"
        fi
    fi
}

report_guard_probes() {
    case "$GUARD_V2_STATUS" in
        pass) pass "guard-v2" ;;
        fail) fail "guard-v2" "$GUARD_V2_DETAIL" ;;
        skip) skip "guard-v2" "$GUARD_V2_DETAIL" ;;
    esac

    case "$GUARD_TRAILERS_STATUS" in
        pass) pass "guard-trailers" ;;
        fail) fail "guard-trailers" "$GUARD_TRAILERS_DETAIL" ;;
        skip) skip "guard-trailers" "$GUARD_TRAILERS_DETAIL" ;;
    esac
}

choose_guard_configuration() {
    RUNTIME_VERSION2=0
    VERSION2_SKIP_REASON=""

    if [[ -n "$WITH_GUARD_LOCATIONS" && "$WITH_GUARD_LOCATIONS" != "0" ]]; then
        write_guard_conf "both"
        if [[ $GUARD_V2_SUPPORTED -eq 1 && $GUARD_V2_REJECTS -eq 0 \
              && $GUARD_TRAILERS_REJECTS -eq 0 ]]; then
            RUNTIME_VERSION2=1
        else
            VERSION2_SKIP_REASON="guard locations are intentionally present in guard.conf"
        fi
        return 0
    fi

    if [[ $GUARD_V2_SUPPORTED -eq 0 ]]; then
        VERSION2_SKIP_REASON="this nginx build has no proxy_http_version 2 support"
        write_guard_conf "empty"
    elif [[ $GUARD_V2_REJECTS -eq 1 ]]; then
        VERSION2_SKIP_REASON="the module rejects proxy_http_version 2 with socks_pass"
        write_guard_conf "empty"
    else
        write_guard_conf "version2"
        RUNTIME_VERSION2=1
    fi
}

generate_cert() {
    if [[ -s "$CERT" && -s "$KEY" ]]; then
        return 0
    fi

    log "generating self-signed TLS certificate"
    rm -f -- "$CERT" "$KEY"

    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
            -keyout "$KEY" -out "$CERT" -subj "/CN=localhost" \
            -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
            >/dev/null 2>&1; then
        rm -f -- "$CERT" "$KEY"
        openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
            -keyout "$KEY" -out "$CERT" -subj "/CN=localhost" \
            >/dev/null 2>&1 \
            || die "openssl failed to generate a self-signed certificate"
    fi
    chmod 600 -- "$KEY" 2>/dev/null || true
}

wait_ready() {
    local file="$1"
    local pid="$2"
    local name="$3"
    local i

    for ((i = 0; i < 150; i++)); do
        if grep -qx 'ready' "$file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '%s exited before becoming ready; log follows:\n' "$name" >&2
            sed -n '1,80p' "$file" >&2 || true
            return 1
        fi
        sleep 0.1
    done

    printf '%s did not print "ready" within 15 seconds; log follows:\n' "$name" >&2
    sed -n '1,80p' "$file" >&2 || true
    return 1
}

start_socks() {
    log "starting socks5_proxy.py on 127.0.0.1:$NOAUTH_PORT and :$AUTH_PORT"
    python3 "$SCRIPT_DIR/socks5_proxy.py" \
        --noauth-port "$NOAUTH_PORT" --auth-port "$AUTH_PORT" \
        > "$SOCKS_LOG" 2>&1 &
    SOCKS_PID=$!
    if ! wait_ready "$SOCKS_LOG" "$SOCKS_PID" "socks5_proxy.py"; then
        die "socks5_proxy.py failed to start (see $SOCKS_LOG)"
    fi
}

start_backend() {
    log "starting backend.py on 127.0.0.1:$HTTP_PORT (TLS :$TLS_PORT, plain :$PLAIN_PORT)"
    python3 "$SCRIPT_DIR/backend.py" \
        --http-port "$HTTP_PORT" --tls-port "$TLS_PORT" \
        --plain-port "$PLAIN_PORT" --cert "$CERT" --key "$KEY" \
        > "$BACKEND_LOG" 2>&1 &
    BACKEND_PID=$!
    if ! wait_ready "$BACKEND_LOG" "$BACKEND_PID" "backend.py"; then
        die "backend.py failed to start (see $BACKEND_LOG)"
    fi
}

nginx_alive() {
    [[ -n "${NGINX_PID:-}" ]] && kill -0 "$NGINX_PID" 2>/dev/null
}

port_open() {
    python3 - "$1" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(0.25)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
}

wait_for_port() {
    local port="$1"
    local attempts="${2:-100}"
    local i

    for ((i = 0; i < attempts; i++)); do
        if port_open "$port"; then
            return 0
        fi
        if ! nginx_alive; then
            return 1
        fi
        sleep 0.1
    done
    return 1
}

start_nginx() {
    log "starting nginx on 127.0.0.1:$NGINX_PORT"
    : > "$NGINX_ERROR_LOG"

    # Dynamic modules always trip ASan's ODR check (ngx_module_names is
    # defined in both the binary and the .so), so it is disabled exactly as
    # in the project's Makefile (test-asan target).  UBSan reports are kept
    # but do not abort, again matching the Makefile.
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1:detect_odr_violation=0}" \
    UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=0}" \
        "$NGINX_BIN" -p "$RUNTIME_DIR" -c "$RUNTIME_CONF" \
        -g 'daemon off;' >> "$NGINX_ERROR_LOG" 2>&1 &
    NGINX_PID=$!
    NGINX_STARTED=1

    if ! wait_for_port "$NGINX_PORT" 120; then
        printf 'nginx did not listen on 127.0.0.1:%s; log follows:\n' "$NGINX_PORT" >&2
        tail -n 80 "$NGINX_ERROR_LOG" >&2 || true
        die "nginx failed to start"
    fi
}

# ---------------------------------------------------------------------------
# HTTP probe helpers for the check battery.
# ---------------------------------------------------------------------------

BODY_FILE=""
HEADER_FILE=""
CURL_ERR=""
HTTP_CODE=""
CURL_RC=0

fetch() {
    local url="$1"
    : > "$BODY_FILE"
    : > "$HEADER_FILE"
    : > "$CURL_ERR"
    CURL_RC=0
    HTTP_CODE="$(curl --http1.1 --silent --show-error \
        --max-time 6 --connect-timeout 2 \
        --dump-header "$HEADER_FILE" \
        --output "$BODY_FILE" \
        --write-out '%{http_code}' \
        "$url" 2> "$CURL_ERR")" || CURL_RC=$?
    HTTP_CODE="${HTTP_CODE//$'\n'/}"
    [[ -n "$HTTP_CODE" ]] || HTTP_CODE="000"
}

header_value() {
    local wanted="$1"
    awk -v wanted="$wanted" '
        BEGIN { wanted = tolower(wanted) }
        {
            line = $0
            sub(/\r$/, "", line)
            pos = index(line, ":")
            if (pos > 0) {
                name = tolower(substr(line, 1, pos - 1))
                if (name == wanted) {
                    value = substr(line, pos + 1)
                    sub(/^[ \t]+/, "", value)
                    print value
                    exit
                }
            }
        }
    ' "$HEADER_FILE"
}

fetch_detail() {
    local body err
    body="$(head -c 120 "$BODY_FILE" 2>/dev/null | tr '\r\n' '  ' || true)"
    err="$(head -c 200 "$CURL_ERR" 2>/dev/null | tr '\r\n' '  ' || true)"
    printf 'curl_rc=%s status=%s body=%q curl_err=%q' \
        "$CURL_RC" "$HTTP_CODE" "$body" "$err"
}

body_is() {
    [[ -f "$BODY_FILE" && "$(cat "$BODY_FILE")" == "$1" ]]
}

body_size() {
    wc -c < "$BODY_FILE" | tr -d ' '
}

nginx_log_contains() {
    [[ -f "$NGINX_ERROR_LOG" ]] && grep -q -- "$1" "$NGINX_ERROR_LOG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Checks (a-s in the harness specification; guard results are reported in
# their q/r slots even though the probes run before nginx starts).
# ---------------------------------------------------------------------------

check_basic() {
    fetch "http://127.0.0.1:$NGINX_PORT/ok"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" && "$(cat "$BODY_FILE")" == "hello" ]]; then
        pass "basic"
    else
        fail "basic" "expected 200/hello; $(fetch_detail)"
    fi
}

check_auth() {
    fetch "http://127.0.0.1:$NGINX_PORT/auth"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" && "$(cat "$BODY_FILE")" == "hello" ]]; then
        pass "auth"
    else
        fail "auth" "expected 200/hello; $(fetch_detail)"
    fi
}

check_auth_bad() {
    fetch "http://127.0.0.1:$NGINX_PORT/auth-bad"
    if [[ "$HTTP_CODE" == "502" ]]; then
        pass "auth-bad"
    else
        fail "auth-bad" "expected 502; $(fetch_detail)"
    fi
}

check_ssl() {
    fetch "http://127.0.0.1:$NGINX_PORT/ssl"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" && "$(cat "$BODY_FILE")" == "hello" ]]; then
        pass "ssl"
    else
        fail "ssl" "expected 200/hello through SOCKS + TLS; $(fetch_detail)"
    fi
}

check_premature() {
    fetch "http://127.0.0.1:$NGINX_PORT/premature"
    if [[ "$HTTP_CODE" == "502" ]]; then
        pass "premature"
    else
        fail "premature" "expected 502 for plaintext response from SSL backend; $(fetch_detail)"
    fi
}

check_charset_bad() {
    fetch "http://127.0.0.1:$NGINX_PORT/charset-bad"
    if [[ $CURL_RC -ne 0 || "$HTTP_CODE" != "200" ]]; then
        fail "charset-bad" "expected 200; $(fetch_detail)"
        return 0
    fi
    if ! nginx_alive; then
        fail "charset-bad" "nginx died after malformed charset response"
        return 0
    fi
    if nginx_log_contains "exited on signal"; then
        fail "charset-bad" "nginx worker crashed after malformed charset response"
        return 0
    fi
    pass "charset-bad"
}

check_charset_good() {
    fetch "http://127.0.0.1:$NGINX_PORT/charset-good"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" ]] \
        && grep -qi 'charset="utf-8"' "$HEADER_FILE"; then
        pass "charset-good"
    else
        fail "charset-good" "expected 200 with charset=\"utf-8\"; $(fetch_detail)"
    fi
}

check_big() {
    fetch "http://127.0.0.1:$NGINX_PORT/big"
    local size
    size="$(body_size)"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" && "$size" == "200000" ]]; then
        pass "big"
    else
        fail "big" "expected 200 with exactly 200000 bytes, got $size; $(fetch_detail)"
    fi
}

check_chunked() {
    fetch "http://127.0.0.1:$NGINX_PORT/chunked"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" \
          && "$(cat "$BODY_FILE")" == "aaabbbccc" ]]; then
        pass "chunked"
    else
        fail "chunked" "expected 200/aaabbbccc; $(fetch_detail)"
    fi
}

check_split_bad() {
    # Raw socket: the response is an HTTP/0.9-style body, so curl (without
    # --http0.9) is not usable here.  With the nginx 39d7d0ba fix the whole
    # first read, including the status line prefix parsed before the split,
    # must be present in the body.  Without the fix the body starts at the
    # second chunk ("XYZ...").
    local out
    out="$(python3 - "$NGINX_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=6)
s.sendall(b"GET /split-bad HTTP/1.1\r\n"
          b"Host: 127.0.0.1\r\n"
          b"Connection: close\r\n\r\n")
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
s.close()
sys.stdout.write(data.decode("latin-1"))
PY
)"

    if ! nginx_alive; then
        fail "split-bad" "nginx died after split invalid status line"
        return 0
    fi

    case "$out" in
        *"HTTP/1.1 XYZ"*)
            pass "split-bad"
            ;;
        *)
            fail "split-bad" "HTTP/0.9 body lost the parsed prefix; got: $(printf '%s' "$out" | head -c 140 | tr '\r\n' '  ')"
            ;;
    esac
}

check_loclen() {
    # Regression for nginx bcb41c91: try_files replaces r->uri with "/abc",
    # which is shorter than the "/ttll/" location prefix; the upstream must
    # still receive "/echo".
    fetch "http://127.0.0.1:$NGINX_PORT/ttll/"
    if ! nginx_alive; then
        fail "loc-len" "nginx died after a request whose URI became shorter than the location prefix"
        return 0
    fi
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" \
          && "$(cat "$BODY_FILE")" == "/echo" ]]; then
        pass "loc-len"
    else
        fail "loc-len" "expected 200 with upstream path '/echo'; $(fetch_detail)"
    fi
}

check_split_good() {
    fetch "http://127.0.0.1:$NGINX_PORT/split-good"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" \
          && "$(cat "$BODY_FILE")" == "OK!!" ]]; then
        pass "split-good"
    else
        fail "split-good" "expected 200/OK!!; $(fetch_detail)"
    fi
}

check_sequential() {
    local i
    for ((i = 1; i <= 10; i++)); do
        fetch "http://127.0.0.1:$NGINX_PORT/ok"
        if [[ $CURL_RC -ne 0 || "$HTTP_CODE" != "200" \
              || "$(cat "$BODY_FILE")" != "hello" ]]; then
            fail "sequential" "request $i of 10 failed: $(fetch_detail)"
            return 0
        fi
    done
    pass "sequential"
}

check_concurrent() {
    local dir="$CHECK_TMP/concurrent"
    local i code ok=0 bad=0 detail=""
    local pids=()
    rm -rf -- "$dir"
    mkdir -p -- "$dir"

    for ((i = 1; i <= 20; i++)); do
        (
            rc=0
            code="$(curl --http1.1 --silent --show-error \
                --max-time 6 --connect-timeout 2 \
                --output /dev/null --write-out '%{http_code}' \
                "http://127.0.0.1:$NGINX_PORT/ok" 2> "$dir/err.$i")" || rc=$?
            if [[ $rc -ne 0 ]]; then
                code="ERR"
            fi
            printf '%s\n' "$code" > "$dir/code.$i"
        ) &
        pids+=("$!")
    done
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for ((i = 1; i <= 20; i++)); do
        code="$(cat "$dir/code.$i" 2>/dev/null || true)"
        if [[ "$code" == "200" ]]; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
            if [[ -z "$detail" ]]; then
                detail="request $i returned ${code:-<missing>}"
            fi
        fi
    done

    if [[ $ok -eq 20 && $bad -eq 0 ]]; then
        pass "concurrent"
    else
        fail "concurrent" "expected 20/20 HTTP 200, got $ok ok and $bad bad ($detail)"
    fi
}

check_cache() {
    fetch "http://127.0.0.1:$NGINX_PORT/cache"
    local first_code="$HTTP_CODE"
    local first_body
    first_body="$(cat "$BODY_FILE")"

    fetch "http://127.0.0.1:$NGINX_PORT/cache"
    local second_code="$HTTP_CODE"
    local second_body
    second_body="$(cat "$BODY_FILE")"
    local cache_status
    cache_status="$(header_value X-Cache-Status)"

    if [[ "$first_code" != "200" || "$first_body" != "cached" \
          || "$second_code" != "200" || "$second_body" != "cached" ]]; then
        fail "cache" "expected two 200/cached responses, got $first_code/$first_body then $second_code/$second_body; $(fetch_detail)"
        return 0
    fi

    if [[ -n "$cache_status" && "$cache_status" != "HIT" ]]; then
        fail "cache" "second response X-Cache-Status was '$cache_status', expected HIT"
        return 0
    fi
    pass "cache"
}

check_xaccel_cache() {
    fetch "http://127.0.0.1:$NGINX_PORT/xaccel"
    if [[ "$HTTP_CODE" != "200" || "$(cat "$BODY_FILE")" != "cached" ]]; then
        fail "xaccel-cache" "first 18081 request: expected 200/cached; $(fetch_detail)"
        return 0
    fi

    fetch "http://127.0.0.1:$NGINX_PORT/xaccel"
    local second_code="$HTTP_CODE"
    local second_body
    second_body="$(cat "$BODY_FILE")"
    local cache_status
    cache_status="$(header_value X-Cache-Status)"

    if [[ "$second_code" != "200" || "$second_body" != "cached" ]]; then
        fail "xaccel-cache" "second 18081 request: expected 200/cached, got $second_code/$second_body; $(fetch_detail)"
        return 0
    fi
    if [[ -n "$cache_status" && "$cache_status" != "HIT" ]]; then
        fail "xaccel-cache" "second 18081 request X-Cache-Status was '$cache_status', expected HIT"
        return 0
    fi

    fetch "http://127.0.0.1:$XACCEL_PORT/xaccel"
    local redirect_code="$HTTP_CODE"
    local redirect_body
    redirect_body="$(cat "$BODY_FILE")"

    if [[ "$redirect_code" != "200" || "$redirect_body" != "redirected" ]]; then
        fail "xaccel-cache" "18082 request: expected internal redirect to /internal-target (200/redirected), got $redirect_code/$redirect_body; $(fetch_detail)"
        return 0
    fi

    if ! nginx_alive; then
        fail "xaccel-cache" "nginx died during cached X-Accel-Redirect handling"
        return 0
    fi

    if grep -Eq 'request count is zero|exited on signal|segmentation fault' \
            "$NGINX_ERROR_LOG" 2>/dev/null; then
        fail "xaccel-cache" "nginx log contains a crash/request-count diagnostic after cached X-Accel-Redirect"
        return 0
    fi

    pass "xaccel-cache"
}

check_store() {
    fetch "http://127.0.0.1:$NGINX_PORT/proxy-store"
    local store_file="$RUNTIME_DIR/store/proxy-store"
    if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" \
          && "$(cat "$BODY_FILE")" == "stored" && -s "$store_file" ]]; then
        pass "store"
    else
        local detail
        detail="$(fetch_detail)"
        if [[ ! -s "$store_file" ]]; then
            detail="$detail; expected non-empty file $store_file"
        fi
        fail "store" "expected 200/stored and stored file; $detail"
    fi
}

check_version2_runtime() {
    if [[ $RUNTIME_VERSION2 -ne 1 ]]; then
        printf 'SKIP: version2-runtime: %s (informational)\n' "${VERSION2_SKIP_REASON:-not enabled}"
        return 0
    fi
    if ! wait_for_port "$GUARD_PORT" 50; then
        printf 'INFO: version2-runtime: nginx is not listening on %s (informational)\n' "$GUARD_PORT"
        return 0
    fi

    fetch "http://127.0.0.1:$GUARD_PORT/version2"
    printf 'INFO: version2-runtime: status=%s curl_rc=%s (informational, not counted)\n' \
        "$HTTP_CODE" "$CURL_RC"
    if ! nginx_alive; then
        printf 'INFO: version2-runtime: nginx is no longer alive after the request\n'
    fi
    return 0
}

check_sanitizer_log() {
    # Note: grep without -q reads the whole stream; "grep -q" would close the
    # pipe early and, with pipefail, nm's SIGPIPE would look like a failure.
    if ! nm -a "$NGINX_BIN" 2>/dev/null | grep '__asan_init' > /dev/null; then
        skip "asan-log" "nginx binary is not ASan-instrumented"
        return 0
    fi

    if grep -q 'AddressSanitizer' "$NGINX_ERROR_LOG" 2>/dev/null; then
        fail "asan-log" "AddressSanitizer report found in $NGINX_ERROR_LOG"
        grep -E -m 5 'AddressSanitizer|SUMMARY' "$NGINX_ERROR_LOG" >&2 || true
        return 0
    fi

    if grep -q 'runtime error:' "$NGINX_ERROR_LOG" 2>/dev/null; then
        if grep -A 25 'runtime error:' "$NGINX_ERROR_LOG" \
                | grep -q 'ngx_http_socks'; then
            fail "ubsan-log" "UBSan report inside the module; see $NGINX_ERROR_LOG"
        else
            skip "ubsan-log" "UBSan reported outside the module (core nginx)"
        fi
    else
        pass "asan-log"
    fi
}

run_checks() {
    BODY_FILE="$CHECK_TMP/body"
    HEADER_FILE="$CHECK_TMP/headers"
    CURL_ERR="$CHECK_TMP/curl.err"

    log "running checks"

    check_basic
    check_auth
    check_auth_bad
    check_ssl
    check_premature
    check_charset_bad
    check_charset_good
    check_big
    check_chunked
    check_split_bad
    check_split_good
    check_loclen
    check_sequential
    check_concurrent
    check_cache
    check_xaccel_cache
    check_store
    report_guard_probes
    check_version2_runtime
}

print_summary() {
    local total=$((PASS + FAIL))
    printf '\n================ summary ================\n'
    printf 'total=%d pass=%d fail=%d skip=%d\n' "$total" "$PASS" "$FAIL" "$SKIP"
    if [[ $FAIL -gt 0 ]]; then
        printf 'failed checks: %s\n' "${FAILED_CHECKS[*]}"
    fi
}

main() {
    prepare_runtime
    write_load_module_conf

    if [[ $RENDER_ONLY -eq 1 ]]; then
        if [[ -n "$WITH_GUARD_LOCATIONS" && "$WITH_GUARD_LOCATIONS" != "0" ]]; then
            write_guard_conf "both"
        else
            write_guard_conf "empty"
        fi
        render_config

        printf 'Rendered nginx config: %s\n' "$RUNTIME_CONF"
        printf 'Wrote module loader:   %s\n' "$LOAD_MODULE_CONF"
        printf 'Guard include:        %s\n' "$GUARD_CONF"

        if [[ -x "$NGINX_BIN" ]]; then
            [[ -f "$MODULE_SO" ]] || printf 'WARNING: module not found: %s\n' "$MODULE_SO" >&2
            nginx_test_capture "$RUNTIME_CONF"
            printf '%s\n' "$NGINX_TEST_OUTPUT"
            exit "$NGINX_TEST_RC"
        fi

        printf 'SKIP: nginx -t (executable not found yet: %s)\n' "$NGINX_BIN"
        exit 0
    fi

    need_tools
    [[ -x "$NGINX_BIN" ]] || die "nginx executable not found: $NGINX_BIN (is the build finished?)"
    [[ -f "$MODULE_SO" ]] || die "dynamic module not found: $MODULE_SO"
    [[ -d "$NGINX_SRC" ]] || printf 'WARNING: NGINX_SRC not found: %s\n' "$NGINX_SRC" >&2

    run_guard_probes
    choose_guard_configuration
    render_config

    log "testing main nginx config"
    nginx_test_capture "$RUNTIME_CONF"
    if [[ $NGINX_TEST_RC -ne 0 ]]; then
        printf '%s\n' "$NGINX_TEST_OUTPUT" >&2
        if [[ -n "$WITH_GUARD_LOCATIONS" && "$WITH_GUARD_LOCATIONS" != "0" ]]; then
            printf 'NOTE: WITH_GUARD_LOCATIONS=1 intentionally puts guard-breaking directives in %s.\n' "$GUARD_CONF" >&2
        fi
        exit 1
    fi
    log "nginx -t: OK"

    generate_cert
    start_socks
    start_backend
    start_nginx

    run_checks
    check_sanitizer_log
    print_summary

    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
