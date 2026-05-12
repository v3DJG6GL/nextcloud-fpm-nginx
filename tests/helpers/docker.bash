# Docker / image inspection helpers. Sourced from bats files.

# image_present <image-tag>
image_present() {
    docker image inspect "$1" >/dev/null 2>&1
}

# image_label <image-tag> <label-key>
image_label() {
    docker image inspect --format='{{ index .Config.Labels "'"$2"'" }}' "$1"
}

# image_env <image-tag> <env-key>
image_env() {
    docker image inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$1" \
        | awk -F= -v k="$2" '$1==k { sub(/^[^=]+=/, "", $0); print; exit }'
}

# image_cmd <image-tag>      → space-separated CMD elements
image_cmd() {
    docker image inspect --format='{{join .Config.Cmd " "}}' "$1"
}

# image_entrypoint <image-tag> → space-separated ENTRYPOINT elements
image_entrypoint() {
    docker image inspect --format='{{join .Config.Entrypoint " "}}' "$1"
}

# image_size_bytes <image-tag>
image_size_bytes() {
    docker image inspect --format='{{.Size}}' "$1"
}

# container_status <container-name> → "running" / "exited" / ""
container_status() {
    docker inspect --format='{{.State.Status}}' "$1" 2>/dev/null || true
}

# container_health <container-name> → "healthy" / "unhealthy" / "starting" / ""
container_health() {
    docker inspect --format='{{.State.Health.Status}}' "$1" 2>/dev/null || true
}

# container_exit_code <container-name> → integer
container_exit_code() {
    docker inspect --format='{{.State.ExitCode}}' "$1" 2>/dev/null || echo -1
}

# get_log <container-name> [tail-lines]
get_log() {
    local tail="${2:-1000}"
    docker logs --tail="$tail" "$1" 2>&1
}

# wait_for_health <container-name> <timeout-s> [target-state=healthy]
wait_for_health() {
    local name="$1" timeout="${2:-180}" target="${3:-healthy}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local h
        h=$(container_health "$name")
        if [ "$h" = "$target" ]; then
            return 0
        fi
        sleep 3
    done
    log "container $name didn't reach health=$target within ${timeout}s (last: $(container_health "$name"))"
    return 1
}

# remove a container quietly if it exists
container_rm() {
    docker rm -f "$@" >/dev/null 2>&1 || true
}
