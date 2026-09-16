#!/usr/bin/env bats
# 05-env-overrides-nginx.bats — NGINX_SERVER_NAME patches nginx.conf in place;
# NGINX_HSTS appears as a conf.d drop-in and is emitted on responses;
# NGINX_ACCESS_LOG toggles the per-request access log (off by default).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "NGINX_SERVER_NAME patches server_name in nginx.conf" {
    run compose_exec grep -E '^\s*server_name test\.local;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "NGINX_HSTS drops into /etc/nginx/snippets/nc-hsts.conf" {
    run compose_exec cat /etc/nginx/snippets/nc-hsts.conf
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security'
    assert_match "$output" 'max-age=31536000'
}

@test "Strict-Transport-Security header on responses" {
    run nc_headers /
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security: max-age=31536000'
}

@test "Strict-Transport-Security header on static assets (not just dynamic pages)" {
    # Static assets are served by `location ~ \.(css|js|...)`, which declares its
    # own add_header (Cache-Control) and so must re-include HSTS — regression
    # guard for the per-block add_header reset.
    run nc_headers /core/css/server.css
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security: max-age=31536000'
    # Pin that the static-asset location (not a fallthrough to `location /` or a
    # 404) actually served this: Cache-Control: public is emitted ONLY by that
    # block. Without it, dropping .css from the static regex would still inherit
    # server-scope HSTS and this test would stay green.
    assert_match "$output" 'Cache-Control: public'
}

@test "NGINX_ACCESS_LOG=true renders 'access_log /dev/stdout main;' into the snippet" {
    run compose_exec cat /etc/nginx/snippets/nc-access-log.conf
    assert_status_zero "$status"
    assert_eq "$output" "access_log /dev/stdout main;"
}

@test "NGINX_ACCESS_LOG=true: a request shows up once in container logs (nginx line, no FPM duplicate)" {
    # Unique query string so the grep can't match the healthcheck's status.php hits.
    local tag="bats-accesslog-$$-$RANDOM"
    run nc_status_code "/status.php?$tag"
    assert_status_zero "$status"
    assert_eq "$output" "200"
    # Access-log delivery to the docker log driver is not synchronous.
    wait_until 15 1 bash -c \
        "docker compose -f '$COMPOSE_FILE' -p '$COMPOSE_PROJECT_NAME' logs --no-log-prefix nc 2>&1 | grep -q 'GET /status.php?$tag '"
    run compose logs --no-log-prefix nc
    assert_status_zero "$status"
    local n
    n=$(printf '%s\n' "$output" | grep -c "/status.php?$tag" || true)
    # nginx `main` format logs the full request line incl. query string. The
    # (opt-in, enabled in the fixture) FPM access log logs only "GET /status.php"
    # without the query, so the tagged request appears exactly once.
    assert_eq "$n" "1" "expected exactly one nginx access-log line for the tagged request"
}

@test "NGINX_ACCESS_LOG unset -> 'access_log off;' (default) and nginx -t still passes" {
    # Sandboxed render (same pattern as tests/bats/04) so the live container's
    # snippet — which later tests read — is left untouched.
    local payload
    payload=$(cat <<'SH'
set -eu
sb=$(mktemp -d)
mkdir -p "$sb/php" "$sb/fpm" "$sb/nginx-conf" "$sb/snippets" "$sb/sv"
cp /etc/nginx/nginx.conf "$sb/nginx.conf"
sed -e "s|/usr/local/etc/php/conf.d/|$sb/php/|g" \
    -e "s|/usr/local/etc/php-fpm.d/|$sb/fpm/|g" \
    -e "s|/etc/nginx/conf.d/|$sb/nginx-conf/|g" \
    -e "s|/etc/nginx/snippets/|$sb/snippets/|g" \
    -e "s|/etc/nginx/nginx.conf|$sb/nginx.conf|g" \
    -e "s|/etc/supervisor/conf.d/|$sb/sv/|g" \
    /usr/local/bin/render-overrides.sh > "$sb/render.sh"
chmod +x "$sb/render.sh"
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$sb/render.sh" 2>&1
echo "--- default ---"; cat "$sb/snippets/nc-access-log.conf"
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin NGINX_ACCESS_LOG=0 "$sb/render.sh" 2>&1
echo "--- explicit 0 ---"; cat "$sb/snippets/nc-access-log.conf"
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin NGINX_ACCESS_LOG=yes "$sb/render.sh" 2>&1
echo "--- yes ---"; cat "$sb/snippets/nc-access-log.conf"
# Lint the rendered default against the sandboxed nginx.conf: point its
# snippet includes at the sandbox and run nginx -t on it. nginx resolves a bare
# relative `include fastcgi_params;` against the config file's OWN directory
# (not -p), so make that one absolute in the sandbox copy.
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$sb/render.sh" 2>&1
sed -i -e "s|/etc/nginx/snippets/|$sb/snippets/|g" \
       -e "s|include fastcgi_params;|include /etc/nginx/fastcgi_params;|" "$sb/nginx.conf"
cp /etc/nginx/snippets/nc-security-headers.conf "$sb/snippets/"
nginx -t -c "$sb/nginx.conf" 2>&1
rc=$?
rm -rf "$sb"
exit $rc
SH
)
    run compose_exec sh -c "$payload"
    assert_status_zero "$status"
    # assert_contains (substring), not assert_match: a needle beginning with
    # `---` would be parsed by grep as an option.
    assert_contains "$output" "--- default ---
access_log off;"
    assert_contains "$output" "--- explicit 0 ---
access_log off;"
    assert_contains "$output" "--- yes ---
access_log /dev/stdout main;"
    assert_match "$output" "test is successful"
}

@test "nginx config validates after server_name patch + HSTS include" {
    run compose_exec nginx -t
    assert_status_zero "$status"
}
