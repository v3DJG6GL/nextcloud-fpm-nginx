#!/usr/bin/env bats
# 12-trusted-proxies.bats — nginx must honor X-Forwarded-For from private
# subnets and rewrite $remote_addr. Misconfiguration leads to all proxied
# requests being attributed to the proxy's IP, breaking bruteforce protection.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "nginx.conf declares real_ip_header X-Forwarded-For" {
    run compose_exec grep -E 'real_ip_header X-Forwarded-For;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "real_ip_recursive on (handles chained proxies)" {
    run compose_exec grep -E 'real_ip_recursive on;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "all four RFC1918/ULA subnets present in set_real_ip_from" {
    run compose_exec sh -c 'grep -E "^\s*set_real_ip_from " /etc/nginx/nginx.conf'
    assert_status_zero "$status"
    assert_match "$output" '10\.0\.0\.0/8'
    assert_match "$output" '172\.16\.0\.0/12'
    assert_match "$output" '192\.168\.0\.0/16'
    assert_match "$output" 'fc00::/7'
}

@test "X-Forwarded-For from trusted subnet rewrites remote_addr" {
    # Probe an endpoint that echoes back the seen client IP via the access log.
    # We trigger one request with a spoofed XFF and one without, then read the log.
    nc_curl GET / -H 'X-Forwarded-For: 198.51.100.42' >/dev/null 2>&1 || true
    sleep 1
    run compose logs --tail=20 nc
    assert_status_zero "$status"
    assert_match "$output" '198\.51\.100\.42'
}
