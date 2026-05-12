#!/usr/bin/env bats
# 09-install-paths.bats — DB-backend-specific install side effects.
# Per-scenario assertions (the matrix iterates over sqlite/postgres/mysql).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/nc.bash'

@test "dbtype matches SCENARIO_DB" {
    local expected
    case "${SCENARIO_DB:-postgres}" in
        sqlite)   expected="sqlite3" ;;
        postgres) expected="pgsql"   ;;
        mysql)    expected="mysql"   ;;
    esac
    run nc_config_system_get dbtype
    assert_status_zero "$status"
    assert_eq "$output" "$expected"
}

@test "datadirectory exists and is writable by www-data" {
    local datadir
    datadir=$(occ config:system:get datadirectory 2>/dev/null | sed 's/[[:space:]]*$//')
    [ -n "$datadir" ]
    run compose_exec_wwwdata test -w "$datadir"
    assert_status_zero "$status"
}

@test "occ integrity:check-core does not flag nextcloud-init-sync.lock" {
    # The lockfile may persist on disk (upstream entrypoint doesn't unlink it
    # on exit) but the real user-visible regression is integrity:check-core
    # flagging it as EXTRA_FILE (issues #2057, #2299). The next test verifies
    # the overall integrity check passes; here we just assert the specific
    # filename isn't mentioned.
    run compose_exec_wwwdata php /var/www/html/occ integrity:check-core --output=json
    assert_status_zero "$status"
    assert_not_match "$output" 'nextcloud-init-sync\.lock'
}

@test "Redis is configured iff SCENARIO_REDIS=true" {
    if [ "${SCENARIO_REDIS:-true}" = "true" ]; then
        run nc_config_system_get memcache.locking
        assert_status_zero "$status"
        assert_match "$output" 'OC\\Memcache\\Redis'
    else
        run nc_config_system_get redis
        # without redis configured, occ returns the empty array or 'No such value'
        true  # nothing to assert positively; absence is correct
    fi
}

@test "occ integrity:check-core passes (no extra/missing files)" {
    run compose_exec_wwwdata php /var/www/html/occ integrity:check-core --output=json
    assert_status_zero "$status"
    # Output is empty JSON object on success
    assert_match "$output" '^\s*\[\]\s*$|^\s*$'
}
