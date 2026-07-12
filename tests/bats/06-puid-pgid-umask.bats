#!/usr/bin/env bats
# 06-puid-pgid-umask.bats — host-user mapping behavior.
# Most tests here spin up isolated containers because PUID is fixture-wide.

load '../helpers/lib.bash'
load '../helpers/docker.bash'
load '../helpers/compose.bash'   # compose_exec used by the no-usermod regression test

PUID_TEST_NAME="nc-puid-test-${COMPOSE_PROJECT_NAME:-$$}"

# Every test in this file boots — and several stop/start/recreate — a throwaway
# container, so they're inherently timing-sensitive: a slow or loaded CI runner
# can miss a wait window and flake transiently (the original symptom: a restart
# racing the first-boot install, so the sentinel-gated chown fired twice). The
# root cause of THAT case is fixed in-test (we now wait for the sentinel to
# settle), but container timing flake has a long tail. bats-core reruns a
# failing test up to BATS_TEST_RETRIES extra times — scope a small budget to
# THIS file so a transient flake self-heals without a manual CI rerun, and
# without granting retries to the deterministic static suites (where a retry
# would only mask a real regression). Retries are safe here because teardown
# drops the container and the volume-backed tests pre-clean their named volumes,
# so each attempt starts from a clean first boot.
#
# We assign BATS_TEST_RETRIES *directly* (not `${BATS_TEST_RETRIES:=2}`): bats
# unconditionally `export`s it to 0 before setup() runs, so a `:=` default is a
# no-op and an external BATS_TEST_RETRIES env is clobbered too. The override
# knob is therefore our own var, which bats leaves untouched: run with
# PUID_TEST_RETRIES=0 to disable retries while debugging locally.
setup() {
    BATS_TEST_RETRIES="${PUID_TEST_RETRIES:-2}"
}

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

    # The restart only skips the chowns if the first-boot install has ALREADY
    # settled BOTH ownership sentinels before we stop:
    #   - version.php  — ships with the code, chowned ~immediately, and
    #   - data/.ncdata — written later by `occ maintenance:install`.
    # version.php settling does NOT mean install is done — locally it goes
    # 1500:1500 ~7s before .ncdata does. Waiting on version.php alone stops
    # mid-install, so the restart sees an unsettled data dir and fires a
    # data-dir chown (`chown -R 1500:1500 /var/www/html/data`) — which the
    # count below would otherwise pick up. So wait (up to 60s) for BOTH, the
    # same pattern the recreate test uses, to make the restart deterministic.
    local i
    for i in $(seq 1 60); do
        if docker exec "$PUID_TEST_NAME" sh -c '
            [ -f /var/www/html/version.php ] \
            && [ -f /var/www/html/data/.ncdata ] \
            && [ "$(stat -c %u:%g /var/www/html/version.php)" = "1500:1500" ] \
            && [ "$(stat -c %u:%g /var/www/html/data/.ncdata)"  = "1500:1500" ]
        ' 2>/dev/null; then break; fi
        sleep 1
    done

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
    # And the /var/www chown itself must be SKIPPED on the restart — that's the
    # named behavior. version.php is already 1500:1500 from the first boot, so
    # the sentinel skips the second chown: exactly 1 www-chown line across both
    # starts. Anchor the match to the WEBROOT chown specifically: the log line
    # is `chown -R 1500:1500 /var/www (` (plain) or `… /var/www [` (pruned), so
    # require `/var/www` to be followed by a space + `(`/`[`. A bare
    # `/var/www` substring would also match the data-dir chown
    # (`… /var/www/html/data (`) and conflate the two counts.
    # (`grep -c` exits 1 when count is 0; `|| true` keeps bats' set -e happy.)
    local chown_count
    chown_count=$(docker logs "$PUID_TEST_NAME" 2>&1 | grep -cE 'chown -R 1500:1500 /var/www [[(]' || true)
    assert_eq "$chown_count" "1" "chown should run once (first boot) and be skipped on restart via sentinel"
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
    # Pre-clean so a bats retry (or a leaked volume from a killed run) starts
    # from a genuine fresh first boot, not a half-populated webroot.
    docker volume rm "$vol" >/dev/null 2>&1 || true

    # First boot — fresh install, chown SHOULD run:
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1500 -e PGID=1500 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${vol}:/var/www/html" \
        "$NC_IMAGE" >/dev/null

    # Wait for upstream install to finish creating .ncdata at the expected
    # ownership. Without this, racing the install means the recreate below
    # sees a missing .ncdata sentinel → data-dir chown fires → false test
    # failure. Up to 60s for sqlite install.
    local i
    for i in $(seq 1 60); do
        if docker exec "$PUID_TEST_NAME" sh -c '
            [ -f /var/www/html/version.php ] \
            && [ -f /var/www/html/data/.ncdata ] \
            && [ "$(stat -c %u:%g /var/www/html/version.php)" = "1500:1500" ] \
            && [ "$(stat -c %u:%g /var/www/html/data/.ncdata)"  = "1500:1500" ]
        ' 2>/dev/null; then break; fi
        sleep 1
    done

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
    # Pre-clean so a bats retry starts from a fresh data volume.
    docker volume rm "$datavol" >/dev/null 2>&1 || true

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
    # Pre-clean so a bats retry starts from fresh webroot + data volumes.
    docker volume rm "$wwwvol" "$datavol" >/dev/null 2>&1 || true

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

