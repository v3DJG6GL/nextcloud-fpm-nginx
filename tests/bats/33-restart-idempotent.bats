#!/usr/bin/env bats
# 33-restart-idempotent.bats — docker compose restart preserves state.
# Catches: installed=false after restart (issue #1682), maintenance flag
# left on, env-override files re-rendered idempotently.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

@test "instanceid persists across restart" {
    local before after
    before=$(occ config:system:get instanceid 2>/dev/null | sed 's/[[:space:]]*$//')
    [ -n "$before" ]
    compose restart nc >/dev/null
    wait_for_nc_install 180
    after=$(occ config:system:get instanceid 2>/dev/null | sed 's/[[:space:]]*$//')
    assert_eq "$after" "$before" "instanceid must not regenerate on restart"
}

@test "occ status still reports installed=true after restart" {
    run occ status --output=json
    assert_status_zero "$status"
    assert_match "$output" '"installed":true'
    assert_match "$output" '"maintenance":false'
}

@test "env-override files are regenerated idempotently after restart" {
    # zz-env-overrides.ini should exist + have the same content
    local before after
    before=$(compose_exec md5sum /usr/local/etc/php/conf.d/zz-env-overrides.ini 2>/dev/null | awk '{print $1}')
    [ -n "$before" ]
    compose restart nc >/dev/null
    wait_for_nc_install 180
    after=$(compose_exec md5sum /usr/local/etc/php/conf.d/zz-env-overrides.ini 2>/dev/null | awk '{print $1}')
    assert_eq "$after" "$before" "zz-env-overrides.ini must be identical across restarts"
}
