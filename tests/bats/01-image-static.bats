#!/usr/bin/env bats
# 01-image-static.bats — image-level invariants visible without booting.
# Complements tests/cst/base.yaml (which CST already runs). Useful for
# assertions CST can't easily express.

load '../helpers/lib.bash'
load '../helpers/docker.bash'

@test "image has HEALTHCHECK declared" {
    run docker image inspect --format='{{.Config.Healthcheck.Test}}' "$NC_IMAGE"
    assert_status_zero "$status"
    assert_match "$output" 'status\.php'
}

@test "ENTRYPOINT is empty (overrides upstream)" {
    run image_entrypoint "$NC_IMAGE"
    assert_status_zero "$status"
    # empty or whitespace
    [ -z "${output//[[:space:]]/}" ]
}

@test "CMD invokes our container entrypoint" {
    run image_cmd "$NC_IMAGE"
    assert_status_zero "$status"
    assert_match "$output" '/usr/local/bin/container-entrypoint\.sh'
}

@test "image has no .git, no SSH keys, no .npmrc" {
    run docker run --rm --entrypoint=sh "$NC_IMAGE" -c \
        'find / -path /proc -prune -o -path /sys -prune -o \( -name .git -o -name id_rsa -o -name .npmrc \) -print 2>/dev/null | head -10'
    assert_status_zero "$status"
    [ -z "${output//[[:space:]]/}" ] || {
        log "found unexpected files:"
        log "$output"
        return 1
    }
}

@test "NEXTCLOUD_VERSION env reports a version" {
    run image_env "$NC_IMAGE" NEXTCLOUD_VERSION
    assert_status_zero "$status"
    assert_match "$output" '^[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "image size below 2.5 GB (sanity ceiling)" {
    local bytes
    bytes=$(image_size_bytes "$NC_IMAGE")
    log "image size: $((bytes/1024/1024)) MB"
    [ "$bytes" -lt $((2500*1024*1024)) ]
}

@test "PHP_OPCACHE_MEMORY_CONSUMPTION baseline ENV defined (128) from upstream" {
    run image_env "$NC_IMAGE" PHP_OPCACHE_MEMORY_CONSUMPTION
    assert_status_zero "$status"
    assert_eq "$output" "128"
}
