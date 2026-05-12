#!/usr/bin/env bats
# 08-install-fresh.bats — first-install side effects on a fresh volume.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'
load '../helpers/nc.bash'

@test "status.php JSON parses cleanly" {
    run nc_status_php
    assert_status_zero "$status"
    assert_match "$output" '^\{.*\}$'
}

@test "instanceid is generated and non-empty" {
    run nc_config_system_get instanceid
    assert_status_zero "$status"
    # 11+ chars alphanumeric, Nextcloud's standard form
    [ -n "$output" ]
    assert_match "$output" '^[a-z0-9]{8,}$'
}

@test "version.php exists in /var/www/html" {
    run compose_exec test -f /var/www/html/version.php
    assert_status_zero "$status"
}

@test "occ status reports installed=true and maintenance=false" {
    run occ status --output=json
    assert_status_zero "$status"
    assert_match "$output" '"installed":\s*true'
    assert_match "$output" '"maintenance":\s*false'
}
