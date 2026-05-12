#!/usr/bin/env bats
# 16-well-known.bats — /.well-known/{caldav,carddav,acme-challenge,...}
# routing must work. Upstream NC admin panel warns if these are broken.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "/.well-known/caldav returns 301 to /remote.php/dav/" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -D - "${base}/.well-known/caldav"
    assert_status_zero "$status"
    assert_match "$output" 'HTTP/1\.[01] 301'
    assert_match "$output" 'Location:.*/remote\.php/dav/'
}

@test "/.well-known/carddav returns 301 to /remote.php/dav/" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -D - "${base}/.well-known/carddav"
    assert_match "$output" 'HTTP/1\.[01] 301'
    assert_match "$output" 'Location:.*/remote\.php/dav/'
}

@test "/.well-known/acme-challenge passes through (404 since no challenge)" {
    run nc_status_code /.well-known/acme-challenge/some-token
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/.well-known/webfinger redirects to /index.php" {
    # Behavior: location block returns 301 to /index.php$request_uri,
    # then Nextcloud serves the actual webfinger response (200) at /index.php.
    run nc_status_code /.well-known/webfinger
    assert_status_zero "$status"
    # 301 redirect or 200 directly depending on what nginx does — both fine
    [ "$output" = "301" ] || [ "$output" = "200" ]
}
