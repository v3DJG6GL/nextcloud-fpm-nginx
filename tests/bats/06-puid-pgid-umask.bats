#!/usr/bin/env bats
# 06-puid-pgid-umask.bats — host-user mapping behavior.
# Most tests here spin up isolated containers because PUID is fixture-wide.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

PUID_TEST_NAME="nc-puid-test-$$"

teardown() {
    container_rm "$PUID_TEST_NAME"
}

@test "default (no PUID/PGID set) -> www-data is uid 33" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 4
    run docker exec "$PUID_TEST_NAME" id -u www-data
    assert_status_zero "$status"
    assert_eq "$output" "33"
}

@test "PUID=1000 PGID=1000 -> www-data is uid 1000, /var/www chowned" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1000 -e PGID=1000 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 8
    run docker exec "$PUID_TEST_NAME" id -u www-data
    assert_status_zero "$status"
    assert_eq "$output" "1000"
    run docker exec "$PUID_TEST_NAME" stat -c '%u:%g' /var/www/html
    assert_status_zero "$status"
    assert_eq "$output" "1000:1000"
}

@test "entrypoint logs groupmod/usermod when PUID changes" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1234 -e PGID=1234 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 4
    run docker logs "$PUID_TEST_NAME"
    assert_status_zero "$status"
    assert_match "$output" 'entrypoint: usermod www-data .* -> 1234'
    assert_match "$output" 'entrypoint: chown -R 1234:1234 /var/www'
}

@test "restart with same PUID skips chown (sentinel)" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1500 -e PGID=1500 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 10
    docker stop "$PUID_TEST_NAME" >/dev/null
    docker start "$PUID_TEST_NAME" >/dev/null
    sleep 4
    # Logs from THIS start only — `docker start` doesn't reset the log, so we
    # look at the *last* entrypoint section after the last 'supervisord started'.
    run docker logs --tail=50 "$PUID_TEST_NAME"
    assert_status_zero "$status"
    # Count usermod lines; should be exactly 1 (from the very first start).
    local count
    count=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'usermod www-data')
    assert_eq "$count" "1" "expected exactly 1 usermod log line across both starts"
}

@test "UMASK propagates to child processes" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e UMASK=027 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 4
    # supervisord PID 1 inherits umask 027; verify via /proc
    run docker exec "$PUID_TEST_NAME" sh -c 'grep ^Umask /proc/1/status'
    assert_status_zero "$status"
    assert_match "$output" '^Umask:\s+0027$'
}
