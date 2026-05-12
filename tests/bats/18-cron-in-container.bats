#!/usr/bin/env bats
# 18-cron-in-container.bats — NEXTCLOUD_CRON_ENABLE=true must produce a 4th
# supervisord program (cron) running busybox crond with the www-data crontab.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

setup() {
    if [ "${SCENARIO_CRON:-none}" != "incontainer" ]; then
        skip "scenario SCENARIO_CRON=$SCENARIO_CRON, this test requires incontainer"
    fi
}

@test "cron supervisord program is RUNNING" {
    nc_supervisorctl_running cron
}

@test "/var/spool/cron/crontabs/www-data contains the cron.php directive" {
    run compose_exec cat /var/spool/cron/crontabs/www-data
    assert_status_zero "$status"
    assert_match "$output" 'php -f /var/www/html/cron\.php'
}

@test "crond started successfully (look for boot log)" {
    run compose logs nc
    assert_status_zero "$status"
    assert_match "$output" 'crond \(busybox'
}

@test "cron program has no permission errors in logs" {
    run compose logs nc
    assert_status_zero "$status"
    assert_not_match "$output" "crond: can't open '/dev/stdout': Permission denied"
}
