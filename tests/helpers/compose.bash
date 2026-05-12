# docker compose helpers for fixture management. Sourced from bats files.

# COMPOSE_FILE is set by tests/run-all.sh based on SCENARIO_DB.
# COMPOSE_PROJECT_NAME is set so concurrent test runs don't collide.

compose() {
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"
}

# Bring fixture up with --wait (blocks until all services pass their
# healthchecks). Then wait extra for /status.php to return installed=true.
compose_up_wait() {
    compose up -d --wait
    wait_for_nc_install
}

# Bring fixture down + remove anonymous volumes (don't leak state between
# scenarios).
compose_down() {
    compose down -v --remove-orphans >/dev/null 2>&1 || true
}

# Exec into the main `nc` service as root.
compose_exec() {
    compose exec -T nc "$@"
}

# Exec into the main `nc` service as www-data.
compose_exec_wwwdata() {
    compose exec -T -u www-data nc "$@"
}

# Run occ via the main `nc` service.
occ() {
    compose_exec_wwwdata php /var/www/html/occ "$@"
}

# Service port mapping for the host. NC service publishes on a host port.
nc_host_url() {
    local port
    port=$(compose port nc 80 2>/dev/null | awk -F: '{print $NF}')
    if [ -z "$port" ]; then
        log "could not determine host port for nc:80"
        return 1
    fi
    echo "http://127.0.0.1:${port}"
}

# Wait until Nextcloud reports installed=true via status.php.
wait_for_nc_install() {
    local timeout="${1:-180}"
    local url
    url=$(nc_host_url)/status.php
    log "waiting for $url to report installed=true (timeout ${timeout}s)..."
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS "$url" 2>/dev/null | grep -q '"installed":true'; then
            return 0
        fi
        sleep 3
    done
    log "Nextcloud install did not complete within ${timeout}s"
    log "Recent nc logs:"
    compose logs --tail=30 nc 2>&1 | sed 's/^/#   /' >&3 || true
    return 1
}
