#!/bin/sh
# Container entrypoint (PID 1). Runs as root.
#
# 1. Optional: reassign www-data uid/gid from PUID/PGID, chown /var/www
#    when the uid actually changes. UMASK applied to all child processes.
# 2. Render env-var-driven config overrides (PHP/FPM/nginx).
# 3. Exec supervisord, which starts:
#      - the upstream Nextcloud entrypoint (runs install/upgrade +
#        before-starting hooks, then execs php-fpm)
#      - nginx
#      - optional: notify_push (NOTIFY_PUSH_ENABLE=true)
#      - optional: cron     (NEXTCLOUD_CRON_ENABLE=true)
set -eu

# --- Reassign www-data uid/gid ----------------------------------------------
# Apply only if either PUID or PGID is set.
#
# Two-stage gating to avoid the (potentially hours-long) `chown -R /var/www`
# on every container recreation:
#
# 1. groupmod/usermod always run when the in-container www-data uid/gid
#    don't match the target. That's cheap (one line in /etc/passwd) and
#    they MUST run every fresh-container boot because /etc/passwd lives
#    in the container layer, not in any bind mount, so it resets to the
#    upstream image's default (33:33) on every `docker compose up -d`
#    after an image pull.
#
# 2. The recursive chown only runs when files on disk are ACTUALLY owned
#    differently from the target. We probe a single persistent file
#    (`/var/www/html/version.php`) instead of stat-walking the whole
#    tree. On a multi-TB HDD data volume, the difference is "instant"
#    vs "hours".
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    target_uid="${PUID:-$(id -u www-data)}"
    target_gid="${PGID:-$(id -g www-data)}"
    current_uid="$(id -u www-data)"
    current_gid="$(id -g www-data)"

    if [ "$target_gid" != "$current_gid" ]; then
        echo "entrypoint: groupmod www-data $current_gid -> $target_gid" >&2
        groupmod -o -g "$target_gid" www-data
    fi
    if [ "$target_uid" != "$current_uid" ]; then
        echo "entrypoint: usermod www-data $current_uid -> $target_uid" >&2
        usermod -o -u "$target_uid" www-data
    fi

    # Probe a single persistent file — if it's already owned target:target,
    # the rest of /var/www is too (the previous boot already chowned it),
    # and we can skip the expensive walk.
    sentinel=/var/www/html/version.php
    if [ -f "$sentinel" ]; then
        disk_uid=$(stat -c '%u' "$sentinel")
        disk_gid=$(stat -c '%g' "$sentinel")
        if [ "$disk_uid" = "$target_uid" ] && [ "$disk_gid" = "$target_gid" ]; then
            : # already correct; skip the walk
        else
            echo "entrypoint: chown -R ${target_uid}:${target_gid} /var/www (sentinel ${sentinel} was ${disk_uid}:${disk_gid}, may take a while)" >&2
            chown -R "${target_uid}:${target_gid}" /var/www
        fi
    else
        # First boot (fresh install — version.php gets written by the
        # upstream entrypoint after rsync). Nothing persistent to chown
        # yet; the upstream rsync chowns its output, and the next boot
        # will sentinel-match. Skip the walk this time.
        :
    fi
fi

# --- UMASK -------------------------------------------------------------------
# Propagated to supervisord and all its children (php-fpm, nginx, etc.).
if [ -n "${UMASK:-}" ]; then
    umask "$UMASK"
fi

# --- Render env-var-driven config overrides ---------------------------------
/usr/local/bin/render-overrides.sh

# --- Hand off to supervisord ------------------------------------------------
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
