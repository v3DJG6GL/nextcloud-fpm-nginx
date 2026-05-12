#!/usr/bin/env bats
# 19-cron-sidecar.bats — alternative cron pattern: a separate container
# in the compose stack with command=/cron.sh runs cron alongside the main
# nextcloud container.

load '../helpers/lib.bash'
load '../helpers/compose.bash'

setup() {
    if [ "${SCENARIO_CRON:-none}" != "sidecar" ]; then
        skip "scenario SCENARIO_CRON=$SCENARIO_CRON, this test requires sidecar"
    fi
}

@test "nc-cron service is running in the compose stack" {
    run compose ps --services --status=running
    assert_status_zero "$status"
    assert_match "$output" '^nc-cron$'
}

@test "the sidecar uses /cron.sh from the same image" {
    run compose exec -T nc-cron sh -c 'ls -l /cron.sh && head -1 /cron.sh'
    assert_status_zero "$status"
    assert_match "$output" 'busybox crond'
}

@test "in-container cron is NOT also enabled (mutual exclusion)" {
    # With SCENARIO_CRON=sidecar, run-all.sh does NOT set NC_CRON_INCONTAINER.
    # The main nc container should have no supervisord cron program.
    run compose_exec supervisorctl status cron
    assert_status_nonzero "$status" "expected 'cron' program absent from main container"
}
