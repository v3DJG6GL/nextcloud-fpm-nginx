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

    # Probe a single persistent file. Skip the (potentially hours-long)
    # walk ONLY when the sentinel both exists AND already matches the
    # target ownership — that means a previous boot already chowned the
    # tree. In every other case (sentinel missing, sentinel owned by a
    # different uid/gid), run the chown.
    sentinel=/var/www/html/version.php
    if [ -f "$sentinel" ] \
       && [ "$(stat -c '%u' "$sentinel")" = "$target_uid" ] \
       && [ "$(stat -c '%g' "$sentinel")" = "$target_gid" ]; then
        # Already correct; subsequent boot of an already-migrated tree.
        :
    else
        if [ -f "$sentinel" ]; then
            reason="sentinel ${sentinel} was $(stat -c '%u:%g' "$sentinel"), target ${target_uid}:${target_gid}"
        else
            reason="fresh install — no sentinel ${sentinel} yet"
        fi
        echo "entrypoint: chown -R ${target_uid}:${target_gid} /var/www (${reason}; may take a while)" >&2
        chown -R "${target_uid}:${target_gid}" /var/www
    fi

    # --- Optional: chown an external datadirectory --------------------------
    # If the NC `datadirectory` config points OUTSIDE /var/www/ (e.g.
    # mounted at /data instead of /var/www/html/data), the /var/www chown
    # above doesn't reach it. Detect the path and gate the chown on the
    # same sentinel pattern.
    #
    # Source of truth for `datadirectory`, in priority order:
    #   1. NEXTCLOUD_DATA_DIR env (honoured during fresh install by the
    #      upstream entrypoint — useful BEFORE config.php exists).
    #   2. config.php (the persistent source of truth post-install).
    # PHP is in the base image so we read it the robust way (avoids
    # fragile grep against config.php's array syntax).
    data_dir=""
    if [ -n "${NEXTCLOUD_DATA_DIR:-}" ]; then
        data_dir="$NEXTCLOUD_DATA_DIR"
    elif [ -f /var/www/html/config/config.php ]; then
        data_dir=$(php -r '
            $CONFIG = [];
            @include "/var/www/html/config/config.php";
            echo $CONFIG["datadirectory"] ?? "";
        ' 2>/dev/null) || data_dir=""
    fi

    case "$data_dir" in
        # Empty (no datadirectory configured yet, or env unset on fresh
        # install) → skip. The upstream entrypoint will create one and
        # the next boot will see it.
        ""|/var/www/*)
            # Either empty or under /var/www/ → already covered by the
            # chown above. Nothing extra to do.
            :
            ;;
        *)
            # External data dir. Sentinel: NC's marker file
            # (`.ncdata` since NC 28, `.ocdata` legacy). NC creates it on
            # install and uses it to validate the data dir on every boot,
            # so it's always present in a healthy install and is owned by
            # www-data by design.
            data_sentinel=""
            if [ -f "$data_dir/.ncdata" ]; then
                data_sentinel="$data_dir/.ncdata"
            elif [ -f "$data_dir/.ocdata" ]; then
                data_sentinel="$data_dir/.ocdata"
            fi

            if [ -n "$data_sentinel" ] \
               && [ "$(stat -c '%u' "$data_sentinel")" = "$target_uid" ] \
               && [ "$(stat -c '%g' "$data_sentinel")" = "$target_gid" ]; then
                # Already correct; skip the walk.
                :
            elif [ -d "$data_dir" ]; then
                if [ -n "$data_sentinel" ]; then
                    reason="sentinel ${data_sentinel} was $(stat -c '%u:%g' "$data_sentinel"), target ${target_uid}:${target_gid}"
                else
                    reason="no .ncdata/.ocdata sentinel in ${data_dir} yet (fresh data dir, or pre-NC-init)"
                fi
                echo "entrypoint: chown -R ${target_uid}:${target_gid} ${data_dir} (${reason}; may take a while on large data)" >&2
                chown -R "${target_uid}:${target_gid}" "$data_dir"
            fi
            ;;
    esac
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
