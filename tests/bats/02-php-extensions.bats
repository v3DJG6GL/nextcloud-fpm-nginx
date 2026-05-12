#!/usr/bin/env bats
# 02-php-extensions.bats — every Nextcloud-required PHP extension must be loaded
# inside the running container (CST validates the image; this validates runtime).

load '../helpers/lib.bash'
load '../helpers/docker.bash'
load '../helpers/compose.bash'

@test "php -m lists all required Nextcloud extensions" {
    # Note: 'opcache' shows up as 'Zend OPcache' under [Zend Modules]; we test
    # its functionality separately via ini_get below. 'bz2' is NOT shipped by
    # the upstream NC fpm image (it's installed as a system tool, not the PHP
    # extension) — Nextcloud core doesn't require it.
    local required="ftp gd intl gmp bcmath imagick redis apcu exif pcntl sysvsem zip igbinary memcached pdo_mysql pdo_pgsql ldap"
    local loaded missing=""
    loaded=$(compose_exec php -m 2>/dev/null)
    for ext in $required; do
        if ! printf '%s\n' "$loaded" | grep -qiE "^${ext}$"; then
            missing="$missing $ext"
        fi
    done
    if [ -n "$missing" ]; then
        log "missing PHP extensions:$missing"
        log "loaded extensions:"
        log "$loaded"
        return 1
    fi
}

@test "Zend OPcache is loaded (separate Zend module listing)" {
    run compose_exec sh -c 'php -m | grep -F "Zend OPcache"'
    assert_status_zero "$status"
}

@test "igbinary serializer set for sessions (Redis fast path)" {
    run compose_exec php -r 'echo ini_get("session.serialize_handler");'
    assert_status_zero "$status"
    assert_eq "$output" "igbinary"
}

@test "opcache is enabled" {
    run compose_exec php -r 'echo ini_get("opcache.enable") ?: 0;'
    assert_status_zero "$status"
    assert_eq "$output" "1"
}

@test "opcache.save_comments=1 (required by Nextcloud)" {
    run compose_exec php -r 'echo ini_get("opcache.save_comments");'
    assert_status_zero "$status"
    assert_eq "$output" "1"
}

@test "apc.enable_cli=1 (Nextcloud cron uses APCu from CLI)" {
    run compose_exec php -r 'echo ini_get("apc.enable_cli") ?: 0;'
    assert_status_zero "$status"
    assert_eq "$output" "1"
}
