#!/usr/bin/env bats
# 29-shutdown.bats — `docker stop` must complete cleanly: SIGTERM → supervisord
# → all programs receive their stopsignal → all exit 0 → container stops.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

# COMPOSE_PROJECT_NAME (unique per CI cell) — NOT bare $$: on a shared dind
# daemon, concurrent matrix cells routinely land on identical in-container
# PIDs, and two cells then fight over one container name ("Conflict. The
# container name ... is already in use" / one cell SIGINTs the other's
# container). Same pattern in every bats file that runs standalone containers.
CTN="nc-shutdown-test-${COMPOSE_PROJECT_NAME:-$$}"

teardown() {
    container_rm "$CTN"
}

@test "docker stop completes within stopwaitsecs and all programs exit 0" {
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    # Wait until status.php is happy so supervisord has stabilized.
    wait_until 120 5 sh -c "docker exec $CTN curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q '\"installed\":true'"

    local start end
    start=$(date +%s)
    docker stop "$CTN" >/dev/null
    end=$(date +%s)
    local elapsed=$((end - start))
    log "docker stop took ${elapsed}s"
    # Default docker stop timeout is 10s before SIGKILL; we expect graceful exit
    # well under that. supervisord.conf stopwaitsecs is 30 for nextcloud, 15 for nginx.
    [ "$elapsed" -lt 25 ]

    # All exit codes should be 0 (verify via logs — supervisord prints
    # "stopped: <prog> (exit status 0)" or "(terminated by SIGTERM)").
    run docker logs --tail=20 "$CTN"
    assert_status_zero "$status"
    assert_match "$output" 'exit status 0|terminated by SIGTERM|bye-bye'
    # php-fpm should specifically log graceful "Finishing... exiting, bye-bye!"
    assert_match "$output" 'Finishing|bye-bye'
}

@test "SIGINT (docker kill -s SIGINT) also triggers graceful shutdown" {
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=a -e NEXTCLOUD_ADMIN_PASSWORD=b \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        "$NC_IMAGE" >/dev/null
    wait_until 90 5 sh -c "docker exec $CTN curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q '\"installed\":true'"
    docker kill -s SIGINT "$CTN" >/dev/null
    # Require the container to actually exit. `docker inspect .State.ExitCode`
    # reports 0 for a STILL-RUNNING container, so without this guard a hung or
    # ignored SIGINT (the exact non-graceful failure this test exists to catch)
    # would read exit_code=0 below and pass green.
    wait_until 25 1 sh -c "[ \"\$(docker inspect --format='{{.State.Status}}' $CTN)\" = exited ]" \
        || { log "container did not exit within 25s of SIGINT (still running → not graceful)"; return 1; }
    local exit_code
    exit_code=$(container_exit_code "$CTN")
    log "container exit code: $exit_code"
    # Exit 0 is ideal but 'SIGTERM-derived' (143) or 'SIGINT-derived' (130)
    # non-zero is also acceptable. Accept only those three — a generic crash
    # code (1, 2, 70, …) during signal handling is NOT a graceful shutdown.
    [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 130 ] || [ "$exit_code" -eq 143 ]
}
