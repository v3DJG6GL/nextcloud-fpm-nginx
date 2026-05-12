#!/usr/bin/env bats
# 21-notify-push-prereqs.bats — guard-rails when notify_push is disabled.
# Verifies the OFF-path: binary still ships in the image, /push/ returns 502
# (no daemon), supervisord doesn't have a cron program, no errors in logs.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'

setup() {
    if [ "${SCENARIO_NOTIFY_PUSH:-false}" != "false" ]; then
        skip "scenario SCENARIO_NOTIFY_PUSH=$SCENARIO_NOTIFY_PUSH, this test requires false"
    fi
}

@test "notify_push binary present in image even when disabled" {
    run compose_exec test -x /usr/local/bin/notify_push
    assert_status_zero "$status"
}

@test "no supervisord 'notify-push' program when disabled" {
    nc_supervisorctl_absent notify-push
}

@test "/push/ returns 502 (no daemon to proxy to) — harmless" {
    # Confirming: /push/ location IS in nginx.conf but the upstream is down,
    # so nginx returns 502. Important: no other URL is affected.
    run nc_status_code /push/test/cookie
    assert_status_zero "$status"
    assert_eq "$output" "502"
}

@test "no notify_push-related crash loops in logs" {
    run compose logs --tail=200 nc
    assert_status_zero "$status"
    assert_not_match "$output" 'notify-push.*FATAL'
    assert_not_match "$output" 'notify-push.*BACKOFF'
}
