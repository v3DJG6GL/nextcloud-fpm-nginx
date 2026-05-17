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
# Runs in a mktemp sandbox so it doesn't clobber the live container's
# zz-env.conf / nginx.conf (which subsequent tests depend on).
@test "render-overrides skips empty/quoted/whitespace FPM_* and still validates" {
    local payload
    payload=$(cat <<'SH'
set -eu
sb=$(mktemp -d)
mkdir -p "$sb/php" "$sb/fpm" "$sb/nginx-conf" "$sb/sv"
cp /etc/nginx/nginx.conf "$sb/nginx.conf"
sed -e "s|/usr/local/etc/php/conf.d/|$sb/php/|g" \
    -e "s|/usr/local/etc/php-fpm.d/|$sb/fpm/|g" \
    -e "s|/etc/nginx/conf.d/|$sb/nginx-conf/|g" \
    -e "s|/etc/nginx/nginx.conf|$sb/nginx.conf|g" \
    -e "s|/etc/supervisor/conf.d/|$sb/sv/|g" \
    /usr/local/bin/render-overrides.sh > "$sb/render.sh"
chmod +x "$sb/render.sh"
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    FPM_PM=static FPM_PM_MAX_CHILDREN=4 \
    FPM_SLOWLOG="''" \
    FPM_REQUEST_SLOWLOG_TIMEOUT="   " \
    FPM_PM_MAX_REQUESTS='""' \
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
    # and php-fpm must accept the resulting config
    assert_match "$output" "test is successful"
}
