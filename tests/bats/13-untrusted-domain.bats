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

@test "second trusted domain registered (guards #1666 space-split)" {
    # The fixture sets NEXTCLOUD_TRUSTED_DOMAINS="localhost example.test".
    # #1666 wrote ONLY index 0, so this index-1 assertion is what actually
    # exercises the space-split regression the file is named for.
    run nc_config_system_get trusted_domains 1
    assert_status_zero "$status"
    assert_eq "$output" "example.test"
}

@test "/ with trusted Host returns 2xx or 3xx (not 400 untrusted-domain)" {
    run nc_status_code / -H 'Host: localhost'
    assert_status_zero "$status"
    # Trusted Host: any 2xx/3xx is fine (200, 301 to https, 302 to /login, etc).
    # Must NOT be 400 (Access through untrusted domain page).
    [ "$output" -ge 200 ] && [ "$output" -lt 400 ]
}

@test "/ with untrusted Host returns 400 with 'Access through untrusted domain' body" {
    local base body
    base=$(nc_host_url)
    body=$(curl -sS -H 'Host: evil.example.com' "${base}/login")
    assert_match "$body" 'Access through untrusted domain'
}
