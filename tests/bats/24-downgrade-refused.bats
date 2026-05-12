#!/usr/bin/env bats
# 24-downgrade-refused.bats — upstream NC entrypoint refuses to start when
# /var/www/html/version.php declares a HIGHER version than the image's
# /usr/src/nextcloud/version.php (issue #2015, etc.). Catches the
# common "I downgraded the image tag" foot-gun.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

CTN="nc-downgrade-test-$$"

setup() {
    if [ -z "${NC_IMAGE_PREV:-}" ]; then
        skip "NC_IMAGE_PREV not set — can't simulate downgrade without two majors"
    fi
}

teardown() {
    container_rm "$CTN"
}

@test "boot current, then try prior image — entrypoint refuses with explicit error" {
    # Boot current image first to populate version.php with the current major.
    docker run -d --name "${CTN}-init" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "${CTN}-data:/var/www/html" \
        "$NC_IMAGE" >/dev/null
    sleep 8
    wait_until 120 5 sh -c "docker exec ${CTN}-init curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q '\"installed\":true'"
    docker rm -f "${CTN}-init" >/dev/null

    # Now try to start the PRIOR major against the same volume.
    docker run --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -v "${CTN}-data:/var/www/html" \
        "$NC_IMAGE_PREV" >/dev/null 2>&1 || true
    sleep 5
    local exit_code
    exit_code=$(container_exit_code "$CTN")
    [ "$exit_code" -ne 0 ] || log "expected non-zero exit on downgrade attempt (got $exit_code)"
    run docker logs "$CTN"
    assert_match "$output" 'higher than the docker image|downgrading is not supported'

    # Clean up the volume
    docker volume rm "${CTN}-data" >/dev/null 2>&1 || true
}
