#!/usr/bin/env bats
# 20-notify-push-up.bats — NOTIFY_PUSH_ENABLE=true must yield a running
# notify-push supervisord program, register the binary URL in NC config,
# and accept WebSocket upgrades through nginx /push/.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'

setup() {
    if [ "${SCENARIO_NOTIFY_PUSH:-false}" != "true" ]; then
        skip "scenario SCENARIO_NOTIFY_PUSH=$SCENARIO_NOTIFY_PUSH, this test requires true"
    fi
}

@test "notify-push supervisord program is RUNNING" {
    nc_supervisorctl_running notify-push
}

@test "notify_push binary version matches pinned release (1.3.2)" {
    run compose_exec /usr/local/bin/notify_push --version
    assert_status_zero "$status"
    assert_match "$output" 'notify_push 1\.3\.2'
}

@test "base_endpoint stored in Nextcloud config (or setup succeeded)" {
    # The wrapper either succeeds setup or falls back to direct
    # config:app:set base_endpoint after 6 retries. Wait up to 3 minutes.
    wait_until 180 5 sh -c '
        compose_url=$(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" exec -T -u www-data nc php /var/www/html/occ config:app:get notify_push base_endpoint 2>/dev/null);
        [ -n "$compose_url" ]
    ' || {
        run occ config:app:get notify_push base_endpoint
        log "base_endpoint after timeout: $output"
        return 1
    }
    run occ config:app:get notify_push base_endpoint
    assert_match "$output" 'http://localhost:7867/push'
}

@test "WebSocket upgrade to /push/ws returns 101 Switching Protocols" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -D - \
        -H 'Upgrade: websocket' \
        -H 'Connection: Upgrade' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "${base}/push/ws"
    assert_status_zero "$status"
    assert_match "$output" 'HTTP/1\.[01] 101 Switching Protocols'
    # nginx lowercases header names in proxied responses
    assert_match "$output" '[Uu]pgrade: websocket'
}

@test "notify_push app installed + enabled in Nextcloud" {
    nc_app_enabled notify_push
}
