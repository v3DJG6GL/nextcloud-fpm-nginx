#!/usr/bin/env bats
# 03-env-overrides-php.bats — PHP_* env vars must reach the running PHP runtime.
# Compose fixtures set representative values (see tests/compose/*.yaml):
#   PHP_TIMEZONE                       = America/Anchorage
#   PHP_MEMORY_LIMIT                   = 1G
#   PHP_UPLOAD_LIMIT                   = 4G
#   PHP_OPCACHE_MEMORY_CONSUMPTION     = 256
#   PHP_OPCACHE_MAX_ACCELERATED_FILES  = 50000
#   PHP_OPCACHE_JIT_BUFFER_SIZE        = 384M
#   PHP_OPCACHE_INTERNED_STRINGS_BUFFER= 64

load '../helpers/lib.bash'
load '../helpers/compose.bash'

@test "PHP_TIMEZONE -> date.timezone" {
    run compose_exec php -r 'echo date_default_timezone_get();'
    assert_status_zero "$status"
    assert_eq "$output" "America/Anchorage"
}

@test "PHP_MEMORY_LIMIT (upstream env var) -> memory_limit" {
    run compose_exec php -r 'echo ini_get("memory_limit");'
    assert_status_zero "$status"
    assert_eq "$output" "1G"
}

@test "PHP_UPLOAD_LIMIT -> upload_max_filesize + post_max_size" {
    run compose_exec php -r 'echo ini_get("upload_max_filesize");'
    assert_status_zero "$status"
    assert_eq "$output" "4G"
    run compose_exec php -r 'echo ini_get("post_max_size");'
    assert_status_zero "$status"
    assert_eq "$output" "4G"
}

@test "PHP_OPCACHE_MEMORY_CONSUMPTION (upstream env) -> opcache.memory_consumption" {
    run compose_exec php -r 'echo ini_get("opcache.memory_consumption");'
    assert_status_zero "$status"
    assert_eq "$output" "256"
}

@test "PHP_OPCACHE_JIT_BUFFER_SIZE -> opcache.jit_buffer_size" {
    run compose_exec php -r 'echo ini_get("opcache.jit_buffer_size");'
    assert_status_zero "$status"
    assert_eq "$output" "384M"
}

@test "PHP_OPCACHE_MAX_ACCELERATED_FILES -> opcache.max_accelerated_files" {
    run compose_exec php -r 'echo ini_get("opcache.max_accelerated_files");'
    assert_status_zero "$status"
    assert_eq "$output" "50000"
}

@test "PHP_OPCACHE_INTERNED_STRINGS_BUFFER -> opcache.interned_strings_buffer" {
    run compose_exec php -r 'echo ini_get("opcache.interned_strings_buffer");'
    assert_status_zero "$status"
    assert_eq "$output" "64"
}

@test "zz-env-overrides.ini exists and is the last-loaded .ini" {
    run compose_exec test -f /usr/local/etc/php/conf.d/zz-env-overrides.ini
    assert_status_zero "$status"
    # ls in lexical order — zz-* must come after opcache-recommended.ini + nextcloud.ini
    run compose_exec sh -c 'ls /usr/local/etc/php/conf.d/ | tail -1'
    assert_status_zero "$status"
    assert_eq "$output" "zz-env-overrides.ini"
}
