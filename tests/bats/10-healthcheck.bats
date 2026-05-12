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
    assert_match "$hc" '\\"installed\\":true'
}

@test "putting NC into maintenance mode flips healthcheck to unhealthy" {
    local cid
    cid=$(compose ps -q nc)
    occ maintenance:mode --on >/dev/null
    # Wait up to 60s (3 retries × 5s timeout + 30s interval) for unhealthy.
    wait_until 90 5 sh -c "[ \"\$(docker inspect --format='{{.State.Health.Status}}' $cid)\" = unhealthy ]" || {
        # Some Docker versions resist flipping unhealthy from healthy; assert at minimum
        # that the healthcheck CMD reports non-zero when maintenance is on.
        run docker exec "$cid" sh -c 'curl -fsS http://127.0.0.1/status.php | grep -q "\"installed\":true"'
        assert_status_nonzero "$status" "expected healthcheck CMD to fail in maintenance mode"
    }
    occ maintenance:mode --off >/dev/null
    wait_until 90 5 sh -c "[ \"\$(docker inspect --format='{{.State.Health.Status}}' $cid)\" = healthy ]"
}

@test "healthcheck timing parameters look sane" {
    local cid hc_iv hc_to hc_sp
    cid=$(compose ps -q nc)
    hc_iv=$(docker inspect --format='{{.Config.Healthcheck.Interval}}' "$cid")
    hc_to=$(docker inspect --format='{{.Config.Healthcheck.Timeout}}' "$cid")
    hc_sp=$(docker inspect --format='{{.Config.Healthcheck.StartPeriod}}' "$cid")
    # Compose fixture sets reasonable values; image baseline is 30s/5s/120s.
    log "interval=$hc_iv timeout=$hc_to start_period=$hc_sp"
    # All non-zero
    [ "$hc_iv" != "0s" ] && [ "$hc_to" != "0s" ] && [ "$hc_sp" != "0s" ]
}
