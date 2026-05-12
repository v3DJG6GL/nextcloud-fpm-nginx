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
