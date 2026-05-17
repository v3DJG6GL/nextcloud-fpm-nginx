#!/usr/bin/env bats
# 15-mime-types.bats — .mjs (ES modules) and .wasm files must be served with
# correct MIME types or the Files app breaks in Edge/Safari (server#42989).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "nginx adds text/javascript for .mjs" {
    run compose_exec sh -c 'grep -E "text/javascript mjs" /etc/nginx/nginx.conf'
    assert_status_zero "$status"
}

@test "mime.types declares application/wasm" {
    run compose_exec grep -E '^[[:space:]]*application/wasm' /etc/nginx/mime.types
    assert_status_zero "$status"
}

# Real HTTP-level checks: the previous tests only grepped the config and would
# pass even if the `types {}` block were placed inside `server {}` (which
# REPLACES the inherited mime map and makes every static asset come back as
# application/octet-stream — combined with X-Content-Type-Options: nosniff,
# browsers refuse to execute the JS and the login form never mounts). See
# nginx.conf http {} block.

@test "served .js gets a javascript mime (not octet-stream)" {
    # Accept either application/javascript or text/javascript (RFC 9239
    # standardised the latter in 2022 and recent Debian mime.types use it).
    # The regression we're guarding against is octet-stream + nosniff.
    run nc_headers /core/js/oc.js
    assert_status_zero "$status"
    local ct
    ct=$(header_value "$output" Content-Type)
    [[ "$ct" == *javascript* ]] \
        || { log "expected */javascript, got: $ct"; return 1; }
}

@test "served .css gets text/css (not octet-stream)" {
    run nc_headers /core/css/server.css
    assert_status_zero "$status"
    local ct
    ct=$(header_value "$output" Content-Type)
    [[ "$ct" == text/css* ]] \
        || { log "expected text/css, got: $ct"; return 1; }
}

@test "served .mjs gets text/javascript (the whole reason the types{} block exists)" {
    # Use a guaranteed-present .mjs if any ship; otherwise check via nginx -T
    # that the type is registered globally rather than only in server scope.
    run compose_exec sh -c 'nginx -T 2>/dev/null | awk "/^http {/,/^}/" | grep -E "text/javascript .*mjs"'
    assert_status_zero "$status" "text/javascript mjs mapping must be in http{} scope, not server{}"
}

@test "static assets get long Cache-Control via the immutable-asset block" {
    # Nextcloud's nginx reference applies Cache-Control: public, max-age=15778463
    # to css/js/svg/png/etc — verify the location ~ \.(css|js|svg|...) block routes
    # correctly. Use core/img/favicon.svg (always shipped by Nextcloud).
    run nc_headers /core/img/favicon.svg
    assert_status_zero "$status"
    assert_match "$output" 'Cache-Control: public, max-age=15778463'
}
