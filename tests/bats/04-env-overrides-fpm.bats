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
@test "render-overrides skips empty/quoted/whitespace FPM_* and still validates" {
    run compose_exec env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        FPM_PM=static \
        FPM_PM_MAX_CHILDREN=4 \
        FPM_SLOWLOG="''" \
        FPM_REQUEST_SLOWLOG_TIMEOUT='   ' \
        FPM_PM_MAX_REQUESTS='""' \
        sh -c '/usr/local/bin/render-overrides.sh \
            && cat /usr/local/etc/php-fpm.d/zz-env.conf \
            && echo --- \
            && php-fpm -t 2>&1'
    assert_status_zero "$status"
    # the quoted-empty / whitespace-only directives must NOT appear
    assert_not_match "$output" "slowlog ="
    assert_not_match "$output" "request_slowlog_timeout ="
    assert_not_match "$output" "pm.max_requests ="
    # the real directives must appear
    assert_match "$output" "pm = static"
    assert_match "$output" "pm.max_children = 4"
    # and php-fpm must accept the resulting config
    assert_match "$output" "test is successful"
}
