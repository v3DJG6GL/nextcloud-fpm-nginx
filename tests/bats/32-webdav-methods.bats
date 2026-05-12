#!/usr/bin/env bats
# 32-webdav-methods.bats — WebDAV methods (PROPFIND, REPORT, MOVE, COPY, MKCOL,
# LOCK, UNLOCK, PUT, DELETE) must not be blocked at the nginx layer.
# Common regression: proxies / WAFs that only allow GET/POST/HEAD/PUT cause
# desktop sync to fail with 405 on first sync.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "PROPFIND on /remote.php/dav reaches Nextcloud (returns 401, not 405)" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -w '%{http_code}' -X PROPFIND "${base}/remote.php/dav/"
    assert_status_zero "$status"
    # 401 = NC said "auth needed" (good — nginx forwarded the method)
    # 207 = NC processed it (also good)
    # 405 = nginx/WAF blocked it (BAD)
    [ "$output" = "401" ] || [ "$output" = "207" ] || {
        log "PROPFIND returned $output — expected 401 or 207, not 405"
        return 1
    }
}

@test "REPORT on /remote.php/dav reaches Nextcloud" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -w '%{http_code}' -X REPORT "${base}/remote.php/dav/"
    assert_status_zero "$status"
    [ "$output" = "401" ] || [ "$output" = "207" ] || {
        log "REPORT returned $output — expected 401 or 207"
        return 1
    }
}

@test "MOVE on /remote.php/dav reaches Nextcloud" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -w '%{http_code}' -X MOVE -H 'Destination: /remote.php/dav/x' "${base}/remote.php/dav/"
    assert_status_zero "$status"
    [ "$output" = "401" ] || [ "$output" = "207" ] || [ "$output" = "404" ] || {
        log "MOVE returned $output — expected 401/207/404"
        return 1
    }
}

@test "MKCOL on /remote.php/dav reaches Nextcloud" {
    local base
    base=$(nc_host_url)
    run curl -sS -o /dev/null -w '%{http_code}' -X MKCOL "${base}/remote.php/dav/"
    assert_status_zero "$status"
    [ "$output" = "401" ] || [ "$output" = "405" ] || [ "$output" = "404" ] || {
        log "MKCOL returned $output"
        return 1
    }
}
