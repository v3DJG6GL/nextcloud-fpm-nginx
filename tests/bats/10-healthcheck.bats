#!/usr/bin/env bats
# 10-healthcheck.bats — Docker HEALTHCHECK must reflect actual NC state, not
# just HTTP 200. status.php returns 200 with installed=false too.

load '../helpers/lib.bash'
load '../helpers/docker.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

@test "container reaches health=healthy within start-period" {
    local cid
    cid=$(compose ps -q nc)
    [ -n "$cid" ]
    wait_for_health "$cid" 180 healthy
}

@test "healthcheck reads status.php JSON (not just HTTP code)" {
    local cid hc
    cid=$(compose ps -q nc)
    hc=$(docker inspect --format='{{.Config.Healthcheck.Test}}' "$cid")
    assert_match "$hc" 'status\.php'
    assert_match "$hc" '"installed":true'
}

@test "healthcheck deliberately stays healthy in maintenance mode" {
    # Intentional behavior: our HEALTHCHECK only greps for "installed":true,
    # not "maintenance":false. This is so that admin-triggered maintenance
    # mode doesn't trip Docker's restart-on-unhealthy policy mid-operation.
    # Test 118 in 27-maintenance-mode.bats documents this from the runtime
    # angle; here we assert the static HEALTHCHECK string doesn't include
    # the maintenance check.
    local cid hc
    cid=$(compose ps -q nc)
    hc=$(docker inspect --format='{{.Config.Healthcheck.Test}}' "$cid")
    # Anchor on the real healthcheck so the negative assertion below isn't
    # vacuously true against an empty/absent HEALTHCHECK string.
    assert_match "$hc" '"installed":true'
    # Pattern: must NOT include a maintenance:false check
    assert_not_match "$hc" 'maintenance.*false'
}

@test "healthcheck timing parameters look sane" {
    local cid hc_iv hc_to hc_sp
    cid=$(compose ps -q nc)
    hc_iv=$(docker inspect --format='{{.Config.Healthcheck.Interval}}' "$cid")
    hc_to=$(docker inspect --format='{{.Config.Healthcheck.Timeout}}' "$cid")
    hc_sp=$(docker inspect --format='{{.Config.Healthcheck.StartPeriod}}' "$cid")
    # Compose fixture sets reasonable values; image baseline is
    # interval=30s/timeout=5s/start-period=14400s (see Dockerfile HEALTHCHECK).
    log "interval=$hc_iv timeout=$hc_to start_period=$hc_sp"
    # All present and non-zero. An absent HEALTHCHECK makes docker inspect emit
    # an empty string (not "0s"), which the "!= 0s" check alone would pass — so
    # require non-empty too.
    [ -n "$hc_iv" ] && [ "$hc_iv" != "0s" ] \
        && [ -n "$hc_to" ] && [ "$hc_to" != "0s" ] \
        && [ -n "$hc_sp" ] && [ "$hc_sp" != "0s" ]
}
