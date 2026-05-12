#!/usr/bin/env bats
# 14-fastcgi-https.bats — fastcgi_param HTTPS is dynamic based on
# X-Forwarded-Proto. When the proxy says https, HTTPS=on; when http, HTTPS=off;
# when no header, default is `on` (assumes behind TLS-terminating proxy).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "nginx.conf defines forwarded_https map" {
    run compose_exec sh -c 'grep -c forwarded_https /etc/nginx/nginx.conf'
    assert_status_zero "$status"
    # Multiple references: the map + the fastcgi_param HTTPS line
    [ "$output" -ge 2 ]
}

@test "fastcgi_param HTTPS references the map variable" {
    run compose_exec sh -c 'grep -E "fastcgi_param HTTPS .forwarded_https" /etc/nginx/nginx.conf'
    assert_status_zero "$status"
}

@test "map default is 'on' (assume behind TLS proxy)" {
    run compose_exec sh -c "awk '/map .http_x_forwarded_proto .forwarded_https/,/^[[:space:]]*}/' /etc/nginx/nginx.conf"
    assert_status_zero "$status"
    assert_match "$output" 'default[[:space:]]+on'
}

@test "map maps 'http' -> 'off' and 'https' -> 'on'" {
    run compose_exec sh -c "awk '/map .http_x_forwarded_proto .forwarded_https/,/^[[:space:]]*}/' /etc/nginx/nginx.conf"
    assert_status_zero "$status"
    assert_match "$output" 'http[[:space:]]+off'
    assert_match "$output" 'https[[:space:]]+on'
}
