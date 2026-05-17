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

    # `grep -c` exits 1 when count is 0; swallow that so $() doesn't trip
    # bats' set -e (we want to assert ON the count, not on grep's exit code).
    local first_chown
    first_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'chown -R 1500:1500 /var/www' || true)
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
    recreated_usermod=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'usermod www-data 33 -> 1500' || true)
    assert_eq "$recreated_usermod" "1" \
        "usermod should run on recreate (/etc/passwd reset to image default)"

    # `|| true` — grep -c exits 1 when count is 0, which IS the expected
    # success case here. We want to assert on the integer, not have the
    # zero-match exit code fail the test before we get there.
    local recreated_chown
    recreated_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -c 'chown -R 1500:1500 /var/www' || true)
    assert_eq "$recreated_chown" "0" \
        "chown should be SKIPPED on recreate (sentinel /var/www/html/version.php already 1500:1500)"

    # Cleanup the named volume so the next bats run starts clean:
    docker volume rm "$vol" >/dev/null 2>&1 || true
}

# External datadirectory (NEXTCLOUD_DATA_DIR pointed outside /var/www/) —
# the /var/www chown doesn't reach it, so the entrypoint must do a
# separate chown gated on .ncdata/.ocdata sentinel.
@test "external NEXTCLOUD_DATA_DIR gets chowned via its own sentinel" {
    local datavol="puid-extdata-vol-$$"

    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1700 -e PGID=1700 \
        -e NEXTCLOUD_DATA_DIR=/srv/nc-data \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${datavol}:/srv/nc-data" \
        "$NC_IMAGE" >/dev/null

    # First boot: data dir starts empty → fresh-install branch → chown runs.
    # Wait up to 60s for upstream install to finish (creates .ncdata):
    local i
    for i in $(seq 1 60); do
        docker exec "$PUID_TEST_NAME" test -f /srv/nc-data/.ncdata 2>/dev/null && break
        sleep 1
    done
    run docker exec "$PUID_TEST_NAME" stat -c '%u:%g' /srv/nc-data/.ncdata
    assert_status_zero "$status"
    assert_eq "$output" "1700:1700"

    local first_data_chown
    first_data_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -c 'chown -R 1700:1700 /srv/nc-data' || true)
    [ "$first_data_chown" -ge 1 ] \
        || { log "expected data-dir chown on first boot, got $first_data_chown"; return 1; }

    # Recreate container, same volume → sentinel matches → chown SKIPPED:
    docker stop "$PUID_TEST_NAME" >/dev/null
    docker rm   "$PUID_TEST_NAME" >/dev/null
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1700 -e PGID=1700 \
        -e NEXTCLOUD_DATA_DIR=/srv/nc-data \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${datavol}:/srv/nc-data" \
        "$NC_IMAGE" >/dev/null
    sleep 6

    local recreated_data_chown
    recreated_data_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -c 'chown -R 1700:1700 /srv/nc-data' || true)
    assert_eq "$recreated_data_chown" "0" \
        "external data-dir chown should be SKIPPED on recreate (sentinel already 1700:1700)"

    docker volume rm "$datavol" >/dev/null 2>&1 || true
}

# Dual-sentinel regression: when datadir is the default
# /var/www/html/data BUT mounted on a separate bind mount than the
# webroot, the two trees can drift apart in ownership. We must detect
# this via .ncdata even though the path looks nested under /var/www.
@test "drift between separate webroot + data bind mounts triggers data-only chown" {
    local wwwvol="puid-drift-www-$$"
    local datavol="puid-drift-data-$$"

    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1800 -e PGID=1800 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${wwwvol}:/var/www/html" \
        -v "${datavol}:/var/www/html/data" \
        "$NC_IMAGE" >/dev/null

    # Wait for install to create both sentinels:
    local i
    for i in $(seq 1 60); do
        docker exec "$PUID_TEST_NAME" test -f /var/www/html/data/.ncdata 2>/dev/null && break
        sleep 1
    done
    run docker exec "$PUID_TEST_NAME" stat -c '%u:%g' /var/www/html/data/.ncdata
    assert_status_zero "$status"
    assert_eq "$output" "1800:1800"

    # Simulate drift: force the data dir back to root ownership.
    docker exec "$PUID_TEST_NAME" chown -R 0:0 /var/www/html/data

    # Recreate. version.php should still be 1800:1800 (separate vol),
    # so the /var/www chown should be SKIPPED. But .ncdata is now 0:0,
    # so the targeted data-dir chown MUST run.
    docker stop "$PUID_TEST_NAME" >/dev/null
    docker rm   "$PUID_TEST_NAME" >/dev/null
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1800 -e PGID=1800 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${wwwvol}:/var/www/html" \
        -v "${datavol}:/var/www/html/data" \
        "$NC_IMAGE" >/dev/null
    sleep 6

    local www_chown data_chown
    www_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -c 'chown -R 1800:1800 /var/www (.*may take a while' || true)
    data_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -c 'chown -R 1800:1800 /var/www/html/data' || true)

    assert_eq "$www_chown" "0" \
        "/var/www chown should be SKIPPED on recreate (version.php sentinel still 1800:1800)"
    [ "$data_chown" -ge 1 ] \
        || { log "expected data-dir chown to fire on drift; got $data_chown lines"; return 1; }

    # And after the targeted chown, .ncdata should be back to 1800:1800:
    run docker exec "$PUID_TEST_NAME" stat -c '%u:%g' /var/www/html/data/.ncdata
    assert_status_zero "$status"
    assert_eq "$output" "1800:1800"

    docker volume rm "$wwwvol" "$datavol" >/dev/null 2>&1 || true
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
