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
    # #1666 wrote ONLY the first space-separated entry, so this asserts the
    # SECOND entry (example.test) made it in — the space-split regression the
    # file is named for. Assert by membership in the full trusted_domains array
    # rather than a fixed index: the upstream entrypoint writes env-supplied
    # domains starting at index 1 (index 0 is the install default 'localhost'),
    # so example.test lands at index 2, not 1.
    run nc_config_system_get trusted_domains
    assert_status_zero "$status"
    assert_match "$output" 'example\.test'
}

@test "/ with trusted Host returns 2xx or 3xx (not 400 untrusted-domain)" {
    run nc_status_code / -H 'Host: localhost'
    assert_status_zero "$status"
    # Trusted Host: any 2xx/3xx is fine (200, 301 to https, 302 to /login, etc).
    # Must NOT be 400 (Access through untrusted domain page).
    [ "$output" -ge 200 ] && [ "$output" -lt 400 ]
}

@test "/ with untrusted Host returns 400 with 'Access through untrusted domain' body" {
    # nc_curl appends an HTTP:%{http_code} trailer so we verify the status the
    # test name promises (400), not just the body text — a regression that
    # served the page with a 2xx would otherwise pass on the body match alone.
    run nc_curl GET /login -H 'Host: evil.example.com'
    assert_status_zero "$status"
    assert_match "$output" 'HTTP:400'
    assert_match "$output" 'Access through untrusted domain'
}
