#!/usr/bin/env bats
# 04-env-overrides-fpm.bats — FPM_* env vars must produce a zz-env.conf with
# the right [www] directives applied.

load '../helpers/lib.bash'
load '../helpers/compose.bash'

@test "zz-env.conf exists in php-fpm.d" {
    run compose_exec test -f /usr/local/etc/php-fpm.d/zz-env.conf
    assert_status_zero "$status"
}

@test "FPM_PM -> 'pm = static' in zz-env.conf" {
    run compose_exec grep -E '^pm = static$' /usr/local/etc/php-fpm.d/zz-env.conf
    assert_status_zero "$status"
}

@test "FPM_PM_MAX_CHILDREN -> pm.max_children" {
    run compose_exec grep -E '^pm\.max_children = 9$' /usr/local/etc/php-fpm.d/zz-env.conf
    assert_status_zero "$status"
}

@test "FPM_REQUEST_TERMINATE_TIMEOUT -> request_terminate_timeout" {
    run compose_exec grep -E '^request_terminate_timeout = 300$' /usr/local/etc/php-fpm.d/zz-env.conf
    assert_status_zero "$status"
}

@test "php-fpm config still validates with zz-env.conf merged" {
    run compose_exec php-fpm -t
    assert_status_zero "$status"
}

# Regression for the FPM_SLOWLOG='' / FPM_REQUEST_SLOWLOG_TIMEOUT='' class of
# bugs where a user empties an FPM_* var with quotes in compose. The pre-fix
# emitter wrote `slowlog = ''` to zz-env.conf and php-fpm crashed at startup
# with "value is NULL for a ZEND_INI_PARSER_ENTRY", killing the container.
# clean_val() in render-overrides.sh should strip surrounding quotes + trim
# whitespace and silently skip the directive when nothing is left.
#
# Also covers the unbalanced lone-quote case (FPM_REQUEST_TERMINATE_TIMEOUT='"'):
# clean_val only strips a *matched* pair, so a single stray quote survives the
# trim and the pre-fix emitter wrote `request_terminate_timeout = "` — an
# unterminated quoted value php-fpm rejects with a syntax error, refusing to
# start. prepare_val()'s metacharacter reject must drop it like the ';' case.
#
# Runs in a mktemp sandbox so it doesn't clobber the live container's
# zz-env.conf / nginx.conf (which subsequent tests depend on).
@test "render-overrides skips empty/quoted/whitespace FPM_* and still validates" {
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
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    FPM_PM=static FPM_PM_MAX_CHILDREN=4 \
    FPM_SLOWLOG="''" \
    FPM_REQUEST_SLOWLOG_TIMEOUT="   " \
    FPM_PM_MAX_REQUESTS='""' \
    FPM_REQUEST_TERMINATE_TIMEOUT='"' \
    "$sb/render.sh" 2>&1
echo "--- zz-env.conf ---"
cat "$sb/fpm/zz-env.conf"
echo "--- php-fpm -t ---"
cat > "$sb/php-fpm.conf" <<INI
[global]
error_log = /proc/self/fd/2
daemonize = no
[www]
listen = 127.0.0.1:9999
user = www-data
group = www-data
INI
cat "$sb/fpm/zz-env.conf" >> "$sb/php-fpm.conf"
php-fpm -t -y "$sb/php-fpm.conf" 2>&1
rc=$?
rm -rf "$sb"
exit $rc
SH
)
    run compose_exec sh -c "$payload"
    assert_status_zero "$status"
    # the real directives must appear
    assert_match "$output" "^pm = static$"
    assert_match "$output" "^pm\.max_children = 4$"
    # the quoted-empty / whitespace-only directives must NOT appear
    assert_not_match "$output" "^slowlog ="
    assert_not_match "$output" "^request_slowlog_timeout ="
    assert_not_match "$output" "^pm\.max_requests ="
    # the unbalanced lone-quote value must NOT appear (would be unterminated)
    assert_not_match "$output" "^request_terminate_timeout ="
    # and php-fpm must accept the resulting config
    assert_match "$output" "test is successful"
}