# Regression for the LSIO-migration first-boot perf issue: after the
# flatten step, /var/www/html/version.php is missing (it lived inside
# www/nextcloud/ which got moved to LSIO_BACKUP) so the www sentinel
# triggers a chown. WITHOUT the prune optimisation, that chown
# stat-walks the multi-TB data dir even though .ncdata says ownership
# is already correct — hours of wasted IO on every migration.
@test "first-boot after flatten prunes data dir when .ncdata sentinel matches" {
    local wwwvol="puid-prune-www-$$"
    local datavol="puid-prune-data-$$"
    # Pre-clean so a bats retry starts from fresh webroot + data volumes.
    docker volume rm "$wwwvol" "$datavol" >/dev/null 2>&1 || true

    # Bootstrap a NC instance to create both sentinels at PUID=1900:
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1900 -e PGID=1900 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${wwwvol}:/var/www/html" \
        -v "${datavol}:/var/www/html/data" \
        "$NC_IMAGE" >/dev/null
    local i
    for i in $(seq 1 60); do
        docker exec "$PUID_TEST_NAME" test -f /var/www/html/data/.ncdata 2>/dev/null && break
        sleep 1
    done
    run docker exec "$PUID_TEST_NAME" stat -c '%u:%g' /var/www/html/data/.ncdata
    assert_eq "$output" "1900:1900"

    # Simulate the migration-flatten state: data dir intact, version.php gone:
    docker exec "$PUID_TEST_NAME" rm -f /var/www/html/version.php

    # Recreate. New boot:
    #   www_sentinel missing  -> www_needs_chown=1
    #   .ncdata correct       -> data_needs_chown=0
    #   data_dir under /var/www → MUST prune the walk
    docker stop "$PUID_TEST_NAME" >/dev/null
    docker rm   "$PUID_TEST_NAME" >/dev/null
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1900 -e PGID=1900 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${wwwvol}:/var/www/html" \
        -v "${datavol}:/var/www/html/data" \
        "$NC_IMAGE" >/dev/null
    sleep 8

    local prune_lines
    prune_lines=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -c 'pruning /var/www/html/data' || true)
    [ "$prune_lines" -ge 1 ] \
        || { log "expected the entrypoint to prune the data dir; saw $prune_lines lines"; return 1; }

    # And just plain `chown -R /var/www` (without the prune annotation)
    # MUST NOT appear — that'd mean we re-walked the data dir.
    local unconditional_chown
    unconditional_chown=$(docker logs "$PUID_TEST_NAME" 2>&1 \
        | grep -cE 'chown -R 1900:1900 /var/www \(' || true)
    assert_eq "$unconditional_chown" "0" \
        "expected NO unconditional /var/www chown — should have pruned the data subtree"

    docker volume rm "$wwwvol" "$datavol" >/dev/null 2>&1 || true
}

# Regression for the 2026-05-17 multi-hour hang: modern shadow-utils'
# `usermod -u` does an implicit recursive ownership update of the
# user's home directory (/var/www) — happens INSIDE usermod, before
# any of our sentinel logic gets to run. On a multi-TB HDD data
# volume that's hours. The fix is to edit /etc/passwd directly via
# sed (microseconds) and rely on our own sentinel-gated chown.
@test "PUID change does NOT invoke usermod (which would do hidden recursive walk)" {
    # The entrypoint script itself must not call the `usermod`/`groupmod`
    # binaries when changing uid/gid. They're allowed to exist in the
    # image (other things might want them), but our entrypoint must use
    # direct file edits — usermod -u does an implicit recursive home-dir
    # chown which hangs for hours on multi-TB data volumes.
    run compose_exec sh -c 'grep -nE "^[[:space:]]*(usermod|groupmod)[[:space:]]" /usr/local/bin/container-entrypoint.sh || true'
    assert_status_zero "$status"
    [ -z "$output" ] \
        || { log "entrypoint still invokes usermod/groupmod (matches: $output)"; return 1; }
}
@test "PUID change logs the 'direct /etc/passwd edit' marker" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e PUID=1600 -e PGID=1600 \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 4
    run docker logs "$PUID_TEST_NAME"
    assert_status_zero "$status"
    assert_match "$output" 'direct /etc/passwd edit, no implicit recurse'
    assert_match "$output" 'direct /etc/group edit, no implicit recurse'
}

# Regression: a non-numeric PUID/PGID (a group/user NAME like PGID=users, or a
# typo containing sed's '|' delimiter) must NOT be written verbatim into
# /etc/passwd+/etc/group (corruption) nor abort the entrypoint under `set -e`
# (the '|' would break the sed s||| and brick the container). Like UMASK, the
# entrypoint warns and falls back to the current id — www-data stays uid 33.
@test "non-numeric PGID is rejected (no corruption, container still boots)" {
    docker run -d --name "$PUID_TEST_NAME" \
        -e PGID=users \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    sleep 4
    run docker logs "$PUID_TEST_NAME"
    assert_status_zero "$status"
    assert_match "$output" "non-numeric PGID='users', keeping current gid"
    # www-data must still resolve (passwd/group not corrupted) and stay at 33.
    run docker exec "$PUID_TEST_NAME" id -u www-data
    assert_status_zero "$status"
    assert_eq "$output" "33"
    run docker exec "$PUID_TEST_NAME" id -g www-data
    assert_status_zero "$status"
    assert_eq "$output" "33"
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
