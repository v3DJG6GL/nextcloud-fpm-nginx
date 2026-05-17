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

# Regression for the case the previous test DOESN'T cover: container
# RECREATION (docker rm + docker run, or `docker compose up -d` after an
# image pull). /etc/passwd lives in the container layer, so a fresh
# container always starts with www-data=33 — `id -u www-data` returns 33,
# usermod has to run again. Without sentinel logic, the recursive
# `chown -R /var/www` ALSO runs every time, which on a multi-TB HDD data
# volume takes hours per image pull. With the sentinel, we probe one file
# (`version.php`) and only chown when it's actually wrong.
@test "recreate with same PUID skips chown (sentinel survives /etc/passwd reset)" {
    local vol="puid-recreate-vol-$$"

    # First boot — fresh install, chown SHOULD run:
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1500 -e PGID=1500 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${vol}:/var/www/html" \
        "$NC_IMAGE" >/dev/null
    sleep 10

    local first_chown
    first_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'chown -R 1500:1500 /var/www')
    [ "$first_chown" -ge 1 ] \
        || { log "expected chown on first boot, got $first_chown lines"; return 1; }

    # Tear down + REMOVE container (named volume survives, mimicking what
    # `docker compose up -d` after an image bump does):
    docker stop "$PUID_TEST_NAME" >/dev/null
    docker rm   "$PUID_TEST_NAME" >/dev/null

    # Recreate with the same name + same volume + same PUID. /etc/passwd
    # in the new container starts at upstream default (www-data=33), so
    # usermod MUST run again. But the sentinel (/var/www/html/version.php)
    # is already 1500:1500 from the previous boot, so chown MUST be skipped.
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1500 -e PGID=1500 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${vol}:/var/www/html" \
        "$NC_IMAGE" >/dev/null
    sleep 6

    local recreated_usermod
    recreated_usermod=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'usermod www-data 33 -> 1500')
    assert_eq "$recreated_usermod" "1" \
        "usermod should run on recreate (/etc/passwd reset to image default)"

    local recreated_chown
    recreated_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'chown -R 1500:1500 /var/www')
    assert_eq "$recreated_chown" "0" \
        "chown should be SKIPPED on recreate (sentinel /var/www/html/version.php already 1500:1500)"

    # Cleanup the named volume so the next bats run starts clean:
    docker volume rm "$vol" >/dev/null 2>&1 || true
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
