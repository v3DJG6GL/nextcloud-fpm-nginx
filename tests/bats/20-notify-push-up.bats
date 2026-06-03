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

@test "notify_push binary version matches the pinned NOTIFY_PUSH_VERSION" {
    run compose_exec /usr/local/bin/notify_push --version
    assert_status_zero "$status"
    # Version kept in lockstep with the Dockerfile NOTIFY_PUSH_VERSION ARG by the
    # notify_push customManager in .github/renovate.json — do not hand-edit.
    assert_match "$output" 'notify_push 1.3.2'
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

# Regression guard for the 2026-05-17 production failure: after an
# LSIO->this-image migration where apps_paths was misconfigured (both
# entries set to url=/apps) AND apps were physically moved between
# apps/ and custom_apps/, NC's Redis cache held a stale route
# collection. Every /apps/notify_push/* HTTP request returned NC's
# themed 404 (~5 KB) even after docker restart, because Redis lives in
# a separate container that survives the restart and CLI bypasses the
# cache for many lookups.
#
# Direct check: hit the cookie endpoint and require a real response.
# 200/401/403 = route matched (controller may auth-gate). 404 = the
# route was never registered → bug.
@test "notify_push HTTP routes reachable (regression: route registration in HTTP context)" {
    run nc_status_code /apps/notify_push/test/cookie
    assert_status_zero "$status"
    [[ "$output" =~ ^(200|401|403)$ ]] \
        || { log "expected route to register, got HTTP $output"; return 1; }
}

# Cross-check: ask NC what URL the route resolves to, then GET that
# URL through nginx. Catches the case where NC's URL generator and
# request matcher disagree (which silently 404s for the daemon).
# Must explicitly loadApp() first — a bare `php -r` doesn't run
# base.php's loadApps() pass, so Router::loadRoutes hits its
# isAppLoaded() check and skips registering routes (Router.php:154).
@test "notify_push reachable at NC-generated URL (matches whatever NC's linkToRoute emits)" {
    run compose_exec sh -c 'php -r '"'"'
        require "/var/www/html/lib/base.php";
        \OC_App::loadApp("notify_push");
        echo \OC::$server->get(\OCP\IURLGenerator::class)
            ->linkToRoute("notify_push.test.cookie");
    '"'"
    assert_status_zero "$status"
    local url="$output"
    [ -n "$url" ] || { log "linkToRoute returned empty — notify_push routes did not register"; return 1; }

    # Dispatch through nginx; require a real response, not the themed 404.
    run nc_status_code "$url"
    assert_status_zero "$status"
    [[ "$output" =~ ^(200|401|403)$ ]] \
        || { log "linkToRoute returned $url but it serves HTTP $output"; return 1; }
}
