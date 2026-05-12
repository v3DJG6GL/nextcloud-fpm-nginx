#!/usr/bin/env bats
# 00-smoke.bats — sanity tests proving the fixture is up and the framework works.
# Run first. If this fails, nothing else will.

load '../helpers/lib.bash'
load '../helpers/docker.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'

@test "image-under-test is present locally" {
    image_present "$NC_IMAGE"
}

@test "compose stack is running" {
    run compose ps --status=running --services
    assert_status_zero "$status"
    assert_contains "$output" 'nc'
}

@test "nc container is healthy" {
    local cid
    cid=$(compose ps -q nc)
    [ -n "$cid" ]
    wait_for_health "$cid" 180 healthy
}

@test "status.php reports installed=true" {
    run nc_status_php
    assert_status_zero "$status"
    assert_match "$output" '"installed":true'
    assert_match "$output" '"maintenance":false'
}

@test "nginx is responding on port 80" {
    run nc_status_code /
    assert_status_zero "$status"
    [ "$output" -ge 200 ] && [ "$output" -lt 500 ]
}
