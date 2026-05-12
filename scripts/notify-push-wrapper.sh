#!/bin/sh
# Lifecycle wrapper for the nextcloud/notify_push binary.
#
# Started by supervisord (when NOTIFY_PUSH_ENABLE=true) as user www-data. The
# wrapper:
#   1. Waits for Nextcloud install/upgrade to complete (version.php +
#      config.php present).
#   2. Starts the notify_push binary in the background.
#   3. Runs `occ notify_push:setup` once the binary is reachable. This
#      registers the binary URL inside Nextcloud's config. Idempotent — on
#      subsequent container starts it's a no-op verification.
#   4. Forwards SIGTERM/SIGINT to the binary for graceful shutdown.
set -eu

NC_ROOT=/var/www/html
PUSH_LOCAL_URL=http://localhost:7867/push

log() { printf '[notify-push-wrapper] %s\n' "$*" >&2; }

# 1. Wait for install/upgrade to settle.
while [ ! -f "$NC_ROOT/version.php" ] || [ ! -f "$NC_ROOT/config/config.php" ]; do
    log "waiting for Nextcloud install (version.php / config.php)..."
    sleep 5
done

# 2. Launch the binary. It reads Redis + DB connection from config.php.
/usr/local/bin/notify_push "$NC_ROOT/config/config.php" &
np_pid=$!

# Forward signals to the binary for clean shutdown.
trap 'log "forwarding TERM"; kill -TERM "$np_pid" 2>/dev/null || true; wait "$np_pid"; exit $?' TERM INT

# 3. Ensure the notify_push companion app is installed/enabled, then register
# the binary URL with Nextcloud.
#
# NC 33 does NOT ship the companion `notify_push` PHP app by default — it has
# to come from the Nextcloud app store. Install + enable + setup can each
# race against Nextcloud's first-boot init; we retry the whole sequence as a
# unit. After 6 unsuccessful attempts of the high-level `notify_push:setup`
# (which sometimes false-fails on mount-info verification even when the
# binary is functional), we fall back to writing `base_endpoint` directly
# via `config:app:set` — which is the actual side-effect setup wants.
sleep 3
attempts=0
while :; do
    attempts=$((attempts + 1))

    # Idempotent.
    php "$NC_ROOT/occ" app:install notify_push >/dev/null 2>&1 || true
    php "$NC_ROOT/occ" app:enable  notify_push >/dev/null 2>&1 || true

    if php "$NC_ROOT/occ" notify_push:setup "$PUSH_LOCAL_URL" 2>&1; then
        log "notify_push:setup succeeded on attempt $attempts"
        break
    fi

    if [ "$attempts" -ge 6 ]; then
        log "notify_push:setup self-test failing after $attempts attempts."
        log "falling back: writing base_endpoint directly via config:app:set."
        if php "$NC_ROOT/occ" config:app:set notify_push base_endpoint \
                --value "$PUSH_LOCAL_URL" >/dev/null 2>&1; then
            log "base_endpoint stored as $PUSH_LOCAL_URL"
        else
            log "fallback failed; clients won't get push notifications"
            log "binary is still running and reachable on /push for manual debug"
        fi
        break
    fi

    log "notify_push setup attempt $attempts/6 failed; retry in 10s"
    sleep 10
done

# 4. Hand off to the binary process.
wait "$np_pid"
