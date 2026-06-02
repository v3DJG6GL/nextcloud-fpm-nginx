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

@test "NGINX_HSTS drops into /etc/nginx/snippets/nc-hsts.conf" {
    run compose_exec cat /etc/nginx/snippets/nc-hsts.conf
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security'
    assert_match "$output" 'max-age=31536000'
}

@test "Strict-Transport-Security header on responses" {
    run nc_headers /
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security: max-age=31536000'
}

@test "Strict-Transport-Security header on static assets (not just dynamic pages)" {
    # Static assets are served by `location ~ \.(css|js|...)`, which declares its
    # own add_header (Cache-Control) and so must re-include HSTS — regression
    # guard for the per-block add_header reset.
    run nc_headers /core/css/server.css
    assert_status_zero "$status"
    assert_match "$output" 'Strict-Transport-Security: max-age=31536000'
    # Pin that the static-asset location (not a fallthrough to `location /` or a
    # 404) actually served this: Cache-Control: public is emitted ONLY by that
    # block. Without it, dropping .css from the static regex would still inherit
    # server-scope HSTS and this test would stay green.
    assert_match "$output" 'Cache-Control: public'
}

@test "nginx config validates after server_name patch + HSTS include" {
    run compose_exec nginx -t
    assert_status_zero "$status"
}
