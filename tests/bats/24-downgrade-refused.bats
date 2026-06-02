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

    # Now try to start the PRIOR major against the same volume, DETACHED.
    # Under supervisord the container does NOT exit on refusal: the upstream
    # entrypoint logs the error and exits, but supervisord (PID 1) stays up and
    # restarts it into BACKOFF/FATAL. A foreground `docker run` would therefore
    # hang forever, and a running container's exit code is 0 (so an exit-code
    # assertion can't work). Poll the logs for the refusal message instead —
    # mirrors test 25, whose comment notes "the entrypoint may log + exit OR loop".
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -v "${CTN}-data:/var/www/html" \
        "$NC_IMAGE_PREV" >/dev/null 2>&1 || true

    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if docker logs "$CTN" 2>&1 | grep -qE 'higher than the docker image|downgrading is not supported'; then
            break
        fi
        sleep 3
    done

    run docker logs "$CTN"
    assert_match "$output" 'higher than the docker image|downgrading is not supported'

    # Clean up the volume
    docker volume rm "${CTN}-data" >/dev/null 2>&1 || true
}
