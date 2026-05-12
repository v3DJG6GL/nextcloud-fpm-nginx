#!/usr/bin/env bats
# 11-security-headers.bats — all 5 Nextcloud upstream security headers must be
# emitted on every response. Catches header regressions in nginx.conf.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "Referrer-Policy: no-referrer" {
    run nc_headers /
    assert_status_zero "$status"
    assert_match "$output" 'Referrer-Policy: no-referrer'
}

@test "X-Content-Type-Options: nosniff" {
    run nc_headers /
    assert_match "$output" 'X-Content-Type-Options: nosniff'
}

@test "X-Frame-Options: SAMEORIGIN" {
    run nc_headers /
    assert_match "$output" 'X-Frame-Options: SAMEORIGIN'
}

@test "X-Permitted-Cross-Domain-Policies: none" {
    run nc_headers /
    assert_match "$output" 'X-Permitted-Cross-Domain-Policies: none'
}

@test "X-Robots-Tag: noindex, nofollow" {
    run nc_headers /
    assert_match "$output" 'X-Robots-Tag: noindex, nofollow'
}

@test "Content-Security-Policy header emitted by Nextcloud PHP" {
    run nc_headers /
    assert_match "$output" 'Content-Security-Policy:'
}

@test "X-Powered-By header stripped (fastcgi_hide_header)" {
    run nc_headers /
    assert_not_match "$output" '^X-Powered-By:'
}

@test "Server header has no version info (server_tokens off)" {
    run nc_headers /
    # nginx default is "Server: nginx/1.26.x"; server_tokens off → "Server: nginx"
    assert_match "$output" '^Server: nginx\r?$'
}
