#!/usr/bin/env bats
# 25-major-skip-refused.bats — Nextcloud refuses to skip major versions
# (e.g., 31 → 33 without going through 32). We synthesize a fake old
# version.php and verify the entrypoint refuses.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

CTN="nc-majorskip-test-$$"
VOL="nc-majorskip-vol-$$"
FIXDIR="$(pwd)/tests/fixtures"

setup() {
    # This test makes sense only against majors >= 33 (we synth a 31 marker;
    # 31→32 is a normal one-major upgrade, not a skip, and the entrypoint
    # rightly runs `occ upgrade` rather than refusing). The floor is the v31
    # fixture + 2 — a fixed lower bound, so no per-major edits as new majors
    # ship (the old 33|34|35|36 allowlist silently skipped at v37+).
    if [ "${NC_MAJOR:-33}" -lt 33 ]; then
        skip "NC_MAJOR=$NC_MAJOR < 33 — within one major of the v31 marker, a normal upgrade not a skip"
    fi
}

teardown() {
    container_rm "$CTN"
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}

@test "synthetic v31 version.php in /var/www/html causes current-major boot to refuse" {
    [ "${REMOTE_DOCKER:-}" = "1" ] && skip "bind-mount from job workspace not visible to remote docker daemon (dind)"
    # Create an empty volume, populate it with a v31 version.php at the root,
    # then try to boot. NC has to think v31 is installed but the image is much newer.
    docker volume create "$VOL" >/dev/null
    docker run --rm -v "$VOL:/var/www/html" -v "$FIXDIR/version-31.php:/tmp/version.php:ro" \
        alpine sh -c 'cp /tmp/version.php /var/www/html/version.php && chmod 644 /var/www/html/version.php' >/dev/null

    # Start the container detached; wait up to 60s for it to exit on its own.
    docker run -d --name "$CTN" \
        -e SQLITE_DATABASE=nc.db \
        -v "$VOL:/var/www/html" \
        "$NC_IMAGE" >/dev/null 2>&1 || true

    # Poll for the entrypoint refusal — looking for the upstream's specific message.
    # We don't strictly require exit; the entrypoint may log + exit OR loop.
    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if docker logs "$CTN" 2>&1 | grep -qE 'upgrading from .* to .* is not supported|only possible to upgrade one major version at a time'; then
            break
        fi
        sleep 3
    done

    run docker logs "$CTN"
    assert_match "$output" 'upgrading from .* to .* is not supported|only possible to upgrade one major version at a time'
}
