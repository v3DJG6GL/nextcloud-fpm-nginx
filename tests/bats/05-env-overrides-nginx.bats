#!/usr/bin/env bats
# 05-env-overrides-nginx.bats — NGINX_SERVER_NAME patches nginx.conf in place;
# NGINX_HSTS appears as a conf.d drop-in and is emitted on responses.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "NGINX_SERVER_NAME patches server_name in nginx.conf" {
    run compose_exec grep -E '^\s*server_name test\.local;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "NGINX_HSTS drops into /etc/nginx/conf.d/90-env-overrides.conf" {
    run compose_exec cat /etc/nginx/conf.d/90-env-overrides.conf
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security'
    assert_match "$output" 'max-age=31536000'
}

@test "Strict-Transport-Security header on responses" {
    run nc_headers /
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security: max-age=31536000'
}

@test "nginx config validates after server_name patch + HSTS include" {
    run compose_exec nginx -t
    assert_status_zero "$status"
}
