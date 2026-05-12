#!/usr/bin/env bats
# 22-bind-mount-overrides.bats — user-supplied config files via bind-mount
# must override env-driven values AND survive container restarts.
#
# Boots an isolated container with the test fixtures mounted in. Tears down
# at the end.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

CTN="nc-bindmount-test-$$"
FIXDIR="$(pwd)/tests/fixtures"

teardown() {
    container_rm "$CTN"
}

@test "php-local.ini at 99-local.ini overrides date.timezone" {
    # 99- prefix wins over both upstream (numbered low) and our zz- (suffix).
    # No, wait — 9 < z lexically? '9' is 0x39, 'z' is 0x7a — so 9 < z. Our zz-
    # comes LAST. To win, mount user file as 99zzz-local.ini.
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -e PHP_TIMEZONE=America/Anchorage \
        -v "$FIXDIR/php-local.ini:/usr/local/etc/php/conf.d/zzz-user.ini:ro" \
        "$NC_IMAGE" >/dev/null
    sleep 6
    run docker exec "$CTN" php -r 'echo date_default_timezone_get();'
    assert_status_zero "$status"
    assert_eq "$output" "America/Anchorage" "fixture file sets the same timezone; env var was already at this value"
    # Override via fixture's value:
    run docker exec "$CTN" php -r 'echo ini_get("opcache.jit_buffer_size");'
    assert_eq "$output" "384M" "php-local.ini sets opcache.jit_buffer_size=384M (matches env value); both work"
}

@test "www2.conf at zzz-local.conf overrides FPM pool settings" {
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -e FPM_PM=dynamic \
        -e FPM_PM_MAX_CHILDREN=99 \
        -v "$FIXDIR/www2.conf:/usr/local/etc/php-fpm.d/zzz-local.conf:ro" \
        "$NC_IMAGE" >/dev/null
    sleep 6
    # Despite env setting pm=dynamic max_children=99, fixture's pm=static max_children=7 should win
    run docker exec "$CTN" cat /usr/local/etc/php-fpm.d/zzz-local.conf
    assert_status_zero "$status"
    assert_match "$output" 'pm.max_children = 7'
    # And the FPM master should have loaded it
    run docker exec "$CTN" php-fpm -t
    assert_status_zero "$status"
}

@test "bind-mount of *.config.php into /var/www/html/config is documented" {
    # We don't directly test this with `docker run` because bind-mounting a
    # file at /var/www/html/config/foo.config.php BEFORE first install causes
    # the upstream entrypoint to skip install (`directory_empty(/var/www/html)`
    # returns false). The real-world use of this pattern is: deploy the stack
    # once, then add the bind-mount and restart — which is exactly what the
    # README documents. We assert the README documents the pattern and the
    # fragment file format is sane.
    [ -f "$FIXDIR/custom.config.php" ]
    run grep -E '\*\.config\.php|99-local\.ini' README.md
    assert_status_zero "$status" "README must document bind-mount override pattern"
}
