#!/usr/bin/env bats
# 19-cron-sidecar.bats — alternative cron pattern: a separate container
# in the compose stack with command=/cron.sh runs cron alongside the main
# nextcloud container.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

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
    run compose exec -T nc-cron sh -c 'ls -l /cron.sh && cat /cron.sh'
    assert_status_zero "$status"
    assert_match "$output" 'busybox crond'
}

@test "in-container cron is NOT also enabled (mutual exclusion)" {
    # With SCENARIO_CRON=sidecar, run-all.sh does NOT set NC_CRON_INCONTAINER.
    # The main nc container should have no supervisord cron program. Gate on the
    # explicit "no such process" message (via the helper) rather than the raw
    # exit code: a cron program that IS defined but sits in FATAL/BACKOFF also
    # exits non-zero, so a raw assert_status_nonzero would stay green even when
    # the double-fire condition this test guards against is present.
    nc_supervisorctl_absent cron
}
