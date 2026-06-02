#!/usr/bin/env bats
# 30-docker-secrets.bats — *_FILE env vars must work on fresh install
# (issue #1148: Docker secrets on first init broken). Plus, secrets must
# NOT appear in /proc/<pid>/environ — they should only be present as files.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

CTN="nc-secrets-test-$$"
SECRET_DIR=""   # per-test scratch dir, set in setup()

setup() {
    SECRET_DIR=$(mktemp -d /tmp/nc-secrets-XXXXXX)
    printf 'pass-from-file-only' > "$SECRET_DIR/admin"
    chmod a+r "$SECRET_DIR/admin"
}

teardown() {
    container_rm "$CTN"
    # rm -rf might fail if files got root-owned by the container; ignore.
    rm -rf "$SECRET_DIR" 2>/dev/null || sudo rm -rf "$SECRET_DIR" 2>/dev/null || true
}

@test "NEXTCLOUD_ADMIN_PASSWORD_FILE on fresh install (instead of plain env)" {
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=admin \
        -e NEXTCLOUD_ADMIN_PASSWORD_FILE=/run/secrets/admin \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "$SECRET_DIR:/run/secrets:ro" \
        "$NC_IMAGE" >/dev/null

    wait_until 120 5 sh -c "docker exec $CTN curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q '\"installed\":true'"

    run docker exec -u www-data "$CTN" php /var/www/html/occ user:info admin --output=json
    assert_status_zero "$status"
    assert_match "$output" '"user_id":"admin"'
}

@test "secret value NOT present in PID 1 /proc/*/environ" {
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -e NEXTCLOUD_ADMIN_USER=admin \
        -e NEXTCLOUD_ADMIN_PASSWORD_FILE=/run/secrets/admin \
        -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
        -v "$SECRET_DIR:/run/secrets:ro" \
        "$NC_IMAGE" >/dev/null
    wait_until 120 5 sh -c "docker exec $CTN curl -fsS http://127.0.0.1/status.php 2>/dev/null | grep -q '\"installed\":true'"

    # PID 1 (supervisord) — the secret should NOT appear in its env. The grep
    # pipeline ends in `|| true` so a "not found" (clean pass) isn't a failure,
    # which makes a status check tautological — the real assertion is that grep
    # extracted no matching line.
    run docker exec "$CTN" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -F "pass-from-file-only" || true'
    [ -z "$output" ] || {
        log "WARNING: admin password leaked into PID 1 environ: $output"
        return 1
    }
}

@test "NEXTCLOUD_ADMIN_PASSWORD_FILE path is read by upstream entrypoint (file_env)" {
    # Test the contract that the upstream's file_env helper supports — confirm
    # the file_env function exists in the upstream entrypoint we layered on.
    run docker run --rm --entrypoint=grep "$NC_IMAGE" -c 'file_env()' /entrypoint.sh
    assert_status_zero "$status"
    [ "$output" -ge 1 ]
}
