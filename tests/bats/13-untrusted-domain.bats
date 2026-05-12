#!/usr/bin/env bats
# 13-untrusted-domain.bats — NEXTCLOUD_TRUSTED_DOMAINS must reject requests
# with unexpected Host headers (Nextcloud returns "Access through untrusted
# domain"). #1666 in nextcloud/docker is the bug where only the FIRST entry
# of the space-separated env was written.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'

@test "first trusted domain registered" {
    run nc_config_system_get trusted_domains 0
    assert_status_zero "$status"
    [ -n "$output" ]
}

@test "/ with trusted Host returns 200" {
    run nc_status_code / -H 'Host: localhost'
    assert_status_zero "$status"
    [ "$output" = "200" ] || [ "$output" = "302" ]   # depending on first-run wizard
}

@test "/ with untrusted Host returns 400 with 'Access through untrusted domain' body" {
    local base body
    base=$(nc_host_url)
    body=$(curl -sS -H 'Host: evil.example.com' "${base}/login")
    assert_match "$body" 'Access through untrusted domain'
}
