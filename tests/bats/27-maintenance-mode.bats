#!/usr/bin/env bats
# 27-maintenance-mode.bats — `occ maintenance:mode` toggles correctly and
# the Docker HEALTHCHECK respects it (catches healthcheck false-positive bug).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'
load '../helpers/docker.bash'

setup_file() {
    # Make sure no previous test left maintenance mode on (could happen if
    # a different bats file failed mid-test).
    occ maintenance:mode --off >/dev/null 2>&1 || true
    sleep 1
}

teardown_file() {
    # Always clear maintenance mode after this file so other tests downstream
    # see a clean state.
    occ maintenance:mode --off >/dev/null 2>&1 || true
}

@test "default state: maintenance=false" {
    run occ status --output=json
    assert_status_zero "$status"
    assert_match "$output" '"maintenance":false'
}

@test "occ maintenance:mode --on flips status.php to maintenance=true" {
    occ maintenance:mode --on >/dev/null
    # Maintenance mode propagates immediately
    sleep 1
    run nc_status_php
    assert_status_zero "$status"
    assert_match "$output" '"maintenance":true'
    # Cleanup: turn it back off
    occ maintenance:mode --off >/dev/null
    sleep 1
}

@test "after maintenance:mode --off, status.php returns maintenance=false again" {
    # Verify clearing works (relevant: failed upgrades sometimes leave it stuck)
    run nc_status_php
    assert_match "$output" '"maintenance":false'
}

@test "healthcheck CMD stays healthy in maintenance mode (only checks installed:true)" {
    # The Docker HEALTHCHECK is `curl -fsS status.php | grep -q "installed":true`.
    # In maintenance mode status.php still reports installed:true, so the grep
    # succeeds and the healthcheck returns 0. This is INTENTIONAL — otherwise
    # Docker would restart the container while an admin performs maintenance.
    # Assert that documented behavior exactly (status -eq 0), not a tautology.
    local cid
    cid=$(compose ps -q nc)
    occ maintenance:mode --on >/dev/null
    sleep 1
    # Run the healthcheck CMD manually:
    run docker exec "$cid" sh -c 'curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q "\"installed\":true"'
    occ maintenance:mode --off >/dev/null
    assert_status_zero "$status" "healthcheck must stay green in maintenance mode (status.php still installed:true)"
}