# Regression for the config-injection reject branches in render-overrides.sh:
# prepare_val() rejects any FPM_*/PHP_* value carrying a ';' (starts an INI
# comment, truncating the directive) or a newline (would inject a second
# directive line); NGINX_HSTS gets its own reject for a '"', '$', '\' or
# newline ('"'/newline close the nginx string early; '$' is interpolated by
# nginx in add_header values, silently corrupting the header or failing
# nginx -t; '\' escapes the closing quote of the raw "..." literal, running it
# on through `always;` → nginx -t fails); NGINX_SERVER_NAME rejects a newline,
# ';' or '#' (';' injects a directive, '#' comments out the ';' terminator so
# nginx swallows the next directive). These are the exact guards the
# printf-not-echo emitter exists to keep effective — yet no test exercised
# them, so breaking the
# `*';'*|*"$nl"*` / `*'"'*|*'$'*|*'\'*|*"$nl"*` / `*"$nl"*|*';'*|*'#'*` cases stayed
# green. Same mktemp sandbox as the empty/quoted test above.
@test "render-overrides rejects ';'/newline FPM_* and '\"' NGINX_HSTS (injection guards)" {
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
nl='
'
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    FPM_PM=static \
    FPM_SLOWLOG="/tmp/s.log; evil = 1" \
    FPM_REQUEST_SLOWLOG_TIMEOUT="10${nl}pm.max_children = 999" \
    NGINX_HSTS='max-age=1; bad"quote' \
    "$sb/render.sh" 2>&1
echo "--- zz-env.conf ---"
cat "$sb/fpm/zz-env.conf" 2>/dev/null || echo "(no zz-env.conf)"
echo "--- nc-hsts.conf ---"
cat "$sb/snippets/nc-hsts.conf" 2>/dev/null || true
# Second render: an HSTS value carrying a '$' but NO '"'/newline. nginx
# interpolates `$var` in add_header values, so without the '$' reject this
# would be written verbatim and silently emit the interpolated value (or fail
# nginx -t on an undefined var). The old '"'/newline-only reject let it through.
echo "=== second render: '\$' HSTS ==="
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_HSTS='max-age=1; pwned$host' \
    "$sb/render.sh" 2>&1
echo "--- nc-hsts.conf (\$ test) ---"
cat "$sb/snippets/nc-hsts.conf" 2>/dev/null || true
# Third render: a NGINX_SERVER_NAME carrying a '#'. nginx treats '#' as a line
# comment, so `foo.com #` would be written as `server_name foo.com #;` — the
# appended ';' is commented out, the directive is left unterminated, and nginx
# folds the following `root` directive into the server_name arguments (valid
# config that passes nginx -t but silently drops `root`). The ';'/newline-only
# reject let it through; the server_name patch must fall back to '_'.
echo "=== third render: '#' NGINX_SERVER_NAME ==="
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_SERVER_NAME='foo.com #' \
    "$sb/render.sh" 2>&1
echo "--- nginx.conf server_name (# test) ---"
grep -E '^\s*server_name ' "$sb/nginx.conf" 2>/dev/null || true
# Fourth render: an HSTS value ending in '\' but with NO '"'/'$'/newline. The
# value is emitted raw into a "..." literal, so a trailing backslash escapes the
# closing quote (`"max-age=1; trapdoor\"`), running the string on through the
# `always;` terminator → nginx -t "unexpected end of file" → boot aborts. The
# old '"'/'$'/newline-only reject let it through; the '\' reject must drop it.
echo "=== fourth render: '\\' HSTS ==="
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_HSTS='max-age=1; trapdoor\' \
    "$sb/render.sh" 2>&1
echo "--- nc-hsts.conf (\\ test) ---"
cat "$sb/snippets/nc-hsts.conf" 2>/dev/null || true
rm -rf "$sb"
SH
)
    run compose_exec sh -c "$payload"
    assert_status_zero "$status"
    # the valid directive must appear (proves render ran to completion)
    assert_match "$output" "^pm = static$"
    # the ';' value is rejected, with the INI-metacharacter skip logged
    assert_not_match "$output" "^slowlog ="
    assert_match "$output" "INI metacharacter"
    # the newline value is rejected — the injected second line never lands
    assert_not_match "$output" "pm\.max_children = 999"
    # all three HSTS values are rejected (the '"' one, the '$'-interpolation one,
    # and the trailing-'\' run-on one), each with its own skip logged and no
    # header ever written to nc-hsts.conf
    assert_match "$output" "skipping NGINX_HSTS"
    assert_not_match "$output" "Strict-Transport-Security"
    assert_not_match "$output" "pwned"
    assert_not_match "$output" "trapdoor"
    # the '#' server_name is rejected, with the ignore logged, and the patched
    # nginx.conf falls back to `server_name _;` — the dangerous value never lands
    assert_match "$output" "ignoring NGINX_SERVER_NAME"
    assert_match "$output" "^\s*server_name _;"
    assert_not_match "$output" "server_name foo\.com"
}
