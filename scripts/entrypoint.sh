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
# Apply only if either PUID or PGID is set. Skip the (expensive) recursive
# chown when the uid/gid already match — `chown -R` on a multi-TB data
# volume would otherwise re-traverse every file on every container start.
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    target_uid="${PUID:-$(id -u www-data)}"
    target_gid="${PGID:-$(id -g www-data)}"
    current_uid="$(id -u www-data)"
    current_gid="$(id -g www-data)"

    changed=0
    if [ "$target_gid" != "$current_gid" ]; then
        echo "entrypoint: groupmod www-data $current_gid -> $target_gid" >&2
        groupmod -o -g "$target_gid" www-data
        changed=1
    fi
    if [ "$target_uid" != "$current_uid" ]; then
        echo "entrypoint: usermod www-data $current_uid -> $target_uid" >&2
        usermod -o -u "$target_uid" www-data
        changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        echo "entrypoint: chown -R ${target_uid}:${target_gid} /var/www (may take a while on first run)" >&2
        chown -R "${target_uid}:${target_gid}" /var/www
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
