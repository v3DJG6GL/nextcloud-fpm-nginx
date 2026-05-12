#!/usr/bin/env bats
# 23-upgrade-fresh.bats — boot the PRIOR major (NC_IMAGE_PREV), wait for
# install, stop, swap to current (NC_IMAGE), boot, verify occ upgrade ran
# and the install survived. Requires NC_IMAGE_PREV env to be set; otherwise
# skipped (CI matrix builds it before this test runs).

load '../helpers/lib.bash'
load '../helpers/docker.bash'

UPGRADE_PROJECT="nc-upgrade-test-$$"

setup() {
    if [ -z "${NC_IMAGE_PREV:-}" ]; then
        skip "NC_IMAGE_PREV not set — skipping upgrade lifecycle test (requires both majors built)"
    fi
}

teardown() {
    docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
}

@test "boot prior major, then upgrade to current; occ upgrade runs and instance survives" {
    # Boot prev image
    NC_IMAGE="$NC_IMAGE_PREV" docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" up -d --wait
    local cid prev_ver
    cid=$(docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" ps -q nc)
    prev_ver=$(docker exec "$cid" cat /var/www/html/version.php | grep -oE "OC_VersionString = '[^']+'" | head -1)
    log "installed prev version: $prev_ver"

    # Swap to current image
    docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" stop nc
    NC_IMAGE="$NC_IMAGE" docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" up -d --wait
    cid=$(docker compose -f tests/compose/upgrade.yaml -p "$UPGRADE_PROJECT" ps -q nc)

    # Wait for upgrade to complete
    wait_for_health "$cid" 300 healthy
    # Verify the upgrade ran by checking version.php advanced
    local new_ver
    new_ver=$(docker exec "$cid" cat /var/www/html/version.php | grep -oE "OC_VersionString = '[^']+'" | head -1)
    log "post-upgrade version: $new_ver"
    [ "$prev_ver" != "$new_ver" ]
    # Maintenance mode should be cleared
    run docker exec -u www-data "$cid" php /var/www/html/occ status --output=json
    assert_status_zero "$status"
    assert_match "$output" '"maintenance":false'
    assert_match "$output" '"installed":true'
}
