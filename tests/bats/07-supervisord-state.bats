#!/usr/bin/env bats
# 07-supervisord-state.bats — supervisord must keep core programs RUNNING;
# optional programs are gated by env vars.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

@test "supervisord program 'nextcloud' is RUNNING" {
    nc_supervisorctl_running nextcloud
}

@test "supervisord program 'nginx' is RUNNING" {
    nc_supervisorctl_running nginx
}

@test "supervisord 'notify-push' present iff NOTIFY_PUSH_ENABLE=true" {
    if [ "${SCENARIO_NOTIFY_PUSH:-false}" = "true" ]; then
        nc_supervisorctl_running notify-push
    else
        nc_supervisorctl_absent notify-push
    fi
}

@test "supervisord 'cron' present iff SCENARIO_CRON=incontainer" {
    if [ "${SCENARIO_CRON:-none}" = "incontainer" ]; then
        nc_supervisorctl_running cron
    else
        nc_supervisorctl_absent cron
    fi
}
