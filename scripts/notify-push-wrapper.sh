#!/bin/sh
# Lifecycle wrapper for the nextcloud/notify_push binary.
#
# Started by supervisord (when NOTIFY_PUSH_ENABLE=true) as user www-data. The
# wrapper:
#   1. Waits for Nextcloud install/upgrade to complete (version.php +
#      config.php present).
#   2. Starts the notify_push binary in the background.
#   3. Syncs the companion PHP app bundled in the image (/usr/src/notify_push)
#      into custom_apps/, enables it, and runs `occ notify_push:setup` once
#      the binary is reachable. This registers the binary URL inside
#      Nextcloud's config. Idempotent — on subsequent container starts it's a
#      no-op verification.
#   4. Forwards SIGTERM/SIGINT to the binary for graceful shutdown.
set -eu

NC_ROOT=/var/www/html
PUSH_LOCAL_URL=http://localhost:7867/push
BUNDLED_APP=/usr/src/notify_push
APP_DIR=$NC_ROOT/custom_apps/notify_push

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
# The official image does NOT ship the companion `notify_push` PHP app. It is
# bundled in this image at $BUNDLED_APP (same release tarball the app store
# serves, version-locked to the binary — see Dockerfile) and synced into
# custom_apps/ here, never fetched from apps.nextcloud.com: the old
# `occ app:install` ran once per fresh volume and got CI rate-limited (429,
# reported by NC as "not found on the appstore"; runs 744/747). Upstream's
# entrypoint only seeds custom_apps/ into an EMPTY volume, so an image bump
# would never reach an existing install without this sync.
#
# version.php/config.php (step 1) already exist while the upstream entrypoint
# — a sibling supervisord program, not a predecessor — is still mid-install
# or mid-`occ upgrade` of a new core, so wait for it to finish before touching
# apps or running our own `occ upgrade`.
nc_ready() {
    st=$(php "$NC_ROOT/occ" status --output=json 2>/dev/null) || return 1
    case "$st" in *'"installed":true'*) ;; *) return 1 ;; esac
    case "$st" in *'"maintenance":true'*|*'"needsDbUpgrade":true'*) return 1 ;; esac
}
waited=0
until nc_ready; do
    [ $((waited % 60)) -eq 0 ] && log "waiting for Nextcloud install/upgrade to finish (occ status)..."
    waited=$((waited + 5))
    sleep 5
done

app_version() {
    sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$1/appinfo/info.xml" 2>/dev/null | head -n 1
}
bundled_ver=$(app_version "$BUNDLED_APP")
installed_ver=$(app_version "$APP_DIR")
if [ "$installed_ver" = "$bundled_ver" ]; then
    :
elif [ -n "$installed_ver" ] \
        && [ "$(printf '%s\n%s\n' "$installed_ver" "$bundled_ver" | sort -V | tail -n 1)" = "$installed_ver" ]; then
    # Newer copy already present (e.g. updated from the app store UI): an
    # app downgrade is refused by Nextcloud, so leave it alone.
    log "custom_apps/notify_push $installed_ver is newer than bundled $bundled_ver; keeping it"
else
    log "syncing bundled notify_push app ${installed_ver:-<none>} -> $bundled_ver"
    # Not fatal under `set -e`: exiting here would orphan the binary started
    # above, and supervisord's restart would then collide on port 7867.
    if ! { mkdir -p "$APP_DIR" && rsync -rlD --delete "$BUNDLED_APP/" "$APP_DIR/"; }; then
        log "copying $BUNDLED_APP into $APP_DIR failed; app:enable below will report it"
    elif [ -n "$installed_ver" ]; then
        # A changed app version makes Nextcloud demand an upgrade (web UI
        # shows the updater page) until `occ upgrade` migrates the app.
        if ! out=$(php "$NC_ROOT/occ" upgrade 2>&1); then
            log "occ upgrade after notify_push $installed_ver -> $bundled_ver failed: $out"
        fi
    fi
fi

# Enable + setup can each race against Nextcloud's first-boot init; we retry
# the whole sequence as a unit. After 6 unsuccessful attempts of the
# high-level `notify_push:setup` (which sometimes false-fails on mount-info
# verification even when the binary is functional), we fall back to writing
# `base_endpoint` directly via `config:app:set` — which is the actual
# side-effect setup wants.
sleep 3
attempts=0
while :; do
    attempts=$((attempts + 1))

    # Idempotent. Failures are non-fatal (the loop retries), but their output
    # is LOGGED — a silently discarded error left CI runs failing
    # "notify_push app not enabled" with no explanation (run 475, 2026-09-16).
    if ! out=$(php "$NC_ROOT/occ" app:enable notify_push 2>&1); then
        log "app:enable notify_push failed (attempt $attempts): $out"
    fi

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
